--[[
	Spray Artist — paints real images onto walls in "Spray Paint!" (PlaceId 5991163185)

	Sources:  typed text · any image URL
	Output:   one Square (or round) dot per pixel, up to 64 colours.

	It paints like a player does — everything goes through the game's own tools:
	  • each colour is picked with the game's colour picker (ColorPicker.SetColor, the same event the
	    picker's HSV/RGB/Hex boxes fire), which moves the picker and sets PaintSettings.Color;
	  • the game's own spray code does the painting, aimed without touching the real mouse: the
	    property it aims with (PlayerMouse.UnitRay) is redirected per paint loop, presses go through
	    PlayerMouse.Button1Down and releases through the Mouse module's mouseUp event;
	  • several paint loops ("lanes") run at once, each steered to its own part of the picture;
	  • afterwards it reads back the dots the server actually stored and repaints whatever is
	    missing, pass after pass, until every pixel is there.
	The game's own spray code sends the paint to the server with its own anti-cheat keys.

	Notes (verified in-game 2026-10-10):
	  • The server keeps only ONE colour per paint batch (the game sends every 0.25 s and on release);
	    other-coloured dots are dropped and the game deletes their local copies. So the picture is
	    reduced to a palette and sprayed strictly one colour at a time: release, wait until the game
	    has sent the colour and the server answered, pause, pick the next colour, pause, spray.
	  • Brush Size must be a multiple of 0.05 (0.30 kept, 0.32 dropped).
	  • The SprayPaint tool must be equipped and PaintSettings.Tool must be "None" for presses to spray.
	  • Dots must land on "PaintRaycast" surfaces within workspace.MaxSprayDistance (40) of you.

	Controls: RightShift toggles the window (and stops a drawing in progress).
	"Place on wall" -> aim at a wall -> click. Esc cancels placement. Don't click in-game while it paints.
	Pressing Paint! again on the same spot only fills in what's missing.
]]

---------------------------------------------------------------------------------------------------
-- Re-execution guard
---------------------------------------------------------------------------------------------------
local genv = if type(getgenv) == "function" then getgenv() else _G
if type(genv.SprayArtist) == "table" and type(genv.SprayArtist.Cleanup) == "function" then
	pcall(genv.SprayArtist.Cleanup)
end

if not game:IsLoaded() then
	game.Loaded:Wait()
end

---------------------------------------------------------------------------------------------------
-- Services & cached references
---------------------------------------------------------------------------------------------------
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AssetService = game:GetService("AssetService")

local LocalPlayer = Players.LocalPlayer
local camera = workspace.CurrentCamera

local httpRequest = (type(request) == "function" and request)
	or (type(http_request) == "function" and http_request)
	or (type(syn) == "table" and type(syn.request) == "function" and syn.request)
	or nil
local canFiles = type(readfile) == "function" and type(writefile) == "function" and type(isfile) == "function"
-- Calling some of the game's own functions (e.g. PaintPositioning.makePaintBetweenScreenPoints)
-- leaves this thread without the executor's capabilities until they're re-applied ("The current
-- thread cannot access 'Instance' (lacking capability Plugin)" when touching our UI). Re-applying
-- the script's identity restores them.
local scriptIdentity = if type(getthreadidentity) == "function" then getthreadidentity() else nil
local function restoreCaps()
	if scriptIdentity and type(setthreadidentity) == "function" then
		pcall(setthreadidentity, scriptIdentity)
	end
end

-- The game's own modules. Requiring them returns the same cached tables the game uses.
local GameApi = {}
do
	local ok, err = pcall(function()
		local modules = ReplicatedStorage:WaitForChild("Modules", 10)
		GameApi.PaintPositioning = require(modules.Paint.PaintPositioning)
		GameApi.Params = GameApi.PaintPositioning.getRaycastParams()
		GameApi.ClientToServer = require(modules.Paint.ClientToServer)
		GameApi.Colors = require(modules.Utils.Colors)
		GameApi.Mouse = require(modules.Mouse.Mouse) -- its mouseUp BindableEvent ends a stroke + sends it
		assert(type(GameApi.Colors.processColor) == "function", "Colors.processColor missing")
	end)
	if not ok then
		warn("[SprayArtist] Made for the game 'Spray Paint!'. Could not load its paint modules: " .. tostring(err))
		return
	end
	if not httpRequest then
		warn("[SprayArtist] Your executor has no request()/http_request() function, so images can't be downloaded.")
		return
	end
	if type(hookmetamethod) ~= "function" or type(getconnections) ~= "function" then
		warn("[SprayArtist] Your executor has no hookmetamethod/getconnections, so it can't drive the game's spray can.")
		return
	end
end

---------------------------------------------------------------------------------------------------
-- Constants & theme
---------------------------------------------------------------------------------------------------
local CONFIG = table.freeze({
	RANGE = (workspace:GetAttribute("MaxSprayDistance") or 40) - 2, -- small margin under the server limit
	MAX_DOT = workspace:GetAttribute("MaxNormalBrushSize") or 1.2,
	MIN_DOT = 0.05, -- the game's own brush-size slider goes down to 0.05
	BRUSH = "Square",
	ROUND_BRUSH = "Octagon", -- the game's round brush
	RUN_JUMP = 5, -- pixels covered in one aim along a row (the game sprays <= 5 dots per tick)
	LANE_PATIENCE = 8, -- ticks a lane re-aims at an unconfirmed pixel before leaving it to the repaint pass
	MAX_LANES = 10,
	-- Speed limit range (pixels per second). ~8 lanes at many hundreds px/s got the account
	-- ghost-banned by the game's anti-cheat; single-lane runs at ~30-100 px/s were fine.
	MIN_RATE = 10,
	MAX_RATE = 1000,
	MIN_STEPS_PER_LANE = 12, -- small colours get fewer lanes (each lane is a press = an undo stroke)
	STALL_SECONDS = 1.5, -- no progress for this long: press the lanes again
	MAX_PASSES = 5, -- paint + repaint-missing passes
	-- Overlapping dots at exactly the same depth z-fight (flickering specks where they overlap).
	-- Every pixel gets a depth level from a repeating pattern so no two overlapping dots share one:
	-- squares (spaced 0.85 of their size) only touch their 8 neighbours -> 2x2 pattern, 4 levels;
	-- round dots (spaced 0.45) reach 2 cells -> 3x3 pattern, 9 levels. Each level is painted on its
	-- own game layer (the game draws layer n 0.0033 studs further out) and lifted a little more.
	SQUARE_LEVEL_PERIOD = 2,
	ROUND_LEVEL_PERIOD = 3,
	-- Total extra lift for the top level. Measured: the server keeps dots lifted 0.02 studs and
	-- rejects 0.05.
	DOT_LIFT_MAX = 0.016,
	COLOR_MATCH = 6, -- 0-255 tolerance when checking a server dot has the pixel's colour
	-- Wrapping the picture over real surfaces (see Wrap)
	WRAP_SNAP = 0.5, -- bumps / steps up to this far off the surface are followed by projection
	WRAP_LIFT = 0.25, -- height above the surface at which a rising wall counts as "in the way"
	WRAP_SUBSTEP = 1.5, -- longest single move while walking the surface (preview tiles are big)
	FOLD_DOT = 0.999, -- neighbouring pixels whose normals differ more than this sit across a fold
	GHOST_TILES = 16, -- preview tiles along the picture's longer side (each follows its surface)
	GHOST_INTERVAL = 0.08, -- seconds between preview re-layouts while aiming
	-- Walking (big pictures): stand within RANGE - WALK_MARGIN of every pixel being sprayed.
	WALK_MARGIN = 3,
	WALK_STAND_OFF = 6, -- studs in front of a wall to stand
	WALK_PATCH = 14, -- radius of the patch of pixels a walk aims at
	-- Colour pipeline (see Imaging.adjust / Imaging.quantize)
	SHARPEN = 0.25, -- "Sharpen details" strength; stronger left bright halos (a "glint") on edges
	SHADOW_LIFT = 0.92, -- gamma for "True colours": paint sits in the game's lighting, darks crush
	PALETTE_REFINE = 6, -- k-means rounds after median cut (palette colours = real picture colours)
	-- The palette is built once per picture + colour settings from a copy at most this many pixels
	-- a side, then reused for every size: resizing only resamples and maps pixels to it.
	PALETTE_SAMPLE = 160,
	PROCESS_BUDGET = 0.008, -- seconds of image processing per frame (spread so nothing hitches)
	DITHER_STRENGTH = 0.8, -- share of the colour error passed on (1 = full Floyd-Steinberg)
	DITHER_CLAMP = 40, -- max error passed on per channel: flat areas don't sparkle
	-- Most pixels along either side of a picture (size / pixel spacing is capped at this).
	MAX_SIDE = 500,
	-- Width / Height slider range (studs).
	MIN_STUDS = 1,
	MAX_STUDS = 250, -- big pictures: the character walks along to stay in spraying range
	-- Text: rendered letters' soft edges count as ink from this alpha up (thicker, crisper strokes).
	TEXT_ALPHA = 90,
	FILE = "SprayArtist.json",
	BIND_NAME = "SprayArtist_Placement",
	TOGGLE_KEY = Enum.KeyCode.RightShift,
	-- Pixels sit this much closer together than the brush is wide, so neighbouring squares overlap
	-- and the wall can't show through seams.
	GRID_OVERLAP = 0.85,
	-- Round dots (the Octagon brush) reach 0.5x their size from the centre. Spacing must stay BELOW
	-- 0.5 so every dot's centre is also covered by its neighbours: at 0.68 and then 0.55 a speck
	-- of wall still showed in the middle of every round dot (a regular grid, round brush only —
	-- squares were fine). At 0.45 each centre sits inside the neighbouring dots.
	ROUND_GRID_OVERLAP = 0.45,
	COLOR_SEND_SECONDS = 0.45, -- typical wait for the game to send a colour and the server to answer
	FLUSH_TIMEOUT = 4,
	-- PaintSettings attributes the drawing sets directly (Size/Opacity/Rotation go through the game's
	-- Appearance controls instead, because the panel re-applies its slider values over the attributes).
	-- Old values are restored afterwards.
	BRUSH_ATTRIBUTES = { "BrushShape", "RainbowEnabled", "NeonEnabled", "ChromeEnabled", "Tool" },
	-- Text mode: placehold.co renders the words as a big PNG on a transparent background.
	TEXT_URL = "https://placehold.co/%dx%d/transparent/%s/png?text=%s&font=%s",
	TEXT_FONT = "montserrat",
	WESERV = "https://images.weserv.nl/?url=%s&w=%d&h=%d&fit=inside&output=png",
	-- Avatar tab: Roblox's thumbnail service (largest size each picture type offers).
	AVATAR_URL = "https://thumbnails.roblox.com/v1/users/%s?userIds=%d&size=%s&format=Png&isCircular=false",
	AVATAR_STYLES = table.freeze({
		Full = table.freeze({ endpoint = "avatar", size = "720x720", label = "Full body", nextStyle = "Bust" }),
		Bust = table.freeze({ endpoint = "avatar-bust", size = "420x420", label = "Upper body", nextStyle = "Head" }),
		Head = table.freeze({ endpoint = "avatar-headshot", size = "720x720", label = "Head", nextStyle = "Full" }),
	}),
})

local THEME = table.freeze({
	Bg = Color3.fromRGB(16, 16, 22),
	Panel = Color3.fromRGB(26, 26, 34),
	Field = Color3.fromRGB(38, 38, 50),
	FieldHover = Color3.fromRGB(48, 48, 62),
	Stroke = Color3.fromRGB(62, 62, 80),
	Text = Color3.fromRGB(236, 236, 246),
	SubText = Color3.fromRGB(150, 150, 172),
	Accent = Color3.fromRGB(255, 92, 138),
	AccentHover = Color3.fromRGB(255, 122, 160),
	Accent2 = Color3.fromRGB(124, 96, 255),
	Accent2Hover = Color3.fromRGB(148, 124, 255),
	Good = Color3.fromRGB(92, 222, 142),
	Bad = Color3.fromRGB(255, 96, 96),
	Warn = Color3.fromRGB(255, 202, 92),
	Font = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Medium),
	FontBold = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold),
	TextSize = 14,
	SmallText = 12,
	Corner = UDim.new(0, 8),
	Width = 330,
	Tween = TweenInfo.new(0.16, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
})

---------------------------------------------------------------------------------------------------
-- Settings (defaults merged with the saved file)
---------------------------------------------------------------------------------------------------
local DEFAULTS = table.freeze({
	mode = "Text",
	textColor = "FFFFFF",
	sizeX = 16, -- picture width on the wall (studs)
	sizeY = 12, -- picture height on the wall (studs; follows the width while keepShape is on)
	keepShape = true,
	pixel = 0.2,
	enhance = false,
	skipTransparent = true,
	colors = 64,
	dither = false,
	lanes = 4,
	maxRate = 200,
	colorPause = 0.1, -- seconds to pause between colours (after the old colour was sent)
	roundBrush = false, -- circles (the game's Octagon brush) instead of squares
	trueColors = true, -- pre-correct pictures for the game's colour filter + lighting
	cleanView = false, -- turn the game's bloom / haze / colour filter off on your screen only
	spongeAllLayers = true, -- the game's sponge (Eraser) wipes your paint on every layer at once
	autoWalk = true, -- walk the character along big pictures so every part is in range
	rotateStep = 90, -- degrees the picture turns per R press while placing
	avatarStyle = "Full", -- Avatar tab: "Full" body, "Bust" (upper body) or "Head"
})
local Settings = table.clone(DEFAULTS)
if canFiles then
	local ok, decoded = pcall(function()
		if not isfile(CONFIG.FILE) then
			return nil
		end
		return HttpService:JSONDecode(readfile(CONFIG.FILE))
	end)
	if ok and type(decoded) == "table" then
		for key, default in DEFAULTS do
			if typeof(decoded[key]) == typeof(default) then
				Settings[key] = decoded[key]
			end
		end
	elseif not ok then
		warn("[SprayArtist] Ignoring unreadable settings file: " .. tostring(decoded))
	end
end

Settings.maxRate = math.clamp(Settings.maxRate, CONFIG.MIN_RATE, CONFIG.MAX_RATE)
Settings.rotateStep = math.clamp(math.floor((tonumber(Settings.rotateStep) or 90) / 15 + 0.5) * 15, 15, 180)
Settings.lanes = math.clamp(Settings.lanes, 1, CONFIG.MAX_LANES)
if not CONFIG.AVATAR_STYLES[Settings.avatarStyle] then
	Settings.avatarStyle = "Full"
end
-- Pixel size doubles as the brush size, which the server only accepts in 0.05 steps.
Settings.pixel = math.clamp(math.floor(Settings.pixel * 20 + 0.5) / 20, CONFIG.MIN_DOT, 0.6)
Settings.sizeX = math.clamp(Settings.sizeX, CONFIG.MIN_STUDS, CONFIG.MAX_STUDS)
Settings.sizeY = math.clamp(Settings.sizeY, CONFIG.MIN_STUDS, CONFIG.MAX_STUDS)

---------------------------------------------------------------------------------------------------
-- Utilities
---------------------------------------------------------------------------------------------------
local Maid = {}
Maid.__index = Maid
function Maid.new()
	return setmetatable({ _tasks = {} }, Maid)
end
function Maid:Give(item)
	table.insert(self._tasks, item)
	return item
end
function Maid:Cleanup()
	local tasks = self._tasks
	self._tasks = {}
	for i = #tasks, 1, -1 do
		local item = tasks[i]
		local kind = typeof(item)
		if kind == "RBXScriptConnection" then
			item:Disconnect()
		elseif kind == "Instance" then
			pcall(item.Destroy, item)
		elseif kind == "thread" then
			pcall(task.cancel, item)
		elseif kind == "function" then
			pcall(item)
		end
	end
end

local maid = Maid.new()
local alive = true

local function create(className: string, props: { [string]: any }, children: { Instance }?): any
	local inst = Instance.new(className)
	for key, value in props do
		if key ~= "Parent" then
			inst[key] = value
		end
	end
	if children then
		for _, child in children do
			child.Parent = inst
		end
	end
	if props.Parent then
		inst.Parent = props.Parent -- parent last: one replication/layout pass instead of one per property
	end
	return inst
end

local activeTweens: { [Instance]: Tween } = setmetatable({}, { __mode = "k" }) :: any
local function tween(inst: Instance, goal: { [string]: any })
	local running = activeTweens[inst]
	if running then
		running:Cancel()
	end
	local t = TweenService:Create(inst, THEME.Tween, goal)
	activeTweens[inst] = t
	t:Play()
end

local function formatInt(n: number): string
	local s = tostring(math.floor(n))
	local formatted = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (formatted:gsub("^,", ""))
end

-- Spreads heavy work (decoding, resampling) over frames so the game never hitches.
local function newYielder(budget: number)
	local sliceStart = os.clock()
	return function()
		if os.clock() - sliceStart > budget then
			task.wait()
			sliceStart = os.clock()
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Inflate (zlib / DEFLATE) — needed for PNG
---------------------------------------------------------------------------------------------------
local Inflate = {}
do
	local LEN_BASE = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
	local LEN_EXTRA = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
	local DIST_BASE = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 }
	local DIST_EXTRA = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }
	local CL_ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

	-- Canonical Huffman table in "puff" form: count per code length + symbols sorted by code.
	local function build(lengths: { number }, first: number, n: number)
		local count = table.create(15, 0)
		for i = first, first + n - 1 do
			local len = lengths[i]
			if len > 0 then
				count[len] += 1
			end
		end
		local offs = table.create(15, 0)
		for len = 2, 15 do
			offs[len] = offs[len - 1] + count[len - 1]
		end
		local symbol = table.create(n, 0)
		for i = 0, n - 1 do
			local len = lengths[first + i]
			if len > 0 then
				offs[len] += 1
				symbol[offs[len]] = i
			end
		end
		return { count = count, symbol = symbol }
	end

	local FIXED_LIT, FIXED_DIST
	do
		local lit = table.create(288, 8)
		for i = 145, 256 do
			lit[i] = 9
		end
		for i = 257, 280 do
			lit[i] = 7
		end
		FIXED_LIT = build(lit, 1, 288)
		FIXED_DIST = build(table.create(30, 5), 1, 30)
	end

	function Inflate.zlib(src: buffer, start: number, expected: number, yielder: () -> ()): (buffer, number)
		local srcLen = buffer.len(src)
		local pos = start + 2 -- skip the 2-byte zlib header
		local out = buffer.create(math.max(expected, 64))
		local outCap = buffer.len(out)
		local op = 0
		local bitBuf, bitCnt = 0, 0

		local function ensure(extra: number)
			if op + extra <= outCap then
				return
			end
			local newCap = outCap
			while newCap < op + extra do
				newCap *= 2
			end
			local grown = buffer.create(newCap)
			buffer.copy(grown, 0, out, 0, op)
			out, outCap = grown, newCap
		end

		local function bits(n: number): number
			while bitCnt < n do
				if pos >= srcLen + 4 then
					error("inflate: truncated data")
				end
				local byte = if pos < srcLen then buffer.readu8(src, pos) else 0
				pos += 1
				bitBuf += bit32.lshift(byte, bitCnt)
				bitCnt += 8
			end
			local v = bit32.band(bitBuf, bit32.lshift(1, n) - 1)
			bitBuf = bit32.rshift(bitBuf, n)
			bitCnt -= n
			return v
		end

		local function decode(h): number
			local count, symbol = h.count, h.symbol
			local code, first, index = 0, 0, 0
			for len = 1, 15 do
				if bitCnt == 0 then
					if pos >= srcLen then
						error("inflate: truncated data")
					end
					bitBuf = buffer.readu8(src, pos)
					pos += 1
					bitCnt = 8
				end
				code += bit32.band(bitBuf, 1)
				bitBuf = bit32.rshift(bitBuf, 1)
				bitCnt -= 1
				local c = count[len]
				if code - c < first then
					return symbol[index + code - first + 1]
				end
				index += c
				first = (first + c) * 2
				code *= 2
			end
			error("inflate: bad huffman code")
		end

		local function codes(lit, dist)
			local ticks = 0
			while true do
				local sym = decode(lit)
				if sym < 256 then
					if op >= outCap then
						ensure(1)
					end
					buffer.writeu8(out, op, sym)
					op += 1
				elseif sym == 256 then
					return
				else
					sym -= 256
					if sym > 29 then
						error("inflate: bad length symbol")
					end
					local len = LEN_BASE[sym] + bits(LEN_EXTRA[sym])
					local dsym = decode(dist) + 1
					if dsym > 30 then
						error("inflate: bad distance symbol")
					end
					local d = DIST_BASE[dsym] + bits(DIST_EXTRA[dsym])
					if d > op then
						error("inflate: distance too far back")
					end
					ensure(len)
					if d >= len then
						buffer.copy(out, op, out, op - d, len)
					else
						for k = 0, len - 1 do
							buffer.writeu8(out, op + k, buffer.readu8(out, op - d + k))
						end
					end
					op += len
				end
				ticks += 1
				if ticks >= 8192 then
					ticks = 0
					yielder()
				end
			end
		end

		local function stored()
			pos -= bitCnt // 8 -- hand back whole bytes the bit reader pre-loaded
			bitBuf, bitCnt = 0, 0
			if pos + 4 > srcLen then
				error("inflate: truncated stored block")
			end
			local len = buffer.readu16(src, pos)
			pos += 4
			if pos + len > srcLen then
				error("inflate: truncated stored block")
			end
			ensure(len)
			buffer.copy(out, op, src, pos, len)
			op += len
			pos += len
		end

		local function dynamic()
			local nlen = bits(5) + 257
			local ndist = bits(5) + 1
			local ncode = bits(4) + 4
			if nlen > 286 or ndist > 30 then
				error("inflate: bad table sizes")
			end
			local clLengths = table.create(19, 0)
			for i = 1, ncode do
				clLengths[CL_ORDER[i] + 1] = bits(3)
			end
			local clCode = build(clLengths, 1, 19)
			local total = nlen + ndist
			local lengths = table.create(total, 0)
			local index = 1
			while index <= total do
				local sym = decode(clCode)
				if sym < 16 then
					lengths[index] = sym
					index += 1
				else
					local len, rep = 0, 0
					if sym == 16 then
						if index == 1 then
							error("inflate: repeat without a previous length")
						end
						len = lengths[index - 1]
						rep = 3 + bits(2)
					elseif sym == 17 then
						rep = 3 + bits(3)
					else
						rep = 11 + bits(7)
					end
					if index + rep - 1 > total then
						error("inflate: too many lengths")
					end
					for _ = 1, rep do
						lengths[index] = len
						index += 1
					end
				end
			end
			codes(build(lengths, 1, nlen), build(lengths, nlen + 1, ndist))
		end

		local last
		repeat
			last = bits(1)
			local btype = bits(2)
			if btype == 0 then
				stored()
			elseif btype == 1 then
				codes(FIXED_LIT, FIXED_DIST)
			elseif btype == 2 then
				dynamic()
			else
				error("inflate: bad block type")
			end
			yielder()
		until last == 1
		return out, op
	end
end

---------------------------------------------------------------------------------------------------
-- PNG decoder (all colour types, 1-16 bit, non-interlaced) -> RGBA8 buffer
---------------------------------------------------------------------------------------------------
local Png = {}
do
	local SIGNATURE = "\137PNG\r\n\26\n"
	local CHANNELS = { [0] = 1, [2] = 3, [3] = 1, [4] = 2, [6] = 4 }

	local function u32be(b: buffer, p: number): number
		return bit32.byteswap(buffer.readu32(b, p))
	end

	function Png.is(b: buffer): boolean
		return buffer.len(b) >= 8 and buffer.readstring(b, 0, 8) == SIGNATURE
	end

	function Png.decode(b: buffer, yielder: () -> ()): (number, number, buffer)
		local len = buffer.len(b)
		local pos = 8
		local w, h, depth, ctype, interlace
		local palette, trns
		local idat, idatLen = {}, 0
		while pos + 8 <= len do
			local clen = u32be(b, pos)
			local tag = buffer.readstring(b, pos + 4, 4)
			local data = pos + 8
			if data + clen > len then
				error("png: truncated chunk " .. tag)
			end
			if tag == "IHDR" then
				w, h = u32be(b, data), u32be(b, data + 4)
				depth, ctype = buffer.readu8(b, data + 8), buffer.readu8(b, data + 9)
				interlace = buffer.readu8(b, data + 12)
			elseif tag == "PLTE" then
				palette = buffer.create(clen)
				buffer.copy(palette, 0, b, data, clen)
			elseif tag == "tRNS" then
				trns = buffer.create(clen)
				buffer.copy(trns, 0, b, data, clen)
			elseif tag == "IDAT" then
				table.insert(idat, { data, clen })
				idatLen += clen
			elseif tag == "IEND" then
				break
			end
			pos = data + clen + 4
		end
		if not w then
			error("png: missing IHDR")
		end
		if interlace ~= 0 then
			error("png: interlaced")
		end
		local channels = CHANNELS[ctype]
		if not channels then
			error("png: bad colour type")
		end
		if w * h > 4_000_000 then
			error("png: image too large")
		end

		local z = buffer.create(idatLen)
		local zp = 0
		for _, part in idat do
			buffer.copy(z, zp, b, part[1], part[2])
			zp += part[2]
		end

		local bitsPerPixel = channels * depth
		local rowBytes = (w * bitsPerPixel + 7) // 8
		local bpp = math.max(1, bitsPerPixel // 8)
		local stride = rowBytes + 1
		local raw, rawLen = Inflate.zlib(z, 0, h * stride, yielder)
		if rawLen < h * stride then
			error("png: not enough pixel data")
		end

		-- Undo the per-row filters in place (rows are processed top-down, so the row above is final).
		for y = 0, h - 1 do
			local cur = y * stride + 1
			local prev = cur - stride
			local filter = buffer.readu8(raw, cur - 1)
			if filter == 1 then
				for i = bpp, rowBytes - 1 do
					buffer.writeu8(raw, cur + i, (buffer.readu8(raw, cur + i) + buffer.readu8(raw, cur + i - bpp)) % 256)
				end
			elseif filter == 2 then
				if y > 0 then
					for i = 0, rowBytes - 1 do
						buffer.writeu8(raw, cur + i, (buffer.readu8(raw, cur + i) + buffer.readu8(raw, prev + i)) % 256)
					end
				end
			elseif filter == 3 then
				for i = 0, rowBytes - 1 do
					local left = if i >= bpp then buffer.readu8(raw, cur + i - bpp) else 0
					local above = if y > 0 then buffer.readu8(raw, prev + i) else 0
					buffer.writeu8(raw, cur + i, (buffer.readu8(raw, cur + i) + (left + above) // 2) % 256)
				end
			elseif filter == 4 then
				for i = 0, rowBytes - 1 do
					local a = if i >= bpp then buffer.readu8(raw, cur + i - bpp) else 0
					local bb = if y > 0 then buffer.readu8(raw, prev + i) else 0
					local c = if i >= bpp and y > 0 then buffer.readu8(raw, prev + i - bpp) else 0
					local p = a + bb - c
					local pa, pb, pc = math.abs(p - a), math.abs(p - bb), math.abs(p - c)
					local pred = if pa <= pb and pa <= pc then a elseif pb <= pc then bb else c
					buffer.writeu8(raw, cur + i, (buffer.readu8(raw, cur + i) + pred) % 256)
				end
			elseif filter ~= 0 then
				error("png: bad filter " .. filter)
			end
			if y % 16 == 0 then
				yielder()
			end
		end

		local maxSample = 2 ^ depth - 1
		local function sample(rowData: number, index: number): number
			if depth == 8 then
				return buffer.readu8(raw, rowData + index)
			elseif depth == 16 then
				return buffer.readu8(raw, rowData + index * 2) -- high byte
			end
			local bitPos = index * depth
			local byte = buffer.readu8(raw, rowData + bitPos // 8)
			return bit32.band(bit32.rshift(byte, 8 - depth - bitPos % 8), maxSample)
		end
		local trnsLen = if trns then buffer.len(trns) else 0
		local keyR, keyG, keyB = -1, -1, -1
		if trns and depth == 8 then
			if ctype == 0 and trnsLen >= 2 then
				keyR = buffer.readu8(trns, 1)
			elseif ctype == 2 and trnsLen >= 6 then
				keyR, keyG, keyB = buffer.readu8(trns, 1), buffer.readu8(trns, 3), buffer.readu8(trns, 5)
			end
		end

		local out = buffer.create(w * h * 4)
		for y = 0, h - 1 do
			local rowData = y * stride + 1
			local o = y * w * 4
			for x = 0, w - 1 do
				local r, g, bl, a
				if ctype == 3 then
					local i = sample(rowData, x)
					if palette and i * 3 + 2 < buffer.len(palette) then
						r, g, bl = buffer.readu8(palette, i * 3), buffer.readu8(palette, i * 3 + 1), buffer.readu8(palette, i * 3 + 2)
					else
						r, g, bl = 0, 0, 0
					end
					a = if i < trnsLen then buffer.readu8(trns, i) else 255
				elseif ctype == 0 or ctype == 4 then
					local v = sample(rowData, x * channels)
					a = if ctype == 4 then sample(rowData, x * 2 + 1) elseif v == keyR then 0 else 255
					if depth < 8 then
						v = v * 255 // maxSample
					end
					r, g, bl = v, v, v
				else
					local base = x * channels
					r, g, bl = sample(rowData, base), sample(rowData, base + 1), sample(rowData, base + 2)
					a = if ctype == 6 then sample(rowData, base + 3)
						elseif r == keyR and g == keyG and bl == keyB then 0
						else 255
				end
				buffer.writeu8(out, o, r)
				buffer.writeu8(out, o + 1, g)
				buffer.writeu8(out, o + 2, bl)
				buffer.writeu8(out, o + 3, a)
				o += 4
			end
			if y % 16 == 0 then
				yielder()
			end
		end
		return w, h, out
	end
end

---------------------------------------------------------------------------------------------------
-- Baseline JPEG decoder (Huffman, any sampling factors, restart markers) -> RGBA8 buffer
-- Progressive / CMYK JPEGs raise an error; the loader then falls back to a PNG-converting proxy.
---------------------------------------------------------------------------------------------------
local Jpeg = {}
do
	local ZIGZAG = {
		1, 2, 9, 17, 10, 3, 4, 11, 18, 25, 33, 26, 19, 12, 5, 6, 13, 20, 27, 34, 41, 49, 42, 35, 28, 21, 14, 7, 8, 15, 22, 29,
		36, 43, 50, 57, 58, 51, 44, 37, 30, 23, 16, 24, 31, 38, 45, 52, 59, 60, 53, 46, 39, 32, 40, 47, 54, 61, 62, 55, 48, 56, 63, 64,
	}
	-- COS[x*8 + u + 1] = C(u) * cos((2x+1)uπ/16) / 2 — the separable 8-point IDCT basis.
	local COS = table.create(64, 0)
	for x = 0, 7 do
		for u = 0, 7 do
			local cu = if u == 0 then 1 / math.sqrt(2) else 1
			COS[x * 8 + u + 1] = cu * math.cos((2 * x + 1) * u * math.pi / 16) / 2
		end
	end

	local function u16be(b: buffer, p: number): number
		return buffer.readu8(b, p) * 256 + buffer.readu8(b, p + 1)
	end

	local function buildHuffman(counts: { number }, symbols: { number })
		local maxcode = table.create(16, -1)
		local valptr = table.create(16, 0)
		local mincode = table.create(16, 0)
		local code, k = 0, 0
		for l = 1, 16 do
			local c = counts[l]
			if c > 0 then
				valptr[l] = k
				mincode[l] = code
				code += c
				k += c
				maxcode[l] = code - 1
			end
			code *= 2
		end
		return { maxcode = maxcode, valptr = valptr, mincode = mincode, symbols = symbols }
	end

	function Jpeg.is(b: buffer): boolean
		return buffer.len(b) > 3 and buffer.readu8(b, 0) == 0xFF and buffer.readu8(b, 1) == 0xD8
	end

	function Jpeg.decode(b: buffer, yielder: () -> ()): (number, number, buffer)
		local len = buffer.len(b)
		local qt = {}
		local dcTables, acTables = {}, {}
		local frame
		local restartInterval = 0
		local decoded = false
		local pos = 2

		local function decodeScan(scanComps)
			local bitBuf, bitCnt = 0, 0

			local function readBit(): number
				if bitCnt == 0 then
					local byte = 0
					if pos < len then
						byte = buffer.readu8(b, pos)
						if byte == 0xFF then
							local nxt = if pos + 1 < len then buffer.readu8(b, pos + 1) else 0
							if nxt == 0 then
								pos += 2
							else
								byte = 0 -- hit a marker: feed zeros, leave the marker for the caller
							end
						else
							pos += 1
						end
					end
					bitBuf, bitCnt = byte, 8
				end
				bitCnt -= 1
				return bit32.extract(bitBuf, bitCnt, 1)
			end

			local function receive(n: number): number
				local v = 0
				for _ = 1, n do
					v = v * 2 + readBit()
				end
				return v
			end

			local function extend(v: number, t: number): number
				if v < bit32.lshift(1, t - 1) then
					return v - bit32.lshift(1, t) + 1
				end
				return v
			end

			local function decodeHuff(h): number
				local maxcode, valptr, mincode = h.maxcode, h.valptr, h.mincode
				local code = readBit()
				for l = 1, 16 do
					if code <= maxcode[l] then
						return h.symbols[valptr[l] + code - mincode[l] + 1]
					end
					code = code * 2 + readBit()
				end
				error("jpeg: bad huffman code")
			end

			local block = table.create(64, 0)
			local tmp = table.create(64, 0)

			local function decodeBlockInto(comp, plane: buffer, planeW: number, ox: number, oy: number)
				for i = 1, 64 do
					block[i] = 0
				end
				local q = comp.q
				local t = decodeHuff(comp.dc)
				local diff = if t == 0 then 0 else extend(receive(t), t)
				comp.pred += diff
				block[1] = comp.pred * q[1]
				local k = 2
				local ac = comp.ac
				while k <= 64 do
					local rs = decodeHuff(ac)
					local s = bit32.band(rs, 15)
					local r = bit32.rshift(rs, 4)
					if s == 0 then
						if r ~= 15 then
							break
						end
						k += 16
					else
						k += r
						if k > 64 then
							break
						end
						block[ZIGZAG[k]] = extend(receive(s), s) * q[k]
						k += 1
					end
				end
				-- Rows (vertical frequency v) first, then columns.
				for v = 0, 7 do
					local rowOff = v * 8
					for x = 0, 7 do
						local cOff = x * 8
						local s = 0
						for u = 1, 8 do
							s += COS[cOff + u] * block[rowOff + u]
						end
						tmp[rowOff + x + 1] = s
					end
				end
				for x = 0, 7 do
					for y = 0, 7 do
						local cOff = y * 8
						local s = 0
						for v = 0, 7 do
							s += COS[cOff + v + 1] * tmp[v * 8 + x + 1]
						end
						local val = math.floor(s + 128.5)
						buffer.writeu8(plane, (oy + y) * planeW + ox + x, if val < 0 then 0 elseif val > 255 then 255 else val)
					end
				end
			end

			local function resync()
				bitBuf, bitCnt = 0, 0
				while pos + 1 < len do
					if buffer.readu8(b, pos) == 0xFF then
						local m = buffer.readu8(b, pos + 1)
						if m >= 0xD0 and m <= 0xD7 then
							pos += 2
							break
						elseif m ~= 0 and m ~= 0xFF then
							break -- a non-restart marker: let the outer parser deal with it
						end
					end
					pos += 1
				end
				for _, c in scanComps do
					c.pred = 0
				end
			end

			for _, c in scanComps do
				c.pred = 0
			end
			local mcuCount = 0
			local single = #scanComps == 1
			if single and frame.ncomp ~= 1 then
				error("jpeg: non-interleaved scans are not supported")
			end
			for my = 0, frame.mcusY - 1 do
				for mx = 0, frame.mcusX - 1 do
					if restartInterval > 0 and mcuCount > 0 and mcuCount % restartInterval == 0 then
						resync()
					end
					mcuCount += 1
					for _, c in scanComps do
						for by = 0, c.v - 1 do
							for bx = 0, c.h - 1 do
								decodeBlockInto(c, c.plane, c.bw, (mx * c.h + bx) * 8, (my * c.v + by) * 8)
							end
						end
					end
				end
				yielder()
			end
			-- Skip to the next real marker.
			while pos + 1 < len do
				if buffer.readu8(b, pos) == 0xFF then
					local m = buffer.readu8(b, pos + 1)
					if m ~= 0 and not (m >= 0xD0 and m <= 0xD7) and m ~= 0xFF then
						break
					end
				end
				pos += 1
			end
		end

		while pos + 1 < len do
			if buffer.readu8(b, pos) ~= 0xFF then
				pos += 1
				continue
			end
			local marker = buffer.readu8(b, pos + 1)
			pos += 2
			if marker == 0xFF then
				pos -= 1 -- fill byte
				continue
			end
			if marker == 0xD8 or marker == 0x01 or (marker >= 0xD0 and marker <= 0xD7) then
				continue
			end
			if marker == 0xD9 then
				break
			end
			local segEnd = pos + u16be(b, pos)
			local p = pos + 2
			if marker == 0xDB then
				while p < segEnd do
					local pqtq = buffer.readu8(b, p)
					p += 1
					local wide = bit32.rshift(pqtq, 4) ~= 0
					local t = table.create(64, 0)
					for i = 1, 64 do
						if wide then
							t[i] = u16be(b, p)
							p += 2
						else
							t[i] = buffer.readu8(b, p)
							p += 1
						end
					end
					qt[bit32.band(pqtq, 15)] = t
				end
			elseif marker == 0xC0 or marker == 0xC1 then
				local fh, fw = u16be(b, p + 1), u16be(b, p + 3)
				local ncomp = buffer.readu8(b, p + 5)
				if ncomp ~= 1 and ncomp ~= 3 then
					error("jpeg: unsupported component count " .. ncomp)
				end
				local comps, byId = {}, {}
				local hmax, vmax = 1, 1
				for i = 0, ncomp - 1 do
					local base = p + 6 + i * 3
					local hv = buffer.readu8(b, base + 1)
					local c = {
						id = buffer.readu8(b, base),
						h = bit32.rshift(hv, 4),
						v = bit32.band(hv, 15),
						tq = buffer.readu8(b, base + 2),
						pred = 0,
					}
					hmax, vmax = math.max(hmax, c.h), math.max(vmax, c.v)
					comps[i + 1] = c
					byId[c.id] = c
				end
				local mcusX = math.ceil(fw / (8 * hmax))
				local mcusY = math.ceil(fh / (8 * vmax))
				for _, c in comps do
					c.bw = mcusX * c.h * 8
					c.bh = mcusY * c.v * 8
					c.plane = buffer.create(c.bw * c.bh)
				end
				if fw * fh > 4_000_000 then
					error("jpeg: image too large")
				end
				frame = { w = fw, h = fh, ncomp = ncomp, comps = comps, byId = byId, hmax = hmax, vmax = vmax, mcusX = mcusX, mcusY = mcusY }
			elseif marker == 0xC2 or marker == 0xC3 or (marker >= 0xC5 and marker <= 0xC7) or (marker >= 0xC9 and marker <= 0xCB) or (marker >= 0xCD and marker <= 0xCF) then
				error("jpeg: progressive/arithmetic JPEG")
			elseif marker == 0xC4 then
				while p < segEnd do
					local tcth = buffer.readu8(b, p)
					p += 1
					local counts, total = table.create(16, 0), 0
					for i = 1, 16 do
						counts[i] = buffer.readu8(b, p + i - 1)
						total += counts[i]
					end
					p += 16
					local symbols = table.create(total, 0)
					for i = 1, total do
						symbols[i] = buffer.readu8(b, p + i - 1)
					end
					p += total
					local tbl = buildHuffman(counts, symbols)
					if bit32.rshift(tcth, 4) == 0 then
						dcTables[bit32.band(tcth, 15)] = tbl
					else
						acTables[bit32.band(tcth, 15)] = tbl
					end
				end
			elseif marker == 0xDD then
				restartInterval = u16be(b, p)
			elseif marker == 0xDA then
				if not frame then
					error("jpeg: scan before frame header")
				end
				local ns = buffer.readu8(b, p)
				local scanComps = {}
				for i = 0, ns - 1 do
					local cid = buffer.readu8(b, p + 1 + i * 2)
					local tdta = buffer.readu8(b, p + 2 + i * 2)
					local c = frame.byId[cid]
					if not c then
						error("jpeg: unknown component in scan")
					end
					c.dc = dcTables[bit32.rshift(tdta, 4)]
					c.ac = acTables[bit32.band(tdta, 15)]
					c.q = qt[c.tq]
					if not (c.dc and c.ac and c.q) then
						error("jpeg: missing tables")
					end
					table.insert(scanComps, c)
				end
				pos = segEnd
				decodeScan(scanComps)
				decoded = true
				continue
			end
			pos = segEnd
		end
		if not (frame and decoded) then
			error("jpeg: no image data")
		end

		local w, h = frame.w, frame.h
		local out = buffer.create(w * h * 4)
		local comps, hmax, vmax = frame.comps, frame.hmax, frame.vmax
		local c1, c2, c3 = comps[1], comps[2], comps[3]
		for y = 0, h - 1 do
			local o = y * w * 4
			local row1 = (y * c1.v // vmax) * c1.bw
			if frame.ncomp == 1 then
				for x = 0, w - 1 do
					local v = buffer.readu8(c1.plane, row1 + x)
					buffer.writeu8(out, o, v)
					buffer.writeu8(out, o + 1, v)
					buffer.writeu8(out, o + 2, v)
					buffer.writeu8(out, o + 3, 255)
					o += 4
				end
			else
				local row2 = (y * c2.v // vmax) * c2.bw
				local row3 = (y * c3.v // vmax) * c3.bw
				for x = 0, w - 1 do
					local yy = buffer.readu8(c1.plane, row1 + x * c1.h // hmax)
					local cb = buffer.readu8(c2.plane, row2 + x * c2.h // hmax) - 128
					local cr = buffer.readu8(c3.plane, row3 + x * c3.h // hmax) - 128
					buffer.writeu8(out, o, math.clamp(math.floor(yy + 1.402 * cr + 0.5), 0, 255))
					buffer.writeu8(out, o + 1, math.clamp(math.floor(yy - 0.344136 * cb - 0.714136 * cr + 0.5), 0, 255))
					buffer.writeu8(out, o + 2, math.clamp(math.floor(yy + 1.772 * cb + 0.5), 0, 255))
					buffer.writeu8(out, o + 3, 255)
					o += 4
				end
			end
			if y % 32 == 0 then
				yielder()
			end
		end
		return w, h, out
	end
end

---------------------------------------------------------------------------------------------------
-- Image processing: resample to the paint grid, optional "realism" enhancement
---------------------------------------------------------------------------------------------------
---------------------------------------------------------------------------------------------------
-- LightingFx: the game's post effects change how paint looks. Its ColorCorrection adds +5 %
-- saturation and contrast for everyone, the warm Atmosphere haze, Bloom and SunRays glow on top.
-- compensation() lists the colour corrections everyone sees, so pictures can be pre-corrected;
-- setClean() turns the effects off on YOUR screen only (restored when off / on unload).
---------------------------------------------------------------------------------------------------
local LightingFx = {}
do
	local Lighting = game:GetService("Lighting")
	local CLEAN_CLASSES = table.freeze({ "BloomEffect", "SunRaysEffect", "ColorCorrectionEffect", "DepthOfFieldEffect" })
	-- what clean view changed: instance -> { property -> original value }
	local changed: { [Instance]: { [string]: any } } = {}
	local cleanOn = false

	local function effects(): { Instance }
		local list = Lighting:GetChildren()
		local cam = workspace.CurrentCamera
		if cam then
			for _, child in cam:GetChildren() do
				table.insert(list, child)
			end
		end
		return list
	end

	-- The ColorCorrection effects other players see (clean view's changes don't count).
	function LightingFx.compensation(): { { brightness: number, contrast: number, saturation: number, tintR: number, tintG: number, tintB: number } }
		local list = {}
		for _, fx in effects() do
			if not fx:IsA("ColorCorrectionEffect") then
				continue
			end
			local original = changed[fx]
			local enabled = if original and original.Enabled ~= nil then original.Enabled else fx.Enabled
			if enabled then
				local tint = fx.TintColor
				table.insert(list, {
					brightness = fx.Brightness,
					contrast = fx.Contrast,
					saturation = fx.Saturation,
					tintR = tint.R,
					tintG = tint.G,
					tintB = tint.B,
				})
			end
		end
		return list
	end

	local function set(inst: Instance, prop: string, value: any)
		local entry = changed[inst]
		if not entry then
			entry = {}
			changed[inst] = entry
		end
		local target: any = inst
		if entry[prop] == nil then
			entry[prop] = target[prop]
		end
		target[prop] = value
	end

	function LightingFx.setClean(on: boolean)
		if on == cleanOn then
			return
		end
		cleanOn = on
		if on then
			for _, fx in effects() do
				if fx:IsA("Atmosphere") then
					set(fx, "Density", 0)
				else
					for _, className in CLEAN_CLASSES do
						if fx:IsA(className) and (fx :: any).Enabled then
							set(fx, "Enabled", false)
							break
						end
					end
				end
			end
			return
		end
		for inst, props in changed do
			for prop, value in props do
				-- the instance may be gone, or the game may have changed it since (keep the game's)
				pcall(function()
					local target: any = inst
					if prop ~= "Enabled" or target.Enabled == false then
						target[prop] = value
					end
				end)
			end
		end
		table.clear(changed)
	end
end
maid:Give(function()
	LightingFx.setClean(false)
end)

---------------------------------------------------------------------------------------------------
-- Sponge on all layers. The game's Eraser finds paint with an OverlapParams whose filter it sets
-- every frame to { yourPaint[currentLayer] } (or to everyone's paint with the moderators' "erase
-- other art" option). While spongeAllLayers is on, a filter of exactly one of YOUR layer folders is
-- widened to your whole paint folder, so the sponge wipes your paint on every layer at once.
-- Nothing else is touched: only that one property assignment on OverlapParams objects.
---------------------------------------------------------------------------------------------------
do
	local paintFolder = workspace:FindFirstChild("PaintFolder")
	if type(hookmetamethod) == "function" and paintFolder then
		local wrap = if type(newcclosure) == "function" then newcclosure else function(f)
			return f
		end
		-- { yourLayerFolder } -> { yourPaintFolder }, anything else -> nil (left as it is)
		local function widened(value: any): { Instance }?
			if type(value) ~= "table" or #value ~= 1 then
				return nil
			end
			local layer = value[1]
			if typeof(layer) ~= "Instance" or not layer:IsA("Folder") then
				return nil
			end
			local mine = layer.Parent
			if mine and mine.Parent == paintFolder and mine.Name == LocalPlayer.Name then
				return { mine }
			end
			return nil
		end
		local oldNewIndex: any
		oldNewIndex = hookmetamethod(OverlapParams.new(), "__newindex", wrap(function(self, key, value)
			if key == "FilterDescendantsInstances" and Settings.spongeAllLayers then
				local ok, wide = pcall(widened, value)
				if ok and wide then
					return oldNewIndex(self, key, wide)
				end
			end
			return oldNewIndex(self, key, value)
		end))
		maid:Give(function()
			hookmetamethod(OverlapParams.new(), "__newindex", oldNewIndex)
		end)
	end
end

local Imaging = {}
do
	function Imaging.decode(body: string, yielder: () -> ()): (number, number, buffer)
		local b = buffer.fromstring(body)
		if Png.is(b) then
			return Png.decode(b, yielder)
		elseif Jpeg.is(b) then
			return Jpeg.decode(b, yielder)
		end
		error("unsupported image format")
	end

	-- Numbers every visible pixel of rendered text by the character it belongs to, left to right,
	-- line by line: lines are separated by fully transparent rows, characters by fully transparent
	-- columns within a line (touching characters count as one).
	function Imaging.letters(rgba: buffer, w: number, h: number): { number }
		local letterOf = table.create(w * h, 0)
		local function visible(x: number, y: number): boolean
			return buffer.readu8(rgba, (y * w + x) * 4 + 3) >= 128
		end
		local nextLetter = 0
		local y = 0
		while y < h do
			-- next band of rows that contain something
			local rowHas = false
			for x = 0, w - 1 do
				if visible(x, y) then
					rowHas = true
					break
				end
			end
			if not rowHas then
				y += 1
				continue
			end
			local top = y
			while y < h do
				local has = false
				for x = 0, w - 1 do
					if visible(x, y) then
						has = true
						break
					end
				end
				if not has then
					break
				end
				y += 1
			end
			local bottom = y - 1
			-- characters = runs of columns with something in this band
			local inLetter = false
			for x = 0, w - 1 do
				local colHas = false
				for yy = top, bottom do
					if visible(x, yy) then
						colHas = true
						break
					end
				end
				if colHas and not inLetter then
					nextLetter += 1
				end
				inLetter = colHas
				if colHas then
					for yy = top, bottom do
						if visible(x, yy) then
							letterOf[yy * w + x + 1] = nextLetter
						end
					end
				end
			end
		end
		return letterOf
	end

	-- Crops to the bounding box of the visible pixels (alpha >= 40) plus `pad` pixels.
	function Imaging.trim(rgba: buffer, w: number, h: number, pad: number): (number, number, buffer)
		local minX, minY, maxX, maxY = w, h, -1, -1
		for y = 0, h - 1 do
			for x = 0, w - 1 do
				if buffer.readu8(rgba, (y * w + x) * 4 + 3) >= 40 then
					if x < minX then
						minX = x
					end
					if x > maxX then
						maxX = x
					end
					if y < minY then
						minY = y
					end
					if y > maxY then
						maxY = y
					end
				end
			end
		end
		if maxX < 0 then
			return w, h, rgba -- nothing visible
		end
		minX, minY = math.max(0, minX - pad), math.max(0, minY - pad)
		maxX, maxY = math.min(w - 1, maxX + pad), math.min(h - 1, maxY + pad)
		local tw, th = maxX - minX + 1, maxY - minY + 1
		local out = buffer.create(tw * th * 4)
		for y = 0, th - 1 do
			buffer.copy(out, y * tw * 4, rgba, ((minY + y) * w + minX) * 4, tw * 4)
		end
		return tw, th, out
	end


	-- Area-average downscale (alpha-weighted so transparent edges don't bleed dark fringes).
	function Imaging.resample(src: buffer, sw: number, sh: number, tw: number, th: number, yielder: () -> ()): buffer
		local out = buffer.create(tw * th * 4)
		local sx, sy = sw / tw, sh / th
		for ty = 0, th - 1 do
			local y0 = math.floor(ty * sy)
			local y1 = math.clamp(math.ceil((ty + 1) * sy), y0 + 1, sh)
			for tx = 0, tw - 1 do
				local x0 = math.floor(tx * sx)
				local x1 = math.clamp(math.ceil((tx + 1) * sx), x0 + 1, sw)
				local r, g, bl, a, n = 0, 0, 0, 0, 0
				for y = y0, y1 - 1 do
					local o = (y * sw + x0) * 4
					for _ = x0, x1 - 1 do
						local pa = buffer.readu8(src, o + 3)
						r += buffer.readu8(src, o) * pa
						g += buffer.readu8(src, o + 1) * pa
						bl += buffer.readu8(src, o + 2) * pa
						a += pa
						n += 1
						o += 4
					end
				end
				local o = (ty * tw + tx) * 4
				if a > 0 then
					buffer.writeu8(out, o, math.floor(r / a + 0.5))
					buffer.writeu8(out, o + 1, math.floor(g / a + 0.5))
					buffer.writeu8(out, o + 2, math.floor(bl / a + 0.5))
				end
				buffer.writeu8(out, o + 3, math.floor(a / n + 0.5))
			end
			yielder()
		end
		return out
	end

	-- Colour pipeline before quantizing (all optional, see processImage):
	--   • a light unsharp mask: downscaled photos look soft on a wall,
	--   • a shadow lift: the paint sits in the game's lighting, dark tones crush to black,
	--   • undoing the game's ColorCorrection effects in reverse order (Roblox applies brightness,
	--     contrast, saturation, then tint), so the corrected colour on screen matches the source.
	-- There is deliberately no saturation boost: on top of the game's own +5 % it turned warm
	-- pictures orange with a glowing "glint".
	function Imaging.adjust(img: buffer, w: number, h: number, opts: { sharpen: number, gamma: number, corrections: { any } }, yielder: () -> ()): buffer
		local out = buffer.create(w * h * 4)
		local sharpen, gamma, corrections = opts.sharpen, opts.gamma, opts.corrections
		local function sample(o: number, up: number, down: number, left: number, right: number, c: number): number
			local v = buffer.readu8(img, o + c)
			if sharpen > 0 then
				local blur = (buffer.readu8(img, up + c) + buffer.readu8(img, down + c) + buffer.readu8(img, left + c) + buffer.readu8(img, right + c)) / 4
				v += (v - blur) * sharpen
			end
			return math.clamp(v / 255, 0, 1)
		end
		for y = 0, h - 1 do
			for x = 0, w - 1 do
				local o = (y * w + x) * 4
				local up = if y > 0 then o - w * 4 else o
				local down = if y < h - 1 then o + w * 4 else o
				local left = if x > 0 then o - 4 else o
				local right = if x < w - 1 then o + 4 else o
				local r = sample(o, up, down, left, right, 0)
				local g = sample(o, up, down, left, right, 1)
				local b = sample(o, up, down, left, right, 2)
				if gamma ~= 1 then
					r, g, b = r ^ gamma, g ^ gamma, b ^ gamma
				end
				for k = #corrections, 1, -1 do
					local cc = corrections[k]
					r /= math.max(cc.tintR, 0.05)
					g /= math.max(cc.tintG, 0.05)
					b /= math.max(cc.tintB, 0.05)
					local sat = 1 + cc.saturation
					if sat > 0.05 then
						local lum = 0.299 * r + 0.587 * g + 0.114 * b
						r, g, b = lum + (r - lum) / sat, lum + (g - lum) / sat, lum + (b - lum) / sat
					end
					local contrast = 1 + cc.contrast
					if contrast > 0.05 then
						r, g, b = (r - 0.5) / contrast + 0.5, (g - 0.5) / contrast + 0.5, (b - 0.5) / contrast + 0.5
					end
					r, g, b = r - cc.brightness, g - cc.brightness, b - cc.brightness
				end
				buffer.writeu8(out, o, math.clamp(math.floor(r * 255 + 0.5), 0, 255))
				buffer.writeu8(out, o + 1, math.clamp(math.floor(g * 255 + 0.5), 0, 255))
				buffer.writeu8(out, o + 2, math.clamp(math.floor(b * 255 + 0.5), 0, 255))
				buffer.writeu8(out, o + 3, buffer.readu8(img, o + 3))
			end
			yielder()
		end
		return out
	end

	-- Nearest palette colour by "redmean" weighted RGB, a cheap approximation of how different two
	-- colours look (plain luminance weights nearly ignored blue, so pixels got the wrong hue).
	-- Results are cached per 4-level RGB bucket (at most 1.5 % off, far fewer palette searches).
	local function nearestFinder(palette: { { number } }): (number, number, number) -> number
		local cache: { [number]: number } = {}
		return function(r: number, g: number, b: number): number
			r = math.clamp(math.floor(r + 0.5), 0, 255)
			g = math.clamp(math.floor(g + 0.5), 0, 255)
			b = math.clamp(math.floor(b + 0.5), 0, 255)
			local key = (r // 4) * 4096 + (g // 4) * 64 + b // 4
			local hit = cache[key]
			if hit then
				return hit
			end
			local best, bestDist = 1, math.huge
			for index, p in palette do
				local rmean = (r + p[1]) * 0.5
				local dr, dg, db = r - p[1], g - p[2], b - p[3]
				local dist = (2 + rmean / 256) * dr * dr + 4 * dg * dg + (2 + (255 - rmean) / 256) * db * db
				if dist < bestDist then
					best, bestDist = index, dist
				end
			end
			cache[key] = best
			return best
		end
	end

	-- Picks up to maxColors colours for the picture: median cut, refined with k-means. Needed
	-- because the server keeps only ONE colour per paint batch, so the painter sprays the picture
	-- colour by colour — fewer colours = fewer colour switches. Pixels with alpha < 128 don't count
	-- when skipTransparent is set.
	function Imaging.buildPalette(img: buffer, w: number, h: number, maxColors: number, skipTransparent: boolean, yielder: () -> ()): { { number } }
		local n = w * h
		local opaque = table.create(n)
		for i = 0, n - 1 do
			if not skipTransparent or buffer.readu8(img, i * 4 + 3) >= 128 then
				opaque[#opaque + 1] = i
			end
		end
		if #opaque == 0 then
			return {}
		end

		local function channel(i: number, c: number): number
			return buffer.readu8(img, i * 4 + c)
		end
		local function measure(box)
			local lo, hi = { 255, 255, 255 }, { 0, 0, 0 }
			for _, i in box.list do
				for c = 1, 3 do
					local v = channel(i, c - 1)
					if v < lo[c] then
						lo[c] = v
					end
					if v > hi[c] then
						hi[c] = v
					end
				end
			end
			local widest, range = 1, -1
			for c = 1, 3 do
				if hi[c] - lo[c] > range then
					widest, range = c, hi[c] - lo[c]
				end
			end
			box.widest, box.range = widest, range
		end

		local boxes = { { list = opaque } }
		measure(boxes[1])
		while #boxes < maxColors do
			-- split the box with the widest colour spread (weighted a little by population)
			local bestIndex, bestScore = nil, 0
			for index, box in boxes do
				local score = box.range * math.sqrt(#box.list)
				if #box.list > 1 and box.range > 0 and score > bestScore then
					bestIndex, bestScore = index, score
				end
			end
			if not bestIndex then
				break
			end
			local box = boxes[bestIndex]
			local c = box.widest - 1
			table.sort(box.list, function(a, b)
				return channel(a, c) < channel(b, c)
			end)
			local half = #box.list // 2
			local upper = table.move(box.list, half + 1, #box.list, 1, table.create(#box.list - half))
			for k = #box.list, half + 1, -1 do
				box.list[k] = nil
			end
			local other = { list = upper }
			measure(box)
			measure(other)
			table.insert(boxes, other)
			yielder()
		end

		local palette = table.create(#boxes)
		for index, box in boxes do
			local r, g, b = 0, 0, 0
			for _, i in box.list do
				r += channel(i, 0)
				g += channel(i, 1)
				b += channel(i, 2)
			end
			local count = #box.list
			palette[index] = { r / count, g / count, b / count }
		end

		-- k-means: median-cut boxes are only a rough start; moving every palette colour to the
		-- average of the pixels nearest to it a few times makes the palette the picture's colours.
		for _ = 1, CONFIG.PALETTE_REFINE do
			local nearestIndex = nearestFinder(palette)
			local sums = table.create(#palette * 4, 0)
			for k, i in opaque do
				local r, g, b = channel(i, 0), channel(i, 1), channel(i, 2)
				local base = (nearestIndex(r, g, b) - 1) * 4
				sums[base + 1] += r
				sums[base + 2] += g
				sums[base + 3] += b
				sums[base + 4] += 1
				if k % 2048 == 0 then
					yielder()
				end
			end
			local moved = 0
			for index, p in palette do
				local base = (index - 1) * 4
				local count = sums[base + 4]
				if count > 0 then
					local r, g, b = sums[base + 1] / count, sums[base + 2] / count, sums[base + 3] / count
					moved = math.max(moved, math.abs(r - p[1]) + math.abs(g - p[2]) + math.abs(b - p[3]))
					p[1], p[2], p[3] = r, g, b
				end
			end
			if moved < 1 then
				break
			end
		end
		-- the game paints whole RGB values
		for _, p in palette do
			p[1] = math.clamp(math.floor(p[1] + 0.5), 0, 255)
			p[2] = math.clamp(math.floor(p[2] + 0.5), 0, 255)
			p[3] = math.clamp(math.floor(p[3] + 0.5), 0, 255)
		end
		return palette
	end

	-- Paints every pixel with its nearest palette colour, optionally Floyd–Steinberg dithered.
	-- Pixels with alpha < 128 stay transparent (alpha 0) when skipTransparent is set; all others
	-- become fully opaque palette colours. Returns the picture and how many colours it really uses.
	function Imaging.mapToPalette(img: buffer, w: number, h: number, palette: { { number } }, dither: boolean, skipTransparent: boolean, yielder: () -> ()): (buffer, number)
		local out = buffer.create(w * h * 4)
		if #palette == 0 then
			return out, 0
		end
		local nearestIndex = nearestFinder(palette)
		local used: { [number]: boolean } = {}
		local usedCount = 0
		-- Error buffers for the current and next row (index x + 2 leaves room for x - 1 / x + 1).
		-- Serpentine scan (every other row right to left) avoids diagonal "worm" patterns, and the
		-- damped, clamped error keeps flat areas from sparkling.
		local errCur = { table.create(w + 3, 0), table.create(w + 3, 0), table.create(w + 3, 0) }
		local errNext = { table.create(w + 3, 0), table.create(w + 3, 0), table.create(w + 3, 0) }
		local strength, limit = CONFIG.DITHER_STRENGTH, CONFIG.DITHER_CLAMP
		local function spread(c: number, x: number, dir: number, err: number)
			local e = math.clamp(err * strength, -limit, limit)
			local cur, nxt = errCur[c], errNext[c]
			cur[x + 2 + dir] += e * 7 / 16
			nxt[x + 2 - dir] += e * 3 / 16
			nxt[x + 2] += e * 5 / 16
			nxt[x + 2 + dir] += e * 1 / 16
		end
		for y = 0, h - 1 do
			local dir = if dither and y % 2 == 1 then -1 else 1
			local first, last = if dir == 1 then 0 else w - 1, if dir == 1 then w - 1 else 0
			for x = first, last, dir do
				local o = (y * w + x) * 4
				if skipTransparent and buffer.readu8(img, o + 3) < 128 then
					continue -- stays all-zero (transparent)
				end
				local r = buffer.readu8(img, o) + errCur[1][x + 2]
				local g = buffer.readu8(img, o + 1) + errCur[2][x + 2]
				local b = buffer.readu8(img, o + 2) + errCur[3][x + 2]
				local index = nearestIndex(r, g, b)
				if not used[index] then
					used[index] = true
					usedCount += 1
				end
				local p = palette[index]
				buffer.writeu8(out, o, p[1])
				buffer.writeu8(out, o + 1, p[2])
				buffer.writeu8(out, o + 2, p[3])
				buffer.writeu8(out, o + 3, 255)
				if dither then
					spread(1, x, dir, r - p[1])
					spread(2, x, dir, g - p[2])
					spread(3, x, dir, b - p[3])
				end
			end
			if dither then
				errCur, errNext = errNext, errCur
				for c = 1, 3 do
					local row = errNext[c]
					for k = 1, w + 3 do
						row[k] = 0
					end
				end
			end
			yielder()
		end
		return out, usedCount
	end

	-- Backwards-compatible one-shot: palette + mapping at the same size.
	function Imaging.quantize(img: buffer, w: number, h: number, maxColors: number, dither: boolean, skipTransparent: boolean, yielder: () -> ()): (buffer, number)
		local palette = Imaging.buildPalette(img, w, h, maxColors, skipTransparent, yielder)
		return Imaging.mapToPalette(img, w, h, palette, dither, skipTransparent, yielder)
	end
end

---------------------------------------------------------------------------------------------------
-- Image sources
---------------------------------------------------------------------------------------------------
local Sources = {}
do
	local function httpGet(url: string): string
		local ok, res = pcall(httpRequest, { Url = url, Method = "GET" })
		if not ok then
			error("request failed: " .. tostring(res), 0)
		end
		if type(res) ~= "table" then
			error("no response", 0)
		end
		local code = tonumber(res.StatusCode) or 0
		if code < 200 or code >= 300 then
			error(("HTTP %d"):format(code), 0)
		end
		return res.Body or ""
	end

	local function proxySize(): number
		local px = math.max(Settings.sizeX, Settings.sizeY) / (Settings.pixel * CONFIG.GRID_OVERLAP)
		return math.clamp(math.floor(px * 2), 240, 1000)
	end

	-- Direct decode first; anything our decoders can't read (webp, gif, progressive JPEG...)
	-- goes through images.weserv.nl which re-encodes it as a plain resized PNG.
	function Sources.fromUrl(url: string, yielder: () -> ()): (number, number, buffer)
		local okDirect, w, h, rgba = pcall(function()
			return Imaging.decode(httpGet(url), yielder)
		end)
		if okDirect then
			return w, h, rgba
		end
		local size = proxySize()
		local okProxy, pw, ph, prgba = pcall(function()
			return Imaging.decode(httpGet(CONFIG.WESERV:format(HttpService:UrlEncode(url), size, size)), yielder)
		end)
		if okProxy then
			return pw, ph, prgba
		end
		error(("couldn't load image (%s / proxy: %s)"):format(tostring(w), tostring(pw)), 0)
	end

	-- Renders the words big (typing \n starts a new line) and crops away the empty margins, so every
	-- painted pixel goes to the letters.
	function Sources.text(text: string, colorHex: string, yielder: () -> ()): (number, number, buffer)
		local lines = string.gsub(text, "\\n", "\n")
		local longest, count = 1, 0
		for line in string.gmatch(lines .. "\n", "(.-)\n") do
			longest = math.max(longest, utf8.len(line) or #line)
			count += 1
		end
		local w = math.clamp(longest * 110, 400, 4000)
		local h = math.clamp(count * 260, 200, 4000)
		local url = CONFIG.TEXT_URL:format(w, h, colorHex, HttpService:UrlEncode(lines), CONFIG.TEXT_FONT)
		local iw, ih, rgba = Imaging.decode(httpGet(url), yielder)
		return Imaging.trim(rgba, iw, ih, 8)
	end

	-- Finds a player from what was typed, in this order: the exact username / display name of someone
	-- in this server, any Roblox username, a user id (usernames can be all digits, so names win), then
	-- a username / display name in this server that starts with it. Returns the user id and username.
	local function resolveUser(query: string): (number, string)
		local q = query:gsub("^@", "")
		local lower = q:lower()
		for _, player in Players:GetPlayers() do
			if player.Name:lower() == lower or player.DisplayName:lower() == lower then
				return player.UserId, player.Name
			end
		end
		local ok, found = pcall(Players.GetUserIdFromNameAsync, Players, q)
		if ok and found then
			return found, q
		end
		local id = tonumber(q)
		if id then
			local okName, name = pcall(Players.GetNameFromUserIdAsync, Players, id)
			if okName then
				return id, name
			end
		end
		for _, player in Players:GetPlayers() do
			if player.Name:lower():sub(1, #lower) == lower or player.DisplayName:lower():sub(1, #lower) == lower then
				return player.UserId, player.Name
			end
		end
		error(("couldn't find a player called \"%s\""):format(q), 0)
	end

	-- The player's avatar picture from Roblox's thumbnail service (transparent background), cropped
	-- to the character. Returns w, h, rgba and the username.
	function Sources.avatar(query: string, style: string, yielder: () -> ()): (number, number, buffer, string)
		local userId, username = resolveUser(query)
		local kind = CONFIG.AVATAR_STYLES[style] or CONFIG.AVATAR_STYLES.Full
		local url = CONFIG.AVATAR_URL:format(kind.endpoint, userId, kind.size)
		-- a picture that isn't rendered yet comes back "Pending": ask again for a few seconds
		local imageUrl
		for _ = 1, 8 do
			local data = HttpService:JSONDecode(httpGet(url))
			local entry = type(data) == "table" and type(data.data) == "table" and data.data[1]
			if entry and entry.state == "Completed" and type(entry.imageUrl) == "string" then
				imageUrl = entry.imageUrl
				break
			elseif entry and entry.state ~= "Pending" then
				error(("Roblox has no avatar picture for %s (%s)"):format(username, tostring(entry.state)), 0)
			end
			task.wait(1)
		end
		if not imageUrl then
			error("Roblox is still rendering that avatar, try again in a moment", 0)
		end
		local iw, ih, rgba = Imaging.decode(httpGet(imageUrl), yielder)
		local w, h, cropped = Imaging.trim(rgba, iw, ih, 4)
		return w, h, cropped, username
	end
end

---------------------------------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------------------------------
local State = {
	busy = false, -- an image is loading
	source = nil :: { w: number, h: number, rgba: buffer, title: string }?,
	image = nil :: { w: number, h: number, rgba: buffer, dots: number }?,
	editable = nil :: any,
	editableSize = Vector2.zero,
	placing = false,
	anchor = nil :: { center: Vector3, right: Vector3, up: Vector3, normal: Vector3 }?,
	hover = { center = Vector3.zero, right = Vector3.xAxis, up = Vector3.yAxis, normal = Vector3.zAxis, valid = false },
	processToken = 0,
	saveToken = 0,
}

local Job = {
	running = false,
	paused = false,
	stop = false,
	thread = nil :: thread?,
	maid = Maid.new(),
	stats = {} :: { [string]: any }, -- mouse-mode timing counters, for troubleshooting from the console
}
maid:Give(function()
	Job.stop = true
	Job.maid:Cleanup()
	local thread = Job.thread
	if thread and coroutine.status(thread) ~= "running" then
		pcall(task.cancel, thread)
	end
end)

local function saveSettings()
	if not canFiles then
		return
	end
	State.saveToken += 1
	local token = State.saveToken
	task.delay(0.5, function() -- debounced: slider drags write once, not every frame
		if not alive or token ~= State.saveToken then
			return
		end
		local ok, err = pcall(writefile, CONFIG.FILE, HttpService:JSONEncode(Settings))
		if not ok then
			warn("[SprayArtist] Couldn't save settings: " .. tostring(err))
		end
	end)
end

---------------------------------------------------------------------------------------------------
-- UI
---------------------------------------------------------------------------------------------------
local UI = {}

local guiParent: Instance
do
	local ok, hui = pcall(function()
		return if type(gethui) == "function" then gethui() else game:GetService("CoreGui")
	end)
	guiParent = if ok and typeof(hui) == "Instance" then hui else LocalPlayer:WaitForChild("PlayerGui")
end

local layoutCounter = 0
local function nextOrder(): number
	layoutCounter += 1
	return layoutCounter
end

local function corner(radius: UDim?): UICorner
	return create("UICorner", { CornerRadius = radius or THEME.Corner })
end

local function stroke(color: Color3?, transparency: number?): UIStroke
	return create("UIStroke", {
		Color = color or THEME.Stroke,
		Transparency = transparency or 0.3,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
end

local function label(parent: Instance, text: string, props: { [string]: any }?): TextLabel
	local base = {
		BackgroundTransparency = 1,
		FontFace = THEME.Font,
		TextSize = THEME.TextSize,
		TextColor3 = THEME.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = text,
		Size = UDim2.new(1, 0, 0, 18),
		LayoutOrder = nextOrder(),
		Parent = parent,
	}
	if props then
		for k, v in props do
			base[k] = v
		end
	end
	return create("TextLabel", base)
end

local function Button(parent: Instance, text: string, style: string, onClick: () -> ()): TextButton
	local colors = {
		primary = { THEME.Accent, THEME.AccentHover },
		secondary = { THEME.Accent2, THEME.Accent2Hover },
		plain = { THEME.Field, THEME.FieldHover },
	}
	local pair = colors[style] or colors.plain
	local btn = create("TextButton", {
		AutoButtonColor = false,
		BackgroundColor3 = pair[1],
		FontFace = THEME.FontBold,
		TextSize = THEME.TextSize,
		TextColor3 = THEME.Text,
		Text = text,
		Size = UDim2.new(1, 0, 0, 34),
		LayoutOrder = nextOrder(),
		Parent = parent,
	}, { corner() })
	maid:Give(btn.MouseEnter:Connect(function()
		tween(btn, { BackgroundColor3 = pair[2] })
	end))
	maid:Give(btn.MouseLeave:Connect(function()
		tween(btn, { BackgroundColor3 = pair[1] })
	end))
	maid:Give(btn.Activated:Connect(onClick))
	return btn
end

local function Row(parent: Instance, height: number): Frame
	return create("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, height),
		LayoutOrder = nextOrder(),
		Parent = parent,
	}, {
		create("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, 8),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
end

-- Only one slider can be dragged at a time; a single InputChanged connection serves all of them.
UI.activeSlider = nil :: any

local function Slider(parent: Instance, opts: { label: string, min: number, max: number, step: number, value: number, format: (number) -> string, onChanged: (number) -> () })
	local root = create("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 40),
		LayoutOrder = nextOrder(),
		Parent = parent,
	})
	create("TextLabel", {
		BackgroundTransparency = 1,
		FontFace = THEME.Font,
		TextSize = THEME.SmallText + 1,
		TextColor3 = THEME.SubText,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = opts.label,
		Size = UDim2.new(1, -70, 0, 16),
		Parent = root,
	})
	local valueLabel = create("TextLabel", {
		BackgroundTransparency = 1,
		FontFace = THEME.FontBold,
		TextSize = THEME.SmallText + 1,
		TextColor3 = THEME.Text,
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0, 70, 0, 16),
		Parent = root,
	})
	local bar = create("Frame", {
		BackgroundColor3 = THEME.Field,
		Position = UDim2.new(0, 0, 0, 24),
		Size = UDim2.new(1, 0, 0, 8),
		Parent = root,
	}, { corner(UDim.new(1, 0)) })
	local fill = create("Frame", {
		BackgroundColor3 = THEME.Accent,
		Size = UDim2.fromScale(0, 1),
		Parent = bar,
	}, { corner(UDim.new(1, 0)) })
	local knob = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = THEME.Text,
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.fromOffset(14, 14),
		Parent = bar,
	}, { corner(UDim.new(1, 0)) })

	local api = { value = opts.value }
	local function render()
		local alpha = (api.value - opts.min) / (opts.max - opts.min)
		fill.Size = UDim2.fromScale(alpha, 1)
		knob.Position = UDim2.fromScale(alpha, 0.5)
		valueLabel.Text = opts.format(api.value)
	end
	function api.set(v: number, fire: boolean)
		v = math.clamp(v, opts.min, opts.max)
		v = opts.min + math.floor((v - opts.min) / opts.step + 0.5) * opts.step
		v = tonumber(string.format("%.3f", v)) :: number
		if v == api.value then
			return
		end
		api.value = v
		render()
		if fire then
			opts.onChanged(v)
		end
	end
	api.refresh = render
	function api.setFromX(x: number)
		local w = bar.AbsoluteSize.X
		if w <= 0 then
			return
		end
		local alpha = math.clamp((x - bar.AbsolutePosition.X) / w, 0, 1)
		api.set(opts.min + alpha * (opts.max - opts.min), true)
	end
	maid:Give(bar.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			UI.activeSlider = api
			api.setFromX(input.Position.X)
		end
	end))
	render()
	return api
end

local function Toggle(parent: Instance, text: string, value: boolean, onChanged: (boolean) -> ())
	local row = create("TextButton", {
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Text = "",
		Size = UDim2.new(1, 0, 0, 24),
		LayoutOrder = nextOrder(),
		Parent = parent,
	})
	create("TextLabel", {
		BackgroundTransparency = 1,
		FontFace = THEME.Font,
		TextSize = THEME.SmallText + 1,
		TextColor3 = THEME.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = text,
		Size = UDim2.new(1, -50, 1, 0),
		Parent = row,
	})
	local track = create("Frame", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromOffset(38, 20),
		BackgroundColor3 = THEME.Field,
		Parent = row,
	}, { corner(UDim.new(1, 0)) })
	local knob = create("Frame", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 3, 0.5, 0),
		Size = UDim2.fromOffset(14, 14),
		BackgroundColor3 = THEME.SubText,
		Parent = track,
	}, { corner(UDim.new(1, 0)) })
	local api = { value = value }
	local function render()
		tween(track, { BackgroundColor3 = if api.value then THEME.Accent else THEME.Field })
		tween(knob, {
			Position = if api.value then UDim2.new(1, -17, 0.5, 0) else UDim2.new(0, 3, 0.5, 0),
			BackgroundColor3 = if api.value then THEME.Text else THEME.SubText,
		})
	end
	maid:Give(row.Activated:Connect(function()
		api.value = not api.value
		render()
		onChanged(api.value)
	end))
	render()
	return api
end

-- Root window -----------------------------------------------------------------------------------
UI.gui = maid:Give(create("ScreenGui", {
	Name = "SprayArtist",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	DisplayOrder = 60,
	Parent = guiParent,
}))

UI.window = create("Frame", {
	AnchorPoint = Vector2.new(0, 0.5),
	Position = UDim2.new(0, 24, 0.5, 0),
	Size = UDim2.new(0, THEME.Width, 0, 600),
	BackgroundColor3 = THEME.Bg,
	Parent = UI.gui,
}, {
	corner(UDim.new(0, 12)),
	stroke(THEME.Stroke, 0.2),
	create("UISizeConstraint", { MaxSize = Vector2.new(THEME.Width, 640) }),
})

UI.titleBar = create("Frame", {
	BackgroundColor3 = THEME.Panel,
	Size = UDim2.new(1, 0, 0, 40),
	Parent = UI.window,
}, {
	corner(UDim.new(0, 12)),
	create("UIGradient", {
		Color = ColorSequence.new(THEME.Accent:Lerp(THEME.Panel, 0.55), THEME.Accent2:Lerp(THEME.Panel, 0.55)),
	}),
})
create("TextLabel", {
	BackgroundTransparency = 1,
	FontFace = THEME.FontBold,
	TextSize = 16,
	TextColor3 = THEME.Text,
	TextXAlignment = Enum.TextXAlignment.Left,
	Text = "Spray Artist",
	Position = UDim2.fromOffset(14, 0),
	Size = UDim2.new(1, -90, 1, 0),
	Parent = UI.titleBar,
})
UI.closeButton = create("TextButton", {
	AutoButtonColor = false,
	AnchorPoint = Vector2.new(1, 0.5),
	Position = UDim2.new(1, -8, 0.5, 0),
	Size = UDim2.fromOffset(26, 26),
	BackgroundColor3 = THEME.Field,
	BackgroundTransparency = 0.3,
	FontFace = THEME.FontBold,
	TextSize = 14,
	TextColor3 = THEME.Text,
	Text = "X",
	Parent = UI.titleBar,
}, { corner(UDim.new(1, 0)) })

UI.content = create("ScrollingFrame", {
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	Position = UDim2.fromOffset(0, 44),
	Size = UDim2.new(1, 0, 1, -48),
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	ScrollBarThickness = 4,
	ScrollBarImageColor3 = THEME.Stroke,
	Parent = UI.window,
}, {
	create("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }),
	create("UIPadding", {
		PaddingLeft = UDim.new(0, 14),
		PaddingRight = UDim.new(0, 14),
		PaddingTop = UDim.new(0, 6),
		PaddingBottom = UDim.new(0, 10),
	}),
})

-- Source tabs -----------------------------------------------------------------------------------
local MODES = table.freeze({
	{ key = "Text", text = "Text", hint = "Type the words to paint… (\\n = new line)" },
	{ key = "URL", text = "Image URL", hint = "Paste a .png / .jpg link" },
	{ key = "Avatar", text = "Avatar", hint = "Type a username or display name…" },
})
UI.tabs = {}
do
	local tabRow = Row(UI.content, 30)
	for _, mode in MODES do
		local btn = create("TextButton", {
			AutoButtonColor = false,
			BackgroundColor3 = THEME.Field,
			FontFace = THEME.FontBold,
			TextSize = THEME.SmallText + 1,
			TextColor3 = THEME.SubText,
			Text = mode.text,
			Size = UDim2.new(1 / #MODES, -6, 1, 0),
			LayoutOrder = nextOrder(),
			Parent = tabRow,
		}, { corner() })
		UI.tabs[mode.key] = btn
	end
end

UI.input = create("TextBox", {
	BackgroundColor3 = THEME.Field,
	ClearTextOnFocus = false,
	FontFace = THEME.Font,
	TextSize = THEME.TextSize,
	TextColor3 = THEME.Text,
	PlaceholderColor3 = THEME.SubText,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextWrapped = true,
	Text = "",
	Size = UDim2.new(1, 0, 0, 52),
	LayoutOrder = nextOrder(),
	Parent = UI.content,
}, {
	corner(),
	stroke(),
	create("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }),
})

-- Text colour (hex), only shown on the Text tab
UI.textColorRow = create("Frame", {
	BackgroundTransparency = 1,
	Size = UDim2.new(1, 0, 0, 30),
	LayoutOrder = nextOrder(),
	Parent = UI.content,
})
create("TextLabel", {
	BackgroundTransparency = 1,
	FontFace = THEME.Font,
	TextSize = THEME.SmallText + 1,
	TextColor3 = THEME.SubText,
	TextXAlignment = Enum.TextXAlignment.Left,
	Text = "Text colour (hex)",
	Size = UDim2.new(0.5, 0, 1, 0),
	Parent = UI.textColorRow,
})
UI.textColorSwatch = create("Frame", {
	AnchorPoint = Vector2.new(1, 0.5),
	Position = UDim2.new(1, -112, 0.5, 0),
	Size = UDim2.fromOffset(22, 22),
	BackgroundColor3 = Color3.fromHex(Settings.textColor),
	Parent = UI.textColorRow,
}, { corner(UDim.new(0, 6)), stroke() })
UI.textColorBox = create("TextBox", {
	AnchorPoint = Vector2.new(1, 0.5),
	Position = UDim2.new(1, 0, 0.5, 0),
	Size = UDim2.fromOffset(104, 26),
	BackgroundColor3 = THEME.Field,
	ClearTextOnFocus = false,
	FontFace = THEME.FontBold,
	TextSize = THEME.SmallText + 1,
	TextColor3 = THEME.Text,
	Text = "#" .. Settings.textColor,
	Parent = UI.textColorRow,
}, { corner(), stroke() })

-- Avatar picture type, only shown on the Avatar tab
UI.avatarRow = create("Frame", {
	BackgroundTransparency = 1,
	Size = UDim2.new(1, 0, 0, 30),
	LayoutOrder = nextOrder(),
	Parent = UI.content,
})
create("TextLabel", {
	BackgroundTransparency = 1,
	FontFace = THEME.Font,
	TextSize = THEME.SmallText + 1,
	TextColor3 = THEME.SubText,
	TextXAlignment = Enum.TextXAlignment.Left,
	Text = "Picture",
	Size = UDim2.new(0.5, 0, 1, 0),
	Parent = UI.avatarRow,
})
UI.avatarStyleButton = create("TextButton", {
	AutoButtonColor = false,
	AnchorPoint = Vector2.new(1, 0.5),
	Position = UDim2.new(1, 0, 0.5, 0),
	Size = UDim2.fromOffset(134, 26),
	BackgroundColor3 = THEME.Field,
	FontFace = THEME.FontBold,
	TextSize = THEME.SmallText + 1,
	TextColor3 = THEME.Text,
	Text = (CONFIG.AVATAR_STYLES[Settings.avatarStyle] or CONFIG.AVATAR_STYLES.Full).label,
	Parent = UI.avatarRow,
}, { corner(), stroke() })

-- Preview -----------------------------------------------------------------------------------------
UI.previewRow = Row(UI.content, 116)
UI.preview = create("ImageLabel", {
	BackgroundColor3 = THEME.Panel,
	Size = UDim2.fromOffset(116, 116),
	ScaleType = Enum.ScaleType.Fit,
	ResampleMode = Enum.ResamplerMode.Pixelated,
	Image = "",
	LayoutOrder = nextOrder(),
	Parent = UI.previewRow,
}, { corner(), stroke() })
UI.previewHint = create("TextLabel", {
	BackgroundTransparency = 1,
	FontFace = THEME.Font,
	TextSize = THEME.SmallText,
	TextColor3 = THEME.SubText,
	TextWrapped = true,
	Text = "",
	Size = UDim2.fromScale(1, 1),
	Parent = UI.preview,
})
UI.info = create("TextLabel", {
	BackgroundTransparency = 1,
	FontFace = THEME.Font,
	TextSize = THEME.SmallText + 1,
	TextColor3 = THEME.SubText,
	TextWrapped = true,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top,
	RichText = true,
	Text = "Load a picture to see its size and paint time here.",
	Size = UDim2.new(1, -124, 1, 0),
	LayoutOrder = nextOrder(),
	Parent = UI.previewRow,
})

-- Status line (created early so every handler can use it) ---------------------------------------
local function setStatus(text: string, color: Color3?)
	restoreCaps()
	pcall(function()
		if UI.status then
			UI.status.Text = text
			UI.status.TextColor3 = color or THEME.SubText
		end
		if UI.hudText then
			UI.hudText.Text = text
		end
	end)
end

---------------------------------------------------------------------------------------------------
-- Preview images (EditableImage; optional — feature-detected)
---------------------------------------------------------------------------------------------------
local Preview = {}
do
	local supported = true
	function Preview.content(): any
		if not State.editable then
			return nil
		end
		local ok, content = pcall(Content.fromObject, State.editable)
		return if ok then content else nil
	end

	function Preview.write(w: number, h: number, rgba: buffer)
		if not supported then
			return
		end
		local size = Vector2.new(w, h)
		if State.editable and State.editableSize ~= size then
			pcall(State.editable.Destroy, State.editable)
			State.editable = nil
		end
		if not State.editable then
			local ok, ei = pcall(function()
				return AssetService:CreateEditableImage({ Size = size })
			end)
			if not ok or not ei then
				supported = false
				warn("[SprayArtist] EditableImage unavailable, previews disabled: " .. tostring(ei))
				return
			end
			State.editable = ei
			State.editableSize = size
		end
		local ok, err = pcall(function()
			State.editable:WritePixelsBuffer(Vector2.zero, size, rgba)
		end)
		if not ok then
			warn("[SprayArtist] Preview write failed: " .. tostring(err))
			return
		end
		local content = Preview.content()
		if content then
			pcall(function()
				UI.preview.ImageContent = content
			end)
			UI.previewHint.Visible = false
		end
	end

	maid:Give(function()
		if State.editable then
			pcall(State.editable.Destroy, State.editable)
			State.editable = nil
		end
	end)
end

---------------------------------------------------------------------------------------------------
-- Wrap: lays the picture over the real surfaces like a sticker. From the placement point it walks
-- across the surface (centre column first, then every row outwards), step by step:
--   • bumps / steps up to WRAP_SNAP are followed by projecting onto them,
--   • a wall rising in the way: the picture folds up onto it (inside corner, e.g. floor -> wall),
--   • the surface dropping away: it folds down over the edge (outside corner, e.g. over a wall top),
--   • nothing there: it carries on flat and those spots are marked unpaintable.
-- The picture's right/up directions are carried along and turned with every fold, so it stays one
-- continuous picture across corners. Only the game's paint-raycast proxies are hit.
---------------------------------------------------------------------------------------------------
local Wrap = {}
do
	-- Turns v by the rotation that takes unit vector a onto unit vector b.
	local function turn(v: Vector3, a: Vector3, b: Vector3): Vector3
		local c = a:Dot(b)
		if c > 0.99999 or c < -0.99 then
			return v
		end
		local k = a:Cross(b)
		return v * c + k:Cross(v) + k * (k:Dot(v) / (1 + c))
	end

	local function paintable(hit: RaycastResult): boolean
		return hit.Instance:HasTag("PaintRaycast")
	end

	-- One move of `s` studs from (p, n) along the surface direction t.
	local function advance(p: Vector3, n: Vector3, t: Vector3, s: number): (Vector3, Vector3, boolean)
		local params = GameApi.Params
		local newPos, newNormal, ok
		local from = p + n * CONFIG.WRAP_LIFT
		local block = workspace:Raycast(from, t * s, params)
		if block and block.Normal:Dot(t) < -0.3 then
			-- inside corner: go to the foot of the wall, then up it for the rest of the move
			local dist = math.clamp((block.Position - from):Dot(t), 0, s)
			newPos = block.Position - n * CONFIG.WRAP_LIFT + turn(t, n, block.Normal) * (s - dist)
			newNormal, ok = block.Normal, paintable(block)
		else
			local ahead = p + t * s
			local hit = workspace:Raycast(ahead + n * CONFIG.WRAP_SNAP, n * (-2 * CONFIG.WRAP_SNAP), params)
			if hit and hit.Normal:Dot(n) > 0.3 then
				return hit.Position, hit.Normal, paintable(hit)
			end
			-- outside corner: find the face below the edge and fold down onto it
			local back = workspace:Raycast(ahead - n * s, t * (-2 * s), params)
			if not (back and back.Normal:Dot(t) > 0.3) then
				return ahead, n, false -- nothing there: carry on flat
			end
			local edge = math.clamp((back.Position - p):Dot(t), 0, s)
			newPos = p + t * edge + turn(t, n, back.Normal) * (s - edge)
			newNormal, ok = back.Normal, paintable(back)
		end
		-- settle onto the face it folded onto
		local snap = workspace:Raycast(newPos + newNormal * CONFIG.WRAP_SNAP, newNormal * (-2 * CONFIG.WRAP_SNAP), params)
		if snap and snap.Normal:Dot(newNormal) > 0.3 then
			return snap.Position, snap.Normal, paintable(snap)
		end
		return newPos, newNormal, ok
	end

	-- Moves a frame { pos, normal, right, up, ok } `len` studs along its own right/up axis.
	local function travel(f, axis: string, len: number)
		local sign = if len < 0 then -1 else 1
		local left = math.abs(len)
		while left > 1e-6 do
			local s = math.min(left, CONFIG.WRAP_SUBSTEP)
			left -= s
			local pos, normal, ok = advance(f.pos, f.normal, f[axis] * sign, s)
			local up = turn(f.up, f.normal, normal)
			up -= normal * up:Dot(normal)
			up = if up.Magnitude > 1e-4 then up.Unit else f.up
			f = { pos = pos, normal = normal, up = up, right = up:Cross(normal).Unit, ok = ok }
		end
		return f
	end

	-- Walks outwards from offset 0 along `axis`, in order of distance on each side, so every
	-- position continues from its neighbour; emit(k, frame) for offsets[k].
	local function march(origin, axis: string, offsets: { number }, emit: (number, any) -> ())
		for _, positive in { true, false } do
			local order = {}
			for k, o in offsets do
				if (o >= 0) == positive then
					table.insert(order, k)
				end
			end
			table.sort(order, function(a, b)
				return math.abs(offsets[a]) < math.abs(offsets[b])
			end)
			local f, at = origin, 0
			for _, k in order do
				f = travel(f, axis, offsets[k] - at)
				at = offsets[k]
				emit(k, f)
			end
		end
	end

	-- Calls emit(i, j, frame) for every offset pair (xs[i] studs right, ys[j] studs up of the
	-- anchor, measured along the surface).
	function Wrap.layout(anchor, xs: { number }, ys: { number }, emit: (number, number, any) -> (), yielder: (() -> ())?)
		local start = { pos = anchor.center, normal = anchor.normal, right = anchor.right, up = anchor.up, ok = true }
		local rowStarts = table.create(#ys)
		march(start, "up", ys, function(j, f)
			rowStarts[j] = f
		end)
		for j = 1, #ys do
			march(rowStarts[j], "right", xs, function(i, f)
				emit(i, j, f)
			end)
			if yielder then
				yielder()
			end
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Wall placement ghost: the picture in tiles, each tile laid on its own spot of the wrapped
-- surface, so the preview bends around corners and up walls exactly like the painting will.
-- Tiles where nothing can be painted show red. Tiles are pooled; re-layouts are throttled.
---------------------------------------------------------------------------------------------------
local Ghost = {}
do
	local tiles = {}
	local shown = 0
	local visible = false
	local transparency = 0.15
	local last = { center = Vector3.zero, normal = Vector3.zero, up = Vector3.zero, w = 0, h = 0, step = 0 }
	local lastLayout = 0
	local pending = nil
	local pendingScheduled = false

	local function newTile()
		local part = create("Part", {
			Name = "SprayArtistGhost",
			Anchored = true,
			CanCollide = false,
			CanQuery = false,
			CanTouch = false,
			CastShadow = false,
			Transparency = 1,
			Size = Vector3.new(1, 1, 0.02),
		})
		local surface = create("SurfaceGui", {
			Face = Enum.NormalId.Back, -- the part's +Z face; CFrame.fromMatrix(_, right, up) makes +Z the wall normal
			SizingMode = Enum.SurfaceGuiSizingMode.FixedSize,
			CanvasSize = Vector2.new(64, 64), -- stretched over the tile's face
			LightInfluence = 0,
			Adornee = part,
			Parent = part,
		})
		local image = create("ImageLabel", {
			BackgroundColor3 = THEME.Accent,
			BackgroundTransparency = 0.82,
			BorderSizePixel = 0,
			ImageTransparency = transparency,
			ResampleMode = Enum.ResamplerMode.Pixelated,
			Size = UDim2.fromScale(1, 1),
			Parent = surface,
		})
		local content = Preview.content()
		if content then
			pcall(function()
				image.ImageContent = content
			end)
		end
		maid:Give(part)
		return { part = part, surface = surface, image = image, ok = true, size = Vector3.zero }
	end

	local function apply(anchor, w: number, h: number, step: number)
		lastLayout = os.clock()
		last.center, last.normal, last.up = anchor.center, anchor.normal, anchor.up
		last.w, last.h, last.step = w, h, step
		local tilePx = math.max(1, math.ceil(math.max(w, h) / CONFIG.GHOST_TILES))
		local cols, rows = math.ceil(w / tilePx), math.ceil(h / tilePx)
		local xs, ys = table.create(cols), table.create(rows)
		for i = 1, cols do
			xs[i] = (((i - 1) * tilePx + math.min(i * tilePx, w)) / 2 - w / 2) * step
		end
		for j = 1, rows do
			ys[j] = (h / 2 - ((j - 1) * tilePx + math.min(j * tilePx, h)) / 2) * step
		end
		Wrap.layout(anchor, xs, ys, function(i, j, f)
			local k = (j - 1) * cols + i
			local tile = tiles[k]
			if not tile then
				tile = newTile()
				tiles[k] = tile
			end
			local x0, y0 = (i - 1) * tilePx, (j - 1) * tilePx
			local pw, ph = math.min(tilePx, w - x0), math.min(tilePx, h - y0)
			-- every tile moves with the layout, so the CFrame write is needed on each re-layout
			tile.part.CFrame = CFrame.fromMatrix(f.pos + f.normal * 0.04, f.right, f.up)
			local partSize = Vector3.new(pw * step, ph * step, 0.02)
			if tile.size ~= partSize then
				tile.size = partSize
				tile.part.Size = partSize
			end
			local image = tile.image
			-- the texture can still be the previous size's picture: sample it proportionally
			local tex = State.editableSize or Vector2.new(w, h)
			local sx, sy = tex.X / w, tex.Y / h
			local offset, size = Vector2.new(x0 * sx, y0 * sy), Vector2.new(pw * sx, ph * sy)
			if image.ImageRectOffset ~= offset then
				image.ImageRectOffset = offset
			end
			if image.ImageRectSize ~= size then
				image.ImageRectSize = size
			end
			if tile.ok ~= f.ok then
				tile.ok = f.ok
				image.BackgroundColor3 = if f.ok then THEME.Accent else THEME.Bad
				image.BackgroundTransparency = if f.ok then 0.82 else 0.35
			end
			if image.ImageTransparency ~= transparency then
				image.ImageTransparency = transparency
			end
			if tile.part.Parent ~= camera then
				tile.part.Parent = camera -- client-only container, never seen by the game's raycasts
			end
			-- hidden tiles stay parented (re-parenting hundreds of SurfaceGuis is the slow part)
			if not tile.surface.Enabled then
				tile.surface.Enabled = true
			end
		end)
		local count = cols * rows
		for k = count + 1, #tiles do
			if tiles[k].surface.Enabled then
				tiles[k].surface.Enabled = false
			end
		end
		shown = count
	end

	function Ghost.refreshImage()
		local content = Preview.content()
		if not content then
			return
		end
		last.w = -1 -- texture size may have changed: the next show() re-lays the tiles
		for _, tile in tiles do
			pcall(function()
				tile.image.ImageContent = content
			end)
		end
	end

	function Ghost.show(anchor, w: number, h: number, step: number, newTransparency: number)
		visible = true
		if newTransparency ~= transparency then
			transparency = newTransparency
			for k = 1, shown do
				tiles[k].image.ImageTransparency = transparency
			end
		end
		local same = shown > 0
			and (anchor.center - last.center).Magnitude < 0.01
			and anchor.normal:Dot(last.normal) > 0.9999
			and anchor.up:Dot(last.up) > 0.9999
			and w == last.w
			and h == last.h
			and step == last.step
		if same then
			return
		end
		if os.clock() - lastLayout >= CONFIG.GHOST_INTERVAL then
			apply(anchor, w, h, step)
			return
		end
		-- aiming moves the anchor every frame: lay out at most every GHOST_INTERVAL
		pending = { center = anchor.center, right = anchor.right, up = anchor.up, normal = anchor.normal, w = w, h = h, step = step }
		if not pendingScheduled then
			pendingScheduled = true
			task.delay(CONFIG.GHOST_INTERVAL, function()
				pendingScheduled = false
				local args = pending
				pending = nil
				if alive and visible and args then
					apply(args, args.w, args.h, args.step)
				end
			end)
		end
	end

	function Ghost.hide()
		visible = false
		pending = nil
		for k = 1, shown do
			tiles[k].surface.Enabled = false
		end
		shown = 0
	end
end

---------------------------------------------------------------------------------------------------
-- Image pipeline glue
---------------------------------------------------------------------------------------------------
-- Transparent pixels are skipped when the toggle says so — and always for text.
local function skipAlpha(): boolean
	-- text and avatars are cut-outs: their transparent background is never painted
	return Settings.skipTransparent or (State.source ~= nil and State.source.cutout == true)
end

local function countDots(rgba: buffer, w: number, h: number): number
	if not skipAlpha() then
		return w * h
	end
	local n = 0
	for i = 0, w * h - 1 do
		if buffer.readu8(rgba, i * 4 + 3) >= 128 then
			n += 1
		end
	end
	return n
end

-- Distance between pixel centres on the wall (the brush itself is Settings.pixel wide).
local function brushName(): string
	return if Settings.roundBrush then CONFIG.ROUND_BRUSH else CONFIG.BRUSH
end

local function gridStep(): number
	return Settings.pixel * (if Settings.roundBrush then CONFIG.ROUND_GRID_OVERLAP else CONFIG.GRID_OVERLAP)
end

-- Pixels across x down for the current picture at the chosen size on the wall. The pixel spacing
-- is fixed by Pixel size, so a bigger picture simply gets more pixels (capped at MAX_SIDE a side,
-- keeping the shape).
local function picturePixels(): (number, number)
	local src = State.source
	local step = gridStep()
	local w = Settings.sizeX / step
	local h = if Settings.keepShape and src then w * src.h / src.w else Settings.sizeY / step
	local scale = math.min(1, CONFIG.MAX_SIDE / math.max(w, h))
	return math.max(2, math.floor(w * scale + 0.5)), math.max(2, math.floor(h * scale + 0.5))
end

local function updateInfo()
	local img = State.image
	if not img then
		return
	end
	local studsW, studsH = img.w * gridStep(), img.h * gridStep()
	local seconds = img.dots / Settings.maxRate + img.colors * (CONFIG.COLOR_SEND_SECONDS + Settings.colorPause * 1.4)
	UI.info.Text = ("%.1f x %.1f studs\n%s dots, %d colours\nabout %s"):format(
		studsW,
		studsH,
		formatInt(img.dots),
		img.colors,
		if seconds >= 90 then ("%d min"):format(math.ceil(seconds / 60)) else ("%ds"):format(math.ceil(seconds))
	)
end

local PROCESS_CANCELLED = "SprayArtist: processing superseded"

-- Rebuilds the paint-grid image from the decoded source (on load and whenever Width/Enhance change).
local function processImage()
	local src = State.source
	if not src then
		return
	end
	State.processToken += 1
	local token = State.processToken
	task.spawn(function()
		-- Spread over frames; a newer change cancels this run at its next yield.
		local slice = os.clock()
		local function yielder()
			if os.clock() - slice > CONFIG.PROCESS_BUDGET then
				task.wait()
				slice = os.clock()
				if token ~= State.processToken or not alive then
					error(PROCESS_CANCELLED, 0)
				end
			end
		end
		local tw, th = picturePixels()
		local ok, result = pcall(function()
			-- text keeps its exact colour; pictures get sharpened / pre-corrected as set
			local trueColors = Settings.trueColors and not src.text
			local adjust = {
				sharpen = if Settings.enhance then CONFIG.SHARPEN else 0,
				gamma = if trueColors then CONFIG.SHADOW_LIFT else 1,
				corrections = if trueColors then LightingFx.compensation() else {},
			}
			local function prepare(w: number, h: number): buffer
				local img = Imaging.resample(src.rgba, src.w, src.h, w, h, yielder)
				if src.text then
					-- Downscaled letters have soft edges; at alpha 128 thin strokes broke apart.
					-- Counting a little more of the edge as ink keeps small text legible.
					for i = 0, w * h - 1 do
						buffer.writeu8(img, i * 4 + 3, if buffer.readu8(img, i * 4 + 3) >= CONFIG.TEXT_ALPHA then 255 else 0)
					end
				end
				if adjust.sharpen > 0 or adjust.gamma ~= 1 or #adjust.corrections > 0 then
					img = Imaging.adjust(img, w, h, adjust, yielder)
				end
				return img
			end
			-- The palette only depends on the picture and the colour settings, not on its size.
			local paletteKey = table.concat({
				tostring(src.rgba),
				tostring(Settings.colors),
				tostring(Settings.enhance),
				tostring(trueColors),
				tostring(skipAlpha()),
			}, "|")
			if State.paletteKey ~= paletteKey then
				local scale = math.min(1, CONFIG.PALETTE_SAMPLE / math.max(src.w, src.h))
				local pw, ph = math.max(1, math.floor(src.w * scale + 0.5)), math.max(1, math.floor(src.h * scale + 0.5))
				State.palette = Imaging.buildPalette(prepare(pw, ph), pw, ph, Settings.colors, skipAlpha(), yielder)
				State.paletteKey = paletteKey
			end
			local quantized, colors = Imaging.mapToPalette(prepare(tw, th), tw, th, State.palette, Settings.dither, skipAlpha(), yielder)
			return { rgba = quantized, colors = colors }
		end)
		if not alive or token ~= State.processToken then
			return
		end
		if not ok then
			setStatus("Processing failed: " .. tostring(result), THEME.Bad)
			return
		end
		State.image = {
			w = tw,
			h = th,
			rgba = result.rgba,
			colors = result.colors,
			dots = countDots(result.rgba, tw, th),
			-- text paints one character at a time
			letters = if src.text then Imaging.letters(result.rgba, tw, th) else nil,
		}
		Preview.write(tw, th, result.rgba)
		Ghost.refreshImage()
		updateInfo()
		-- a placed picture's preview follows size / pixel changes
		if State.anchor and not State.placing and not Job.running then
			Ghost.show(State.anchor, tw, th, gridStep(), 0.45)
		end
		if UI.syncSize then
			UI.syncSize()
		end
	end)
end

local function loadImage()
	if State.busy then
		return
	end
	local text = UI.input.Text:gsub("^%s+", ""):gsub("%s+$", "")
	if text == "" then
		setStatus("Type something first.", THEME.Warn)
		return
	end
	State.busy = true
	local mode = Settings.mode
	setStatus(if mode == "Text" then "Rendering text…" elseif mode == "Avatar" then "Finding that avatar…" else "Downloading…", THEME.Warn)
	local thread = task.spawn(function()
		local yielder = newYielder(0.006)
		local ok, w, h, rgba, title = pcall(function()
			if mode == "Text" then
				local sw, sh, px = Sources.text(text, Settings.textColor, yielder)
				return sw, sh, px, "“" .. text .. "”"
			elseif mode == "Avatar" then
				local sw, sh, px, username = Sources.avatar(text, Settings.avatarStyle, yielder)
				return sw, sh, px, username .. "'s avatar"
			end
			local sw, sh, px = Sources.fromUrl(text, yielder)
			return sw, sh, px, text:match("([^/]+)$") or "image"
		end)
		State.busy = false
		if not alive then
			return
		end
		if not ok then
			setStatus("Load failed: " .. tostring(w), THEME.Bad)
			return
		end
		local shortTitle = if #title > 40 then title:sub(1, 38) .. "…" else title
		-- text and avatars always paint only the shape (their background is transparent)
		State.source = { w = w, h = h, rgba = rgba, title = shortTitle, text = mode == "Text", cutout = mode == "Text" or mode == "Avatar" }
		setStatus(if mode == "Avatar" then `Loaded {shortTitle}. Press Place.` else "Loaded. Press Place.", THEME.Good)
		processImage()
	end)
	maid:Give(thread)
end

---------------------------------------------------------------------------------------------------
-- Placement
---------------------------------------------------------------------------------------------------
local Placement = {}
do
	-- Picture rotation in degrees, clockwise as the viewer sees it. R adds Settings.rotateStep.
	Placement.rotation = 0

	-- Aligned basis: on walls the picture is perfectly upright (world Y); on floors/ceilings its top
	-- points along whichever world axis is closest to the camera's look direction, so it is always
	-- square to the world, never tilted with the camera.
	local function basisFor(normal: Vector3): (Vector3, Vector3)
		local up
		if math.abs(normal.Y) > 0.9 then
			local look = camera.CFrame.LookVector
			up = if math.abs(look.X) >= math.abs(look.Z)
				then (if look.X >= 0 then Vector3.xAxis else -Vector3.xAxis)
				else (if look.Z >= 0 then Vector3.zAxis else -Vector3.zAxis)
		else
			up = Vector3.yAxis - normal * normal.Y
		end
		if up.Magnitude < 1e-4 then
			up = Vector3.zAxis - normal * normal.Z
		end
		up = up.Unit
		return up:Cross(normal).Unit, up
	end

	-- Turns the (right, up) pair clockwise by `deg` as seen by someone facing the surface.
	local function rotated(right: Vector3, up: Vector3, deg: number): (Vector3, Vector3)
		local a = math.rad(deg)
		local c, s = math.cos(a), math.sin(a)
		return (right * c - up * s).Unit, (up * c + right * s).Unit
	end

	-- Re-applies the current rotation to a placed picture (keeps its unrotated basis).
	local function applyToAnchor()
		local anchor = State.anchor
		if not anchor or not anchor.baseRight then
			return
		end
		anchor.right, anchor.up = rotated(anchor.baseRight, anchor.baseUp, Placement.rotation)
		if State.image then
			Ghost.show(anchor, State.image.w, State.image.h, gridStep(), 0.45)
		end
	end

	function Placement.rotate()
		Placement.rotation = (Placement.rotation + Settings.rotateStep) % 360
		if not State.placing then
			applyToAnchor()
		end
		setStatus(("Rotated to %d°."):format(Placement.rotation), THEME.SubText)
	end

	local function step()
		debug.profilebegin("SprayArtist:Placement")
		local img = State.image
		local hover = State.hover
		local mouse = UserInputService:GetMouseLocation() -- viewport space, matches ViewportPointToRay
		local ray = camera:ViewportPointToRay(mouse.X, mouse.Y)
		local hit = workspace:Raycast(ray.Origin, ray.Direction * 1000, GameApi.Params)
		if img and hit and hit.Instance:HasTag("PaintRaycast") then
			local right, up = basisFor(hit.Normal)
			hover.baseRight, hover.baseUp = right, up
			right, up = rotated(right, up, Placement.rotation)
			hover.center, hover.right, hover.up, hover.normal, hover.valid = hit.Position, right, up, hit.Normal, true
			Ghost.show(hover, img.w, img.h, gridStep(), 0.15)
		else
			hover.valid = false
			Ghost.hide()
		end
		debug.profileend()
	end

	function Placement.begin()
		if Job.running then
			setStatus("Stop the current painting first.", THEME.Warn)
			return
		end
		if not State.image then
			setStatus("Load an image first.", THEME.Warn)
			return
		end
		if State.placing then
			return
		end
		-- Unequip the spray can so the placement click doesn't also spray a dot.
		local char = LocalPlayer.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if hum then
			hum:UnequipTools()
		end
		State.placing = true
		State.anchor = nil
		RunService:BindToRenderStep(CONFIG.BIND_NAME, Enum.RenderPriority.Camera.Value + 1, step)
		setStatus("Click on a wall to place it. R rotates, Esc cancels.", THEME.Warn)
	end

	function Placement.finish(confirm: boolean)
		if not State.placing then
			return
		end
		State.placing = false
		RunService:UnbindFromRenderStep(CONFIG.BIND_NAME)
		local hover = State.hover
		if confirm and hover.valid and State.image then
			State.anchor = { center = hover.center, right = hover.right, up = hover.up, normal = hover.normal, baseRight = hover.baseRight, baseUp = hover.baseUp }
			Ghost.show(State.anchor, State.image.w, State.image.h, gridStep(), 0.45)
			setStatus("Placed. Press Paint!", THEME.Good)
		else
			Ghost.hide()
			setStatus("Placement cancelled.", THEME.SubText)
		end
	end

	maid:Give(function()
		RunService:UnbindFromRenderStep(CONFIG.BIND_NAME)
	end)
end

---------------------------------------------------------------------------------------------------
-- Painter (game's own spray can + colour picker, aimed without touching the real mouse)
---------------------------------------------------------------------------------------------------
local Painter = {}
do
	local function character()
		local char = LocalPlayer.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if not hum or hum.Health <= 0 then
			return nil, nil
		end
		return char, hum
	end

	local function sprayEquipped(): boolean
		local char = character()
		return char ~= nil and char:FindFirstChild("SprayPaint") ~= nil
	end

	-- The game only sprays on press while the SprayPaint tool is equipped.
	local function ensureSprayEquipped(): boolean
		local char, hum = character()
		if not char then
			return false
		end
		if char:FindFirstChild("SprayPaint") then
			return true
		end
		local tool = LocalPlayer.Backpack:FindFirstChild("SprayPaint")
		if not tool then
			return false
		end
		hum:EquipTool(tool)
		task.wait(0.4) -- let the game's Equipped handler hook the mouse
		return char:FindFirstChild("SprayPaint") ~= nil
	end

	local function rootPosition(): Vector3?
		local char = character()
		return if char then char:GetPivot().Position else nil
	end

	local function appearanceControls()
		local ok, settings = pcall(function()
			return LocalPlayer.PlayerGui.PaintGui.Left.Main.Main.Appearance.Main.Settings
		end)
		if not ok or not settings then
			return nil
		end
		local size = settings:FindFirstChild("Scale") and settings.Scale:FindFirstChild("Slider")
		local opacity = settings:FindFirstChild("Opacity") and settings.Opacity:FindFirstChild("Slider")
		local rotation = settings:FindFirstChild("RotationFrame") and settings.RotationFrame:FindFirstChild("Swapper")
		if not (size and opacity and rotation) then
			return nil
		end
		return { size = size, opacity = opacity, rotation = rotation }
	end

	local function colorPicker(): Instance?
		local ok, picker = pcall(function()
			return LocalPlayer.PlayerGui.PaintGui.Left.Main.Main.Color.ColorPicker
		end)
		return if ok and picker and picker:FindFirstChild("SetColor") then picker else nil
	end

	local function setProgress(done: number, total: number)
		restoreCaps()
		local alpha = if total > 0 then math.clamp(done / total, 0, 1) else 0
		UI.progressFill.Size = UDim2.fromScale(alpha, 1)
	end

	local function waitWhile(cond: () -> boolean, message: string): boolean
		local shown = false
		while alive and not Job.stop and cond() do
			if not shown then
				setStatus(message, THEME.Warn)
				shown = true
			end
			task.wait(0.2)
		end
		return alive and not Job.stop
	end

	-----------------------------------------------------------------------------------------------
	-- Lanes: several of the game's own paint loops, each steered to its own part of the picture.
	--
	-- Every press of PlayerMouse.Button1Down makes the game's PaintGui script connect one more
	-- Heartbeat paint loop (until mouseUp disconnects them all). Each loop aims with
	-- PlayerMouse.UnitRay via the Mouse module, so the __index hook below looks at the call stack to
	-- see WHICH loop is asking and hands it that lane's next pixel. N lanes = N paint ticks per frame,
	-- each up to 5 dots. The game still creates, caches and sends every dot itself (valid keys).
	--
	-- The loops all share ONE "last sprayed position" upvalue (u14 in onEquippedPaint), which the game
	-- interpolates from. Left alone, lane B would draw a line from lane A's last dot. So right before
	-- each lane's tick we write that upvalue: the lane's own last pixel, or nil to start fresh (which
	-- also makes gaps free — no line is drawn across them). Located by its neighbours in the closure
	-- (RaycastParams before it, the character after it); if that ever fails we fall back to one lane
	-- that "lifts" (aims at the sky for a tick) at gaps.
	--
	-- The server checks every stroke for continuity: a dot is only kept if it's close to the last
	-- kept dot of the SAME stroke (verified: dots 0.45 studs apart in one stroke -> 0/40 kept; the
	-- same jumps split over two stroke numbers -> kept). So every lane paints under its own stroke
	-- number, and every gap inside a lane starts a fresh stroke. The game reads the stroke number from
	-- PaintSettings.Stroke as each dot is made, so we set it right before the lane's tick.
	-- (Fresh numbers needn't be logged with the server — unlogged strokes were kept 12/12.)
	--
	-- Per tick a lane either keeps aiming at an unconfirmed target or moves on to the next pixel —
	-- up to RUN_JUMP pixels in one go along a row (the game interpolates the dots in between).
	-----------------------------------------------------------------------------------------------
	local Lanes = {}
	do
		local playerMouse = LocalPlayer:GetMouse()
		local mouseRaycast = GameApi.Mouse.raycast
		local mouseTowards = GameApi.Mouse.raycastTowardsPosition
		local SKY = Ray.new(Vector3.new(0, 1e5, 0), Vector3.yAxis) -- hits nothing: the game resets its stroke
		local oldIndex: any = nil
		local byLoop: { [any]: any } = setmetatable({}, { __mode = "k" })
		local ticking: any = nil
		local lastIndex: number? = nil -- upvalue slot of the shared "last position" in a paint loop
		local probed = false
		local paintSettings: Instance? = nil
		-- Speed limit (pixels per second) as a token bucket refilled by the driver loop each frame.
		-- The game's anti-cheat ghost-banned the account when ~8 lanes painted many hundreds of
		-- pixels per second (2026-10-10), so the default stays at a human-plausible rate.
		local budget = 0
		-- The game won't spray a dot closer than max(Size x MinDistanceMultiplierBetweenPaint,
		-- MinSpacing) to its remembered last position. With tiny pixels (0.05 squares sit 0.0425
		-- apart, under the 0.075 minimum) every step along a row would be skipped, so each pixel is
		-- then sprayed as its own dot (no last position handed over, no runs along the row).
		local singleDots = false

		Lanes.SKY = SKY

		function Lanes.setSingleDots(on: boolean)
			singleDots = on
		end

		function Lanes.refill(rate: number, dt: number)
			budget = math.min(budget + rate * dt, math.max(rate * 0.2, CONFIG.RUN_JUMP))
		end

		function Lanes.setPaintSettings(settings: Instance)
			paintSettings = settings
		end

		-- Next unused stroke number (the game's own presses count up the same attribute).
		local function newStroke(): number
			local stroke = ((paintSettings :: Instance):GetAttribute("Stroke") or 0) + 1
			;(paintSettings :: Instance):SetAttribute("Stroke", stroke)
			return stroke
		end

		local function findLastIndex(loop): number?
			if type(debug.getupvalues) ~= "function" or type(debug.setupvalue) ~= "function" then
				return nil
			end
			local ok, ups = pcall(debug.getupvalues, loop)
			if not ok or type(ups) ~= "table" then
				return nil
			end
			for i = 2, 20 do
				local value = ups[i]
				if typeof(ups[i - 1]) == "RaycastParams" and typeof(ups[i + 1]) == "Instance" and (value == nil or typeof(value) == "Vector3") then
					return i
				end
			end
			return nil
		end

		-- True when lanes can steer the shared last position (multi-lane + gap-free painting).
		function Lanes.canSteer(): boolean
			return lastIndex ~= nil
		end

		-- Called for every PlayerMouse.UnitRay read. Mouse.raycast called straight from a paint loop is
		-- that loop's once-per-tick aim; Mouse.raycastTowardsPosition (same tick, for the interpolated
		-- dots) only needs an origin in front of the wall, so it gets the ticking lane's ray.
		local function onRead(): Ray?
			for level = 2, 10 do
				local f = debug.info(level, "f")
				if f == nil then
					return nil
				end
				if f == mouseRaycast then
					local loop = debug.info(level + 1, "f")
					local lane = byLoop[loop]
					if lane then
						ticking = lane
						local ray, from = lane.tick()
						if lastIndex then
							debug.setupvalue(loop, lastIndex, from)
						end
						if ray ~= SKY and paintSettings and lane.stroke and paintSettings:GetAttribute("Stroke") ~= lane.stroke then
							paintSettings:SetAttribute("Stroke", lane.stroke)
						end
						return ray
					end
					return nil
				elseif f == mouseTowards then
					return if ticking then ticking.ray else nil
				end
			end
			return nil
		end

		function Lanes.available(): boolean
			return type(hookmetamethod) == "function"
				and type(getconnections) == "function"
				and type(debug.info) == "function"
				and GameApi.Mouse ~= nil
				and type(mouseRaycast) == "function"
		end

		function Lanes.install()
			if oldIndex then
				return
			end
			local wrap = if type(newcclosure) == "function" then newcclosure else function(f)
				return f
			end
			oldIndex = hookmetamethod(game, "__index", wrap(function(self, key)
				if key == "UnitRay" and self == playerMouse then
					local ok, ray = pcall(onRead)
					if ok and ray then
						return ray
					end
				end
				return oldIndex(self, key)
			end))
		end

		function Lanes.uninstall()
			table.clear(byLoop)
			ticking = nil
			if oldIndex then
				hookmetamethod(game, "__index", oldIndex)
				oldIndex = nil
			end
		end

		local function paintLoops(): { [any]: boolean }
			local set = {}
			for _, connection in getconnections(RunService.Heartbeat) do
				local f = connection.Function
				if f and not set[f] then
					local source = debug.info(f, "s")
					if source and string.find(source, "PaintGui", 1, true) then
						set[f] = true
					end
				end
			end
			return set
		end

		-- Presses the spray button once and binds the paint loop the game just created to `lane`.
		function Lanes.press(lane): boolean
			local before = paintLoops()
			if type(firesignal) == "function" then
				firesignal(playerMouse.Button1Down)
			else
				for _, connection in getconnections(playerMouse.Button1Down) do
					connection:Fire()
				end
			end
			for f in paintLoops() do
				if not before[f] then
					byLoop[f] = lane
					-- the press just counted the stroke number up: that's this lane's first stroke
					lane.stroke = if paintSettings then paintSettings:GetAttribute("Stroke") else nil
					lane.pressFresh = true
					if not probed then
						probed = true
						lastIndex = findLastIndex(f)
					end
					return true
				end
			end
			return false
		end

		-- One throwaway press (aimed at the sky) to locate the shared last-position upvalue up front.
		function Lanes.probe()
			if probed then
				return
			end
			Lanes.press(Lanes.new({}))
			Lanes.releaseAll()
		end

		-- mouseUp: the game disconnects every paint loop and sends what they sprayed.
		function Lanes.releaseAll()
			table.clear(byLoop)
			ticking = nil
			GameApi.Mouse.mouseUp:Fire()
		end

		function Lanes.new(queue)
			local lane = {
				queue = queue,
				idx = 1,
				target = nil,
				targetEnd = 0,
				last = nil, -- last confirmed step = the game's remembered position (nil = none)
				ray = SKY,
				from = nil :: Vector3?, -- the last position handed to the game with the current target
				waited = 0,
				finished = false,
				confirmed = 0,
				stroke = nil :: number?, -- stroke number this lane's dots are made with
				pressFresh = false,
			}
			-- Returns the ray to aim with and the "last position" the game should interpolate from.
			function lane.tick(): (Ray, Vector3?)
				local target = lane.target
				if target then
					if target.done then
						lane.last = lane.queue[lane.targetEnd]
						lane.idx = lane.targetEnd + 1
						lane.target = nil
					else
						lane.waited += 1
						if lane.waited < CONFIG.LANE_PATIENCE then
							return lane.ray, lane.from
						end
						-- Give up on it for this pass (the repaint pass catches it) and start fresh.
						lane.idx = lane.targetEnd + 1
						lane.target, lane.last, lane.ray = nil, nil, SKY
						return SKY, nil
					end
				end
				local queue = lane.queue
				local step = queue[lane.idx]
				if not step then
					lane.finished, lane.ray = true, SKY
					return SKY, nil
				end
				local last = lane.last
				if last and (step.path ~= last.path + 1 or last.normal:Dot(step.normal) < CONFIG.FOLD_DOT) then
					lane.last = nil
					if not lastIndex then
						lane.ray = SKY -- can't steer the last position: lift for one tick instead
						return SKY, nil
					end
					last = nil -- steering: just start a fresh stroke here (no line across the gap)
				end
				-- Run along the row only when already in it (a run right after the snake turns a corner
				-- would cut diagonally and skip the row's first pixels).
				local k = lane.idx
				if last and last.row == step.row and not singleDots then
					while k - lane.idx < CONFIG.RUN_JUMP - 1 do
						local nxt = queue[k + 1]
						if not nxt or nxt.path ~= queue[k].path + 1 or nxt.row ~= step.row or nxt.normal:Dot(step.normal) < CONFIG.FOLD_DOT then
							break
						end
						k += 1
					end
				end
				local cost = k - lane.idx + 1
				if budget < cost then
					-- Over the speed limit: hold still this tick. Aiming at the spot just sprayed with
					-- that same spot as the last position makes the game skip the tick (no new dot).
					if last then
						return Ray.new(last.pos + last.normal * 2, -last.normal), last.pos
					end
					return SKY, nil
				end
				budget -= cost
				if not last and paintSettings then
					-- Starting fresh (after a gap or a give-up): a new stroke, so the server's
					-- continuity check doesn't compare this dot with the far-away previous one.
					-- The very first start after a press uses the stroke the press created.
					if lane.pressFresh then
						lane.pressFresh = false
					else
						lane.stroke = newStroke()
					end
				end
				local t = queue[k]
				lane.target, lane.targetEnd, lane.waited = t, k, 0
				lane.ray = Ray.new(t.pos + t.normal * 2, -t.normal)
				lane.from = if last and not singleDots then last.pos else nil
				return lane.ray, lane.from
			end
			return lane
		end
	end
	maid:Give(Lanes.uninstall)



	-----------------------------------------------------------------------------------------------
	-- Walker: walks the character like a player does (PathfindingService waypoints +
	-- Humanoid:MoveTo) so every part of a big picture comes within spraying range in turn.
	-----------------------------------------------------------------------------------------------
	local Walker = {}
	do
		local PathfindingService = game:GetService("PathfindingService")
		local groundParams = RaycastParams.new()
		groundParams.FilterType = Enum.RaycastFilterType.Exclude

		-- Where to stand for a patch of pixels: in front of it (walls) or on it (floors), on the ground.
		function Walker.standPoint(center: Vector3, normal: Vector3): Vector3
			local goal = center + (if math.abs(normal.Y) < 0.7 then normal * CONFIG.WALK_STAND_OFF else Vector3.zero)
			groundParams.FilterDescendantsInstances = { LocalPlayer.Character, workspace:FindFirstChild("PaintFolder"), camera }
			local hit = workspace:Raycast(goal + Vector3.yAxis * 4, Vector3.yAxis * -120, groundParams)
			return if hit then hit.Position else goal
		end

		local function arrive(hum: Humanoid, root: BasePart, target: Vector3, timeout: number): boolean
			local t0, lastOrder = os.clock(), os.clock()
			hum:MoveTo(target)
			while alive and not Job.stop and os.clock() - t0 < timeout do
				local flat = (root.Position - target) * Vector3.new(1, 0, 1)
				if flat.Magnitude < 2 then
					return true
				end
				if os.clock() - lastOrder > 1 then
					hum:MoveTo(target) -- MoveTo gives up by itself after 8 s
					lastOrder = os.clock()
				end
				task.wait()
			end
			return false
		end

		-- Walks to `goal` along a computed path (straight there when no path is found). True when the
		-- character ended up next to it.
		function Walker.goTo(goal: Vector3): boolean
			local char, hum = character()
			local root = char and char:FindFirstChild("HumanoidRootPart")
			if not (hum and root and root:IsA("BasePart")) then
				return false
			end
			local path = PathfindingService:CreatePath({ AgentRadius = 2, AgentHeight = 5, AgentCanJump = true, WaypointSpacing = 6 })
			local ok = pcall(function()
				path:ComputeAsync(root.Position, goal)
			end)
			local points = {}
			if ok and path.Status == Enum.PathStatus.Success then
				for _, waypoint in path:GetWaypoints() do
					table.insert(points, { pos = waypoint.Position, jump = waypoint.Action == Enum.PathWaypointAction.Jump })
				end
			end
			pcall(path.Destroy, path)
			if #points == 0 then
				points = { { pos = goal, jump = false } }
			end
			for _, point in points do
				if Job.stop or not alive then
					return false
				end
				if point.jump then
					hum.Jump = true
				end
				local timeout = (root.Position - point.pos).Magnitude / math.max(hum.WalkSpeed, 4) + 2
				if not arrive(hum, root, point.pos, timeout) then
					hum.Jump = true -- stuck on something: hop and try once more
					if not arrive(hum, root, point.pos, 2) then
						break
					end
				end
			end
			hum:MoveTo(root.Position) -- stand still
			return ((root.Position - goal) * Vector3.new(1, 0, 1)).Magnitude < 4
		end
	end

	-- Lays the picture out over the surfaces (see Wrap). Each pixel becomes a step with its grid
	-- cell (x, y), its spot + facing on the surface and its snake-path index (even rows left->right,
	-- odd rows right->left), so consecutive path indices are always neighbouring pixels.
	local function buildSteps(image, anchor, yielder)
		local w, h, rgba = image.w, image.h, image.rgba
		local step = gridStep()
		local xs, ys = table.create(w), table.create(h)
		for i = 1, w do
			xs[i] = (i - 0.5 - w / 2) * step
		end
		for j = 1, h do
			ys[j] = (h / 2 - j + 0.5) * step
		end
		local geo = { w = w, h = h, step = step }
		local skip = skipAlpha()
		local cells = {}
		local offWall = 0
		Wrap.layout(anchor, xs, ys, function(i, j, f)
			local x, y = i - 1, j - 1
			local o = (y * w + x) * 4
			if skip and buffer.readu8(rgba, o + 3) < 128 then
				return
			end
			if not f.ok then
				offWall += 1 -- no paintable surface there: the game would refuse to spray it anyway
				return
			end
			local r, g, b = buffer.readu8(rgba, o), buffer.readu8(rgba, o + 1), buffer.readu8(rgba, o + 2)
			cells[y * w + x] = {
				x = x,
				y = y,
				row = y,
				path = 0,
				letter = if image.letters then image.letters[y * w + x + 1] else nil,
				pos = f.pos,
				normal = f.normal,
				r = r,
				g = g,
				b = b,
				key = r * 65536 + g * 256 + b,
			}
		end, yielder)
		local steps = {}
		local pathIndex = 0
		for y = 0, h - 1 do
			local reverse = y % 2 == 1
			for k = 0, w - 1 do
				local x = if reverse then w - 1 - k else k
				pathIndex += 1
				local cell = cells[y * w + x]
				if cell then
					cell.path = pathIndex
					steps[#steps + 1] = cell
				end
			end
		end
		return steps, geo, offWall
	end

	-- Groups steps by colour (the server keeps only one colour per batch), biggest colour first, each
	-- group in snake-path order. Fresh step copies, so per-pass "done" flags never leak between passes.
	-- Painting order inside a colour: text goes character by character (then snake order inside
	-- the character); everything else just follows the snake path.
	local function stepBefore(a, b): boolean
		if a.letter and b.letter and a.letter ~= b.letter then
			return a.letter < b.letter
		end
		return a.path < b.path
	end

	local function groupByColor(steps)
		local groups, order = {}, {}
		for _, s in steps do
			local group = groups[s.key]
			if not group then
				group = {}
				groups[s.key] = group
				table.insert(order, s.key)
			end
			group[#group + 1] = table.clone(s)
		end
		for _, group in groups do
			table.sort(group, stepBefore)
		end
		table.sort(order, function(a, b)
			return #groups[a] > #groups[b]
		end)
		local list = table.create(#order)
		for _, key in order do
			list[#list + 1] = groups[key]
		end
		return list
	end

	-- Makes sure the player has at least `count` visible layers (adding them through the game's own
	-- AddLayer remote, the Layers panel's "+" button) and returns the lowest `count` layer numbers.
	-- Returns fewer when the game's layer limit is reached.
	local function ensureLayers(myFolder: Instance, count: number): { number }
		local function list(): { number }
			local ids = {}
			for _, folder in myFolder:GetChildren() do
				local id = tonumber(folder.Name)
				if folder:IsA("Folder") and id then
					table.insert(ids, id)
				end
			end
			table.sort(ids)
			return ids
		end
		local ids = list()
		local remotes = ReplicatedStorage:FindFirstChild("Remotes")
		local paintRemotes = remotes and remotes:FindFirstChild("Paint")
		local addLayer = paintRemotes and paintRemotes:FindFirstChild("AddLayer")
		while #ids < count and alive and addLayer and addLayer:IsA("RemoteFunction") do
			local before = #ids
			-- true = the limit is reached (the game's button would offer its gamepass then)
			local ok, full = pcall(function()
				return (addLayer :: RemoteFunction):InvokeServer()
			end)
			restoreCaps()
			if not ok or full then
				break
			end
			local t0 = os.clock()
			repeat
				task.wait()
				ids = list()
			until #ids > before or os.clock() - t0 > 3
			if #ids == before then
				break
			end
		end
		return table.move(ids, 1, math.min(count, #ids), 1, {})
	end

	local function run(image, anchor)
		local paintSettings = LocalPlayer:FindFirstChild("PaintSettings")
		local myFolder = workspace:FindFirstChild("PaintFolder") and workspace.PaintFolder:FindFirstChild(LocalPlayer.Name)
		local picker = colorPicker()
		local appearance = appearanceControls()
		if not (paintSettings and myFolder and picker and appearance) then
			setStatus("Couldn't find the game's paint settings / colour picker / brush controls.", THEME.Bad)
			return
		end
		local layerFolder = myFolder:FindFirstChild(tostring(paintSettings:GetAttribute("Layer") or 1))
		if not layerFolder then
			setStatus("Your current layer doesn't exist — pick one in the game's Layers panel.", THEME.Bad)
			return
		end

		setStatus("Preparing…", THEME.Warn)
		local allSteps, geo, offWall = buildSteps(image, anchor, newYielder(0.006))
		if #allSteps == 0 then
			setStatus("Nothing to paint: that spot isn't a paintable wall. Place it again.", THEME.Bad)
			return
		end
		if not Lanes.available() then
			setStatus("Your executor lacks hookmetamethod/getconnections — can't drive the spray can.", THEME.Bad)
			return
		end
		if not ensureSprayEquipped() then
			setStatus("Couldn't equip the spray can.", THEME.Bad)
			return
		end

		-- Brush setup through the game's own controls; everything is restored afterwards.
		local saved = {}
		for _, name in CONFIG.BRUSH_ATTRIBUTES do
			saved[name] = paintSettings:GetAttribute(name)
		end
		local savedColor = paintSettings:GetAttribute("Color")
		local savedSize = appearance.size:GetAttribute("Value")
		local savedOpacity = appearance.opacity:GetAttribute("Value")
		local savedRotation = appearance.rotation:GetAttribute("Selection")
		Lanes.setPaintSettings(paintSettings)
		Lanes.install()
		Job.maid:Give(function()
			pcall(Lanes.releaseAll)
			Lanes.uninstall()
			local _, hum = character()
			if hum then
				pcall(function()
					hum:MoveTo((hum.RootPart :: BasePart).Position) -- stop any walk in progress
				end)
			end
			UI.hud.Visible = false
			UI.window.Visible = true
			for name, value in saved do
				paintSettings:SetAttribute(name, value)
			end
			pcall(function()
				appearance.size:SetAttribute("Value", savedSize)
				appearance.opacity:SetAttribute("Value", savedOpacity)
				appearance.rotation:SetAttribute("Selection", savedRotation)
			end)
			local pk = colorPicker()
			if pk and typeof(savedColor) == "Color3" then
				pk.SetColor:Fire(GameApi.Colors.processColor(savedColor))
			end
		end)
		-- The server only keeps dots whose brush Size is a multiple of 0.05 (0.30 kept, 0.32 dropped).
		-- k / 20 (not k * 0.05) gives the exact same double as typing 0.15, 0.2, ... into the game.
		local dotSize = math.clamp(math.floor(Settings.pixel * 20 + 0.5) / 20, CONFIG.MIN_DOT, CONFIG.MAX_DOT)
		appearance.size:SetAttribute("Value", dotSize) -- the panel copies this into PaintSettings.Size
		appearance.opacity:SetAttribute("Value", 1)
		appearance.rotation:SetAttribute("Selection", "Fixed")
		local brush = brushName()
		paintSettings:SetAttribute("BrushShape", brush)
		paintSettings:SetAttribute("RainbowEnabled", false)
		paintSettings:SetAttribute("NeonEnabled", false)
		paintSettings:SetAttribute("ChromeEnabled", false)
		paintSettings:SetAttribute("Tool", "None")
		local minGap = math.max(
			dotSize * (workspace:GetAttribute("MinDistanceMultiplierBetweenPaint") or 0.35),
			workspace:GetAttribute("MinSpacing") or 0
		)
		Lanes.setSingleDots(geo.step < minGap * 1.02)

		-- Depth levels on separate layers (see CONFIG.SQUARE_LEVEL_PERIOD).
		local period = if Settings.roundBrush then CONFIG.ROUND_LEVEL_PERIOD else CONFIG.SQUARE_LEVEL_PERIOD
		local levels = period * period
		setStatus(("Preparing %d layers…"):format(levels), THEME.Warn)
		local layerIds = ensureLayers(myFolder, levels)
		local useLayers = #layerIds >= levels
		if not useLayers then
			layerIds = {} -- layer limit reached: depth comes from the lift alone
		end
		local liftStep = CONFIG.DOT_LIFT_MAX / (levels - 1)
		-- every layer folder the picture's dots can end up in (for the missing-pixel check)
		local paintLayers = { layerFolder }
		for _, id in layerIds do
			local folder = myFolder:FindFirstChild(tostring(id))
			if folder and folder ~= layerFolder then
				table.insert(paintLayers, folder)
			end
		end

		-- Spatial index of the picture's pixels (cells one pixel wide), to tell which pixel a dot is.
		-- (The picture can bend around corners, so a dot can't be mapped back with plane maths.)
		local cellSize = geo.step
		local index: { [number]: { [number]: { any } } } = {}
		for _, st in allSteps do
			local q = st.pos / cellSize
			local key = math.floor(q.X) * 1e7 + math.floor(q.Y)
			local plane = index[key]
			if not plane then
				plane = {}
				index[key] = plane
			end
			local iz = math.floor(q.Z)
			local list = plane[iz]
			if not list then
				list = {}
				plane[iz] = list
			end
			list[#list + 1] = st
		end
		-- Calls visit(step, distance) for every pixel within `radius` (<= one cell) of `pos`.
		local function forNear(pos: Vector3, radius: number, visit: (any, number) -> ())
			local q = pos / cellSize
			local ix, iy, iz = math.floor(q.X), math.floor(q.Y), math.floor(q.Z)
			for dx = -1, 1 do
				for dy = -1, 1 do
					local plane = index[(ix + dx) * 1e7 + iy + dy]
					if plane then
						for dz = -1, 1 do
							local list = plane[iz + dz]
							if list then
								for _, st in list do
									local d = (st.pos - pos).Magnitude
									if d <= radius then
										visit(st, d)
									end
								end
							end
						end
					end
				end
			end
		end
		local nearestFound, nearestDist = nil, math.huge
		local function keepNearest(st, d: number)
			if d < nearestDist then
				nearestFound, nearestDist = st, d
			end
		end

		-- Depth level for every dot of this picture: all of them pass through the game's
		-- ClientToServer.cachePaint (the game looks the function up on the module table each call),
		-- so a wrapper there moves each dot to its level's layer and lifts it just before it's sent.
		-- (The local preview copy stays in the current layer; the server's copy goes to info.Layer.)
		local C2S = GameApi.ClientToServer
		local originalCache = C2S.cachePaint
		C2S.cachePaint = function(part, info)
			if type(info) == "table" and typeof(info.CFrame) == "CFrame" then
				nearestFound, nearestDist = nil, math.huge
				forNear(info.CFrame.Position, geo.step * 0.6, keepNearest)
				local st = nearestFound
				if st then
					local level = (st.y % period) * period + (st.x % period)
					if useLayers then
						info.Layer = layerIds[level + 1]
					end
					if level > 0 then
						info.CFrame = info.CFrame + st.normal * (level * liftStep)
						pcall(function()
							part.CFrame = info.CFrame
						end)
					end
				end
			end
			return originalCache(part, info)
		end
		Job.maid:Give(function()
			if C2S.cachePaint ~= originalCache then
				C2S.cachePaint = originalCache
			end
		end)

		-- Every dot the game sprays appears locally first (tagged "Client"); a dot at a lane's target
		-- confirms it. The radius is tight so a dot one pixel away never counts.
		local tolerance = geo.step * 0.45
		local activeLanes = {}
		local pendingLocal = 0 -- local dots the game hasn't had answered by the server yet
		Job.maid:Give(layerFolder.DescendantRemoving:Connect(function(d)
			if d:IsA("BasePart") and d:HasTag("Client") then
				pendingLocal = math.max(0, pendingLocal - 1)
			end
		end))
		Job.maid:Give(layerFolder.DescendantAdded:Connect(function(d)
			if not (d:IsA("BasePart") and d:HasTag("Client")) then
				return
			end
			pendingLocal += 1
			local pos = d.Position
			for _, lane in activeLanes do
				local t = lane.target
				if t and not t.done and (pos - t.pos).Magnitude <= tolerance then
					t.done = true
					lane.confirmed += lane.targetEnd - lane.idx + 1
					return
				end
			end
		end))

		local function flush()
			local t0 = os.clock()
			while pendingLocal > 0 and os.clock() - t0 < CONFIG.FLUSH_TIMEOUT and alive do
				task.wait()
			end
		end

		-- Which wanted pixels are NOT on the server yet: a pixel counts once a server dot of the right
		-- colour and size covers its centre (so this also works for repainting over older paint).
		local function findMissing()
			flush()
			task.wait(0.25)
			local covered = {}
			local reach = (dotSize / 2) * 0.85 -- studs: a bit inside the dot's edge
			local yielder = newYielder(0.006)
			local dotR, dotG, dotB = 0, 0, 0
			local function coverIfSameColour(st)
				if math.abs(dotR - st.r) <= CONFIG.COLOR_MATCH and math.abs(dotG - st.g) <= CONFIG.COLOR_MATCH and math.abs(dotB - st.b) <= CONFIG.COLOR_MATCH then
					covered[st] = true
				end
			end
			for _, folder in paintLayers do
				for _, stroke in folder:GetChildren() do
					for _, part in stroke:GetChildren() do
						if part:IsA("BasePart") and part.Name == brush and not part:HasTag("Client") and not part:HasTag("SprayArtistLocal") and math.abs(part.Size.X - dotSize) < 0.01 then
							local c = part.Color
							dotR, dotG, dotB = c.R * 255, c.G * 255, c.B * 255
							forNear(part.Position, reach, coverIfSameColour)
						end
					end
					yielder()
				end
			end
			local missing = {}
			for _, s in allSteps do
				if not covered[s] then
					missing[#missing + 1] = s
				end
			end
			return missing
		end

		local Colors = GameApi.Colors
		Lanes.probe()
		-- Several lanes only work when they can each steer the shared last position; text keeps one
		-- lane so it really goes character by character.
		local laneLimit = if Lanes.canSteer() and not image.letters then math.clamp(Settings.lanes, 1, CONFIG.MAX_LANES) else 1
		local startTime = os.clock()
		local paintedTotal = 0
		local lastUi = 0

		-- Picks the colour in the game's picker, waits until the game has really switched to it,
		-- then pauses a moment before spraying (never any overlap between two colours).
		local function selectColor(s)
			local wanted = Colors.processColor(Color3.fromRGB(s.r, s.g, s.b))
			picker.SetColor:Fire(wanted) -- synchronous: PaintSettings.Color is already updated after this
			local t0 = os.clock()
			while alive and not Job.stop and os.clock() - t0 < 1 do
				local current = paintSettings:GetAttribute("Color")
				if typeof(current) == "Color3" and math.abs(current.R - wanted.R) + math.abs(current.G - wanted.G) + math.abs(current.B - wanted.B) < 0.01 then
					break
				end
				task.wait()
			end
			if Settings.colorPause > 0 then
				task.wait(Settings.colorPause * 0.4)
			end
		end

		-- Ends a colour. Strictly one colour at a time: with a pause > 0 it waits until the game has
		-- sent every dot of this colour AND the server has answered (its local preview dots disappear
		-- then), then pauses. With the pause at 0 there's no wait at all: the game delays caching a
		-- dot and sending a batch by the same 0.2 s, so everything sprayed before the release still
		-- goes out in the release's batch and the next colour's dots land in the next one.
		local function finishColor(passLabel: string)
			if Settings.colorPause <= 0 then
				return
			end
			setStatus(("%s · switching colour…"):format(passLabel), THEME.Good)
			flush()
			task.wait(Settings.colorPause)
		end

		-- Paints one colour with up to laneLimit lanes; returns how many pixels were confirmed.
		local function paintColor(group, passLabel: string, passDone: number, passTotal: number): number
			local count = math.clamp(math.ceil(#group / CONFIG.MIN_STEPS_PER_LANE), 1, laneLimit)
			local per = math.ceil(#group / count)
			local lanes = {}
			for j = 1, count do
				local first, last = (j - 1) * per + 1, math.min(j * per, #group)
				if first <= last then
					lanes[#lanes + 1] = Lanes.new(table.move(group, first, last, 1, table.create(last - first + 1)))
				end
			end
			activeLanes = lanes
			selectColor(group[1])

			local function pressAll()
				for _, lane in lanes do
					if not lane.finished then
						lane.target, lane.last, lane.ray, lane.from = nil, nil, Lanes.SKY, nil
						Lanes.press(lane)
					end
				end
			end
			pressAll()

			local confirmed, lastConfirmed, lastChange, restarts = 0, -1, os.clock(), 0
			while alive and not Job.stop do
				Lanes.refill(Settings.maxRate, task.wait())
				local finished = true
				confirmed = 0
				for _, lane in lanes do
					confirmed += lane.confirmed
					if not lane.finished then
						finished = false
					end
				end
				local now = os.clock()
				if now - lastUi > 0.2 then
					lastUi = now
					local rate = (paintedTotal + confirmed) / math.max(now - startTime, 0.01)
					setStatus(("%s %s / %s · %d px/s · %d lanes"):format(
						passLabel,
						formatInt(passDone + confirmed),
						formatInt(passTotal),
						math.floor(rate),
						#lanes
					), THEME.Good)
					setProgress(passDone + confirmed, passTotal)
				end
				if finished then
					break
				end
				if Job.paused or not sprayEquipped() then
					Lanes.releaseAll()
					if not waitWhile(function()
						return Job.paused or not ensureSprayEquipped()
					end, if Job.paused then "Paused." else "Equip the spray can to keep painting…") then
						break
					end
					paintSettings:SetAttribute("Tool", "None")
					pressAll()
					lastChange = os.clock()
				elseif confirmed ~= lastConfirmed then
					lastConfirmed, lastChange = confirmed, now
				elseif now - lastChange > CONFIG.STALL_SECONDS then
					-- The loops stopped painting (tool swapped, respawn, too far…): press again.
					restarts += 1
					if restarts > 3 then
						break -- leave the rest to the repaint pass / next Paint! press
					end
					Lanes.releaseAll()
					task.wait()
					pressAll()
					lastChange = os.clock()
				end
			end
			-- Release ends this colour. Strictly one colour at a time: wait until the game has sent every
			-- dot of this colour AND the server has answered (its local preview dots disappear then),
			-- then pause before the next colour is picked.
			Lanes.releaseAll()
			activeLanes = {}
			finishColor(passLabel)
			return confirmed
		end

		-- Pixels within spraying range of where the character stands now, and the rest.
		local reachStuds = CONFIG.RANGE - CONFIG.WALK_MARGIN
		local function splitByReach(list)
			local root = rootPosition()
			if not root then
				return {}, list
			end
			local near, far = {}, {}
			for _, st in list do
				if (st.pos - root).Magnitude <= reachStuds then
					near[#near + 1] = st
				else
					far[#far + 1] = st
				end
			end
			return near, far
		end

		-- Walks towards the patch of `far` nearest to the character; returns the pixel aimed at.
		local function walkToNext(far)
			local root = rootPosition() or far[1].pos
			local seed, best = far[1], math.huge
			for _, st in far do
				local d = (st.pos - root).Magnitude
				if d < best then
					seed, best = st, d
				end
			end
			local sum, normalSum, count = Vector3.zero, Vector3.zero, 0
			for _, st in far do
				if (st.pos - seed.pos).Magnitude <= CONFIG.WALK_PATCH then
					sum += st.pos
					normalSum += st.normal
					count += 1
				end
			end
			local normal = if normalSum.Magnitude > 1e-3 then normalSum.Unit else seed.normal
			setStatus("Walking to the next part of the picture…", THEME.Warn)
			Walker.goTo(Walker.standPoint(sum / count, normal))
			return seed
		end

		local pass = 0
		local remaining = 0
		while alive and not Job.stop do
			setStatus(if pass == 0 then "Checking the wall…" else "Checking for missing pixels…", THEME.Warn)
			local missing = findMissing()
			remaining = #missing
			if remaining == 0 or pass >= CONFIG.MAX_PASSES then
				break
			end
			pass += 1
			local passLabel = if pass == 1 and remaining == #allSteps then "Painting" else ("Fixing %d missing (pass %d):"):format(remaining, pass)
			local passDone = 0
			-- Paint everything within reach of where the character stands, then walk to the nearest
			-- part that's left (big pictures), until this pass is through.
			local queue = missing
			while #queue > 0 and alive and not Job.stop do
				local near, far = splitByReach(queue)
				if #near == 0 then
					if not Settings.autoWalk then
						break -- out of range: stays missing
					end
					local seed = walkToNext(far)
					near, far = splitByReach(queue)
					if #near == 0 then
						-- couldn't get close enough (no way there / too high up): leave that patch
						local keep = {}
						for _, st in far do
							if (st.pos - seed.pos).Magnitude > CONFIG.WALK_PATCH then
								keep[#keep + 1] = st
							end
						end
						queue = keep
						continue
					end
					if not ensureSprayEquipped() then
						break
					end
				end
				for _, group in groupByColor(near) do
					if Job.stop or not alive then
						break
					end
					local confirmed = paintColor(group, passLabel, passDone, remaining)
					passDone += confirmed
					paintedTotal += confirmed
				end
				queue = far
			end
		end

		setProgress(#allSteps - remaining, #allSteps)
		local elapsed = os.clock() - startTime
		local summary = ("%s px painted in %.1fs"):format(formatInt(paintedTotal), elapsed)
		if offWall > 0 then
			summary ..= (" · %s off the wall"):format(formatInt(offWall))
		end
		if Job.stop then
			setStatus("Stopped. " .. summary .. " · press Paint! again to finish it.", THEME.Warn)
		elseif remaining > 0 then
			setStatus(("%s still missing after %d passes (out of reach?). Press Paint! again to retry. %s"):format(formatInt(remaining), pass, summary), THEME.Warn)
		else
			setStatus("Done — every pixel is on the wall! " .. summary, THEME.Good)
		end
	end

	function Painter.start()
		if Job.running then
			return
		end
		if State.placing then
			Placement.finish(true)
		end
		local image, anchor = State.image, State.anchor
		if not image then
			setStatus("Load an image first.", THEME.Warn)
			return
		end
		if not anchor then
			setStatus("Press Place first.", THEME.Warn)
			return
		end
		-- Range pre-check on the four corners so the user knows before anything is sprayed.
		local rootPos = rootPosition()
		if rootPos and not Settings.autoWalk then
			local hw, hh = image.w * gridStep() / 2, image.h * gridStep() / 2
			local far = 0
			for _, sx in { -1, 1 } do
				for _, sy in { -1, 1 } do
					local cornerPos = anchor.center + anchor.right * (hw * sx) + anchor.up * (hh * sy)
					far = math.max(far, (cornerPos - rootPos).Magnitude)
				end
			end
			if far > CONFIG.RANGE then
				setStatus(("A corner is %d studs away (max %d). Walk closer, lower the Size, or turn on walking."):format(math.floor(far), math.floor(CONFIG.RANGE)), THEME.Bad)
				return
			end
		end
		Job.running, Job.paused, Job.stop = true, false, false
		UI.pauseButton.Text = "Pause"
		Ghost.hide() -- the ghost would sit on top of the real paint
		Job.thread = task.spawn(function()
			local ok, err = xpcall(run, debug.traceback, image, anchor)
			if not ok then
				Job.lastError = tostring(err)
				warn("[SprayArtist] " .. tostring(err))
				-- never let a failing status update leave the job stuck as "running"
				pcall(setStatus, "Painter error: " .. tostring(err):sub(1, 180), THEME.Bad)
			end
			pcall(Job.maid.Cleanup, Job.maid)
			Job.running, Job.paused, Job.thread = false, false, nil
			-- The anchor is kept: pressing Paint! again on the same spot only fills what's missing.
			if UI.pauseButton then
				UI.pauseButton.Text = "Pause"
			end
		end)
	end

	function Painter.togglePause()
		if not Job.running then
			return
		end
		Job.paused = not Job.paused
		UI.pauseButton.Text = if Job.paused then "Resume" else "Pause"
	end

	function Painter.stop()
		if Job.running then
			Job.stop = true
			Job.paused = false
		elseif State.placing then
			Placement.finish(false)
		else
			State.anchor = nil
			Ghost.hide()
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Remaining UI (settings, actions, progress)
---------------------------------------------------------------------------------------------------
-- Actions right under the picture: 1 Load -> 2 Place on wall -> 3 Paint!
do
	local row = Row(UI.content, 34)
	UI.loadButton = Button(row, "1  Load", "secondary", loadImage)
	UI.loadButton.Size = UDim2.new(1 / 3, -6, 1, 0)
	local place = Button(row, "2  Place", "plain", Placement.begin)
	place.Size = UDim2.new(1 / 3, -6, 1, 0)
	local paint = Button(row, "3  Paint!", "primary", Painter.start)
	paint.Size = UDim2.new(1 / 3, -6, 1, 0)
end
do
	local row = Row(UI.content, 30)
	UI.pauseButton = Button(row, "Pause", "plain", Painter.togglePause)
	UI.pauseButton.Size = UDim2.new(0.5, -4, 1, 0)
	local stopBtn = Button(row, "Stop", "plain", Painter.stop)
	stopBtn.Size = UDim2.new(0.5, -4, 1, 0)
end
UI.progress = create("Frame", {
	BackgroundColor3 = THEME.Field,
	Size = UDim2.new(1, 0, 0, 6),
	LayoutOrder = nextOrder(),
	Parent = UI.content,
}, { corner(UDim.new(1, 0)) })
UI.progressFill = create("Frame", {
	BackgroundColor3 = THEME.Good,
	Size = UDim2.fromScale(0, 1),
	Parent = UI.progress,
}, { corner(UDim.new(1, 0)) })
UI.status = label(UI.content, "Ready.", {
	TextSize = THEME.SmallText + 1,
	TextColor3 = THEME.SubText,
	TextWrapped = true,
	AutomaticSize = Enum.AutomaticSize.Y,
})

-- A titled group of settings with a one-line explanation.
local function section(title: string, hint: string)
	create("Frame", { -- divider
		BackgroundColor3 = THEME.Stroke,
		BackgroundTransparency = 0.4,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 1),
		LayoutOrder = nextOrder(),
		Parent = UI.content,
	})
	label(UI.content, title, { FontFace = THEME.FontBold, TextColor3 = THEME.Accent, TextSize = THEME.SmallText + 2, Size = UDim2.new(1, 0, 0, 20) })
end

local reprocessToken = 0
local function scheduleReprocess()
	reprocessToken += 1
	local token = reprocessToken
	task.delay(0.15, function() -- debounce: colour count changes rebuild the palette
		if alive and token == reprocessToken then
			processImage()
		end
	end)
end

-- Width / Height show the picture's real size (after the MAX_SIDE cap and, with Keep shape on,
-- the picture's own proportions).
local function syncSizeSliders()
	if not (UI.widthSlider and UI.heightSlider) then
		return
	end
	local tw, th = picturePixels()
	local step = gridStep()
	UI.widthSlider.set(tw * step, false)
	UI.heightSlider.set(th * step, false)
end
UI.syncSize = syncSizeSliders
local function sizeChanged()
	syncSizeSliders()
	-- the placed preview resizes right away (stretching the current picture until the new one is
	-- processed); the processing itself starts immediately and older runs are cancelled
	if State.anchor and State.image and not State.placing and not Job.running then
		local tw, th = picturePixels()
		Ghost.show(State.anchor, tw, th, gridStep(), 0.45)
	end
	saveSettings()
	processImage()
end

local function studsText(v: number): string
	return ("%g studs"):format(math.floor(v * 10 + 0.5) / 10)
end

section("Size", "")
UI.widthSlider = Slider(UI.content, {
	label = "Width",
	min = CONFIG.MIN_STUDS,
	max = CONFIG.MAX_STUDS,
	step = 0.5,
	value = Settings.sizeX,
	format = studsText,
	onChanged = function(v)
		Settings.sizeX = v
		sizeChanged()
	end,
})
UI.heightSlider = Slider(UI.content, {
	label = "Height",
	min = CONFIG.MIN_STUDS,
	max = CONFIG.MAX_STUDS,
	step = 0.5,
	value = Settings.sizeY,
	format = studsText,
	onChanged = function(v)
		Settings.sizeY = v
		local src = State.source
		if Settings.keepShape and src then
			-- keeping the shape: the height drives the width
			Settings.sizeX = math.clamp(v * src.w / src.h, CONFIG.MIN_STUDS, CONFIG.MAX_STUDS)
		end
		sizeChanged()
	end,
})
Toggle(UI.content, "Keep shape", Settings.keepShape, function(v)
	Settings.keepShape = v
	if not v then
		local _, th = picturePixels()
		Settings.sizeY = th * gridStep() -- unlocking starts from the current height
	end
	sizeChanged()
end)
UI.pixelSlider = Slider(UI.content, {
	label = "Pixel size",
	min = CONFIG.MIN_DOT,
	max = 0.6,
	step = 0.05,
	value = Settings.pixel,
	format = function(v)
		return ("%.2f studs"):format(v)
	end,
	onChanged = function(v)
		Settings.pixel = v
		sizeChanged() -- same size on the wall, so the number of pixels changes
	end,
})
Toggle(UI.content, "Round brush", Settings.roundBrush, function(v)
	Settings.roundBrush = v
	sizeChanged()
end)

section("Look", "")
UI.colorsSlider = Slider(UI.content, {
	label = "Colours",
	min = 4,
	max = 64,
	step = 1,
	value = Settings.colors,
	format = function(v)
		return tostring(v)
	end,
	onChanged = function(v)
		Settings.colors = v
		saveSettings()
		scheduleReprocess()
	end,
})
Toggle(UI.content, "Dither", Settings.dither, function(v)
	Settings.dither = v
	saveSettings()
	processImage()
end)
Toggle(UI.content, "Sharpen", Settings.enhance, function(v)
	Settings.enhance = v
	saveSettings()
	processImage()
end)
Toggle(UI.content, "True colours", Settings.trueColors, function(v)
	Settings.trueColors = v
	saveSettings()
	processImage()
end)
Toggle(UI.content, "Skip transparent", Settings.skipTransparent, function(v)
	Settings.skipTransparent = v
	saveSettings()
	processImage()
end)

section("Speed", "")
UI.rateSlider = Slider(UI.content, {
	label = "Speed",
	min = CONFIG.MIN_RATE,
	max = CONFIG.MAX_RATE,
	step = 10,
	value = Settings.maxRate,
	format = function(v)
		return ("%d px/s"):format(v)
	end,
	onChanged = function(v)
		Settings.maxRate = v
		saveSettings()
		updateInfo()
	end,
})
UI.lanesSlider = Slider(UI.content, {
	label = "Lanes",
	min = 1,
	max = CONFIG.MAX_LANES,
	step = 1,
	value = Settings.lanes,
	format = function(v)
		return ("%dx"):format(v)
	end,
	onChanged = function(v)
		Settings.lanes = v
		saveSettings()
	end,
})
UI.pauseSlider = Slider(UI.content, {
	label = "Colour pause",
	min = 0,
	max = 2,
	step = 0.1,
	value = Settings.colorPause,
	format = function(v)
		return ("%.1f s"):format(v)
	end,
	onChanged = function(v)
		Settings.colorPause = v
		saveSettings()
		updateInfo()
	end,
})

section("Extras", "")
do
	-- The game's own /fart chat command (the server plays it for everyone). While the toggle is on it
	-- repeats every FART_INTERVAL seconds (verified: the server plays every one at 0.5 s apart).
	local FART_INTERVAL = 0.5
	local fartRemote = game:GetService("ReplicatedStorage"):FindFirstChild("Remotes")
	fartRemote = fartRemote and fartRemote:FindFirstChild("Misc")
	fartRemote = fartRemote and fartRemote:FindFirstChild("Fart")
	if fartRemote and fartRemote:IsA("RemoteEvent") then
		local fartThread: thread? = nil
		local function stopFarting()
			if fartThread then
				pcall(task.cancel, fartThread)
				fartThread = nil
			end
		end
		Toggle(UI.content, "Fart", false, function(on)
			stopFarting()
			if on then
				fartThread = task.spawn(function()
					while alive do
						fartRemote:FireServer()
						task.wait(FART_INTERVAL)
					end
				end)
			end
		end)
		maid:Give(stopFarting)
	end
end
Slider(UI.content, {
	label = "Rotate step (R key)",
	min = 15,
	max = 180,
	step = 15,
	value = Settings.rotateStep,
	format = function(v)
		return ("%d°"):format(v)
	end,
	onChanged = function(v)
		Settings.rotateStep = v
		saveSettings()
	end,
})
Toggle(UI.content, "Auto walk", Settings.autoWalk, function(v)
	Settings.autoWalk = v
	saveSettings()
end)
Toggle(UI.content, "Sponge all layers", Settings.spongeAllLayers, function(v)
	Settings.spongeAllLayers = v
	saveSettings()
end)
Toggle(UI.content, "Clean view", Settings.cleanView, function(v)
	Settings.cleanView = v
	saveSettings()
	LightingFx.setClean(v)
end)
LightingFx.setClean(Settings.cleanView)
syncSizeSliders()

label(UI.content, "Paints with the game's own spray can + colour picker without moving your mouse, then repaints anything missing — don't click in-game while it paints. Red preview tiles = nothing paintable there. RightShift hides this window / stops painting.", {
	TextSize = THEME.SmallText - 1,
	TextColor3 = THEME.SubText,
	TextTransparency = 0.3,
	TextWrapped = true,
	AutomaticSize = Enum.AutomaticSize.Y,
})


-- Slim HUD while the real mouse draws (the window hides so the cursor can't click it).
-- Active = false everywhere so it never swallows the cursor's clicks.
UI.hud = create("Frame", {
	Active = false,
	Visible = false,
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 64),
	Size = UDim2.fromOffset(520, 34),
	BackgroundColor3 = THEME.Bg,
	BackgroundTransparency = 0.15,
	Parent = UI.gui,
}, { corner(), stroke(THEME.Stroke, 0.3) })
UI.hudText = create("TextLabel", {
	Active = false,
	BackgroundTransparency = 1,
	FontFace = THEME.FontBold,
	TextSize = THEME.SmallText + 1,
	TextColor3 = THEME.Text,
	TextTruncate = Enum.TextTruncate.AtEnd,
	Text = "",
	Size = UDim2.new(1, -16, 1, 0),
	Position = UDim2.fromOffset(8, 0),
	Parent = UI.hud,
})

-- Tabs behaviour ----------------------------------------------------------------------------------
local function selectMode(key: string)
	Settings.mode = key
	for _, mode in MODES do
		local btn = UI.tabs[mode.key]
		local selected = mode.key == key
		tween(btn, {
			BackgroundColor3 = if selected then THEME.Accent2 else THEME.Field,
			TextColor3 = if selected then THEME.Text else THEME.SubText,
		})
		if selected then
			UI.input.PlaceholderText = mode.hint
		end
	end
	UI.loadButton.Text = if key == "Text" then "1  Make text" else "1  Load"
	UI.textColorRow.Visible = key == "Text"
	UI.avatarRow.Visible = key == "Avatar"
end
for _, mode in MODES do
	maid:Give(UI.tabs[mode.key].Activated:Connect(function()
		selectMode(mode.key)
		saveSettings()
	end))
end
selectMode(if UI.tabs[Settings.mode] then Settings.mode else "Text")
maid:Give(UI.avatarStyleButton.Activated:Connect(function()
	local current = CONFIG.AVATAR_STYLES[Settings.avatarStyle] or CONFIG.AVATAR_STYLES.Full
	Settings.avatarStyle = current.nextStyle
	UI.avatarStyleButton.Text = CONFIG.AVATAR_STYLES[Settings.avatarStyle].label
	saveSettings()
	-- an avatar is already loaded: reload it in the new style straight away
	if Settings.mode == "Avatar" and State.source and State.source.cutout and not State.source.text and UI.input.Text:match("%S") then
		loadImage()
	end
end))
maid:Give(UI.textColorBox.FocusLost:Connect(function()
	local hex = UI.textColorBox.Text:gsub("[^%x]", ""):upper()
	if #hex == 3 then
		hex = hex:sub(1, 1):rep(2) .. hex:sub(2, 2):rep(2) .. hex:sub(3, 3):rep(2)
	end
	if #hex ~= 6 then
		UI.textColorBox.Text = "#" .. Settings.textColor -- invalid: keep the old colour
		return
	end
	Settings.textColor = hex
	UI.textColorBox.Text = "#" .. hex
	UI.textColorSwatch.BackgroundColor3 = Color3.fromHex(hex)
	saveSettings()
end))
maid:Give(UI.input.FocusLost:Connect(function(enterPressed)
	if enterPressed then
		loadImage()
	end
end))

---------------------------------------------------------------------------------------------------
-- Input (one connection each, dispatching by state)
---------------------------------------------------------------------------------------------------
local drag = { active = false, startInput = Vector2.zero, startPos = UDim2.new() }

maid:Give(UI.titleBar.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		drag.active = true
		drag.startInput = Vector2.new(input.Position.X, input.Position.Y)
		drag.startPos = UI.window.Position
	end
end))

maid:Give(UserInputService.InputChanged:Connect(function(input)
	local kind = input.UserInputType
	if kind ~= Enum.UserInputType.MouseMovement and kind ~= Enum.UserInputType.Touch then
		return
	end
	if UI.activeSlider then
		UI.activeSlider.setFromX(input.Position.X)
	elseif drag.active then
		local delta = Vector2.new(input.Position.X, input.Position.Y) - drag.startInput
		local viewport = camera.ViewportSize
		local size = UI.window.AbsoluteSize
		local start = drag.startPos
		-- clamp so the window can't be dragged off-screen (AnchorPoint is (0, 0.5))
		local x = math.clamp(start.X.Offset + delta.X, 0, math.max(0, viewport.X - size.X))
		local yScaled = start.Y.Scale * viewport.Y + start.Y.Offset + delta.Y
		local y = math.clamp(yScaled, size.Y / 2, math.max(size.Y / 2, viewport.Y - size.Y / 2))
		UI.window.Position = UDim2.fromOffset(x, y)
	end
end))

maid:Give(UserInputService.InputEnded:Connect(function(input)
	local kind = input.UserInputType
	if kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.Touch then
		UI.activeSlider = nil
		drag.active = false
	end
end))

maid:Give(UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if input.KeyCode == CONFIG.TOGGLE_KEY and not gameProcessed then
		if Job.running then
			Painter.stop() -- the window is hidden while drawing; the same key stops it
			return
		end
		UI.window.Visible = not UI.window.Visible
		if not UI.window.Visible and State.placing then
			Placement.finish(false) -- hiding the UI also stops the placement render loop
		end
		return
	end
	if input.KeyCode == Enum.KeyCode.R and not gameProcessed and not Job.running and (State.placing or State.anchor) then
		Placement.rotate()
		return
	end
	if not State.placing then
		return
	end
	if input.KeyCode == Enum.KeyCode.Escape then
		Placement.finish(false)
	elseif input.UserInputType == Enum.UserInputType.MouseButton1 and not gameProcessed then
		Placement.finish(true)
	end
end))

maid:Give(workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	camera = workspace.CurrentCamera
end))

---------------------------------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------------------------------
local function Cleanup()
	if not alive then
		return
	end
	alive = false
	maid:Cleanup()
	if genv.SprayArtist and genv.SprayArtist.Cleanup == Cleanup then
		genv.SprayArtist = nil
	end
end
maid:Give(UI.closeButton.Activated:Connect(Cleanup))
genv.SprayArtist = {
	Cleanup = Cleanup,
	-- handles for driving/inspecting the tool from the executor console
	Debug = { State = State, Settings = Settings, Sources = Sources, Imaging = Imaging, UI = UI, Job = Job, loadImage = loadImage, processImage = processImage, Painter = Painter, Placement = Placement, LightingFx = LightingFx, Wrap = Wrap, Ghost = Ghost },
}

setStatus("Ready.", THEME.SubText)
