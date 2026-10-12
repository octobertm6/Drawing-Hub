-- Free Draw — Image Auto-Draw (PlaceId 72039880963188)
-- Draws any image URL onto the big canvas by sending part batches straight to the game's DrawEvent,
-- exactly like the in-game Pixel tool does, just thousands of parts per second instead of one per click.
--
-- Pipeline: URL -> images.weserv.nl (resize + PNG) -> getcustomasset -> EditableImage
--           -> Oklab median-cut + k-means palette -> rectangle merger (same-colour runs become one part)
--           -> DrawEvent batches (100 parts each, new stroke id every 5000 parts).
--
-- Verified live (2026-10-12):
--   * DrawEvent:FireServer(strokeId, parts, isFinal, layerId, transparency, rainbow, neon, universal, zOffset, layerOpacity)
--     parts[i] = { CFrame, Size, Color, Shape, Opacity, PartName }. Any size/position/colour is kept.
--   * The 5th argument is TRANSPARENCY (0 = solid). 50..250-part batches sent back to back all land
--     (~3,000 parts/s); 20 x 500-part batches fired instantly into ONE stroke lost everything after the first.
--   * A stroke's colour set is fixed by its FIRST batch: any later batch that adds a new colour is rejected
--     (StrokeLimitEvent, the client undoes the stroke). Repeated rejections block the whole session, even hand
--     drawing, until you rejoin. So: one stroke per colour.
--   * Starting a new stroke while the server is still finalising the previous one is rejected too (the
--     finalise time grows with stroke size), so we wait until every part of a stroke has replicated back
--     before the next StrokeStart.
--   * Limit: 200,000 live parts per player (300,000 with the gamepass). Undo = RemovePartEvent(strokeId, count).
--   * The client forces your OWN server parts to Transparency 1 (StrokeCreateModule) and shows local copies
--     instead, so we disable that per-part connection and show the server parts directly.

if not game:IsLoaded() then
	game.Loaded:Wait()
end

----------------------------------------------------------------------------------------------------
-- Launcher: join the game if we're somewhere else, and re-run this script after the teleport.
-- After the teleport it re-runs from <executor workspace>/free_draw.lua if present, else from GitHub.
----------------------------------------------------------------------------------------------------
local TARGET_PLACE_ID = 72039880963188
local SCRIPT_FILE = "free_draw.lua"
-- When launched from the drawing hub bundle, the hub supplies code that relaunches the whole bundle instead.
local launcherEnv: any = if type(getgenv) == "function" then getgenv() else _G
-- Standalone: the local copy if there is one, otherwise this script's copy on GitHub.
local SCRIPT_URL = "https://raw.githubusercontent.com/octobertm6/Drawing-Hub/main/scripts/free_draw.lua"
local RELAUNCH = launcherEnv.__DRAW_HUB_RELAUNCH
	or `local src = if type(isfile) == "function" and isfile("{SCRIPT_FILE}") then readfile("{SCRIPT_FILE}") else game:HttpGet("{SCRIPT_URL}"); loadstring(src, "free_draw")()`

local function teleportToGame()
	local queue = if type(queue_on_teleport) == "function" then queue_on_teleport
		elseif type(syn) == "table" and type(syn.queue_on_teleport) == "function" then syn.queue_on_teleport
		else nil
	if queue then
		pcall(queue, RELAUNCH)
	else
		warn("[FreeDraw] no queue_on_teleport: run the script again once you're in the game")
	end
	game:GetService("TeleportService"):Teleport(TARGET_PLACE_ID, game:GetService("Players").LocalPlayer)
end

if game.PlaceId ~= TARGET_PLACE_ID then
	print("[FreeDraw] not in Free Draw, teleporting…")
	teleportToGame()
	return
end

----------------------------------------------------------------------------------------------------
-- Re-execution guard
----------------------------------------------------------------------------------------------------
local genv: any = if type(getgenv) == "function" then getgenv() else _G
if genv.__FREEDRAW_AUTODRAW and type(genv.__FREEDRAW_AUTODRAW.Cleanup) == "function" then
	pcall(genv.__FREEDRAW_AUTODRAW.Cleanup)
end

----------------------------------------------------------------------------------------------------
-- Services & executor features
----------------------------------------------------------------------------------------------------
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")
local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CoreGui = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer

local Exec = {
	request = (if type(request) == "function" then request elseif type(http_request) == "function" then http_request else nil) :: any,
	writefile = (if type(writefile) == "function" then writefile else nil) :: any,
	delfile = (if type(delfile) == "function" then delfile else nil) :: any,
	makefolder = (if type(makefolder) == "function" then makefolder else nil) :: any,
	getcustomasset = (if type(getcustomasset) == "function" then getcustomasset else nil) :: any,
	gethui = (if type(gethui) == "function" then gethui else nil) :: any,
	getconnections = (if type(getconnections) == "function" then getconnections else nil) :: any,
}

do
	local missing = {}
	for _, name in { "request", "writefile", "getcustomasset" } do
		if not Exec[name] then
			table.insert(missing, name)
		end
	end
	if #missing > 0 then
		error("[FreeDraw] executor is missing: " .. table.concat(missing, ", "))
	end
end

----------------------------------------------------------------------------------------------------
-- Game references (remotes + the layer module the game itself uses)
----------------------------------------------------------------------------------------------------
local Game = {}
do
	local function remote(name: string): RemoteEvent
		local r = ReplicatedStorage:FindFirstChild(name)
		if not r then
			error("[FreeDraw] missing remote " .. name .. " (wrong game?)")
		end
		return r :: RemoteEvent
	end
	Game.DrawEvent = remote("DrawEvent")
	Game.StrokeStartEvent = remote("StrokeStartEvent")
	Game.AddPartCountEvent = remote("AddPartCountEvent")
	Game.RemovePartEvent = remote("RemovePartEvent")
	Game.AddPartCountBindable = ReplicatedStorage:FindFirstChild("AddPartCountBindable") :: BindableEvent?
	Game.StrokeLimitEvent = ReplicatedStorage:FindFirstChild("StrokeLimitEvent") :: RemoteEvent?
	local ok, layers = pcall(require, ReplicatedStorage.Modules.LayerManagerModule)
	Game.Layers = if ok then layers else nil
	-- Same module instance the game uses (it requires via StarterPlayer), so LivePartCount is live.
	local okCfg, cfg = pcall(require, game.StarterPlayer.StarterPlayerScripts.LocalModules.ClientDrawingConfig)
	Game.Config = if okCfg then cfg else nil
end

----------------------------------------------------------------------------------------------------
-- Theme & constants
----------------------------------------------------------------------------------------------------
local Theme = table.freeze({
	Bg = Color3.fromRGB(18, 20, 26),
	Panel = Color3.fromRGB(26, 29, 37),
	Field = Color3.fromRGB(36, 40, 51),
	FieldHover = Color3.fromRGB(46, 51, 64),
	Stroke = Color3.fromRGB(56, 62, 78),
	Text = Color3.fromRGB(232, 235, 242),
	SubText = Color3.fromRGB(150, 158, 176),
	Accent = Color3.fromRGB(80, 160, 255),
	AccentHover = Color3.fromRGB(120, 185, 255),
	Danger = Color3.fromRGB(226, 72, 84),
	Good = Color3.fromRGB(90, 200, 120),
	Font = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Medium),
	FontBold = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold),
	TextSize = 13,
	Corner = UDim.new(0, 6),
	Width = 340,
	Tween = TweenInfo.new(0.14, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
})

local CONST = table.freeze({
	PART_THICKNESS = 0.001,
	PART_Y = 0.001, -- the game's own pixels sit at y = 0.001 (+ layer offset)
	BATCH = 50, -- parts per DrawEvent (the game's own batch size)
	STROKE_PARTS = 2000, -- new stroke id after this many parts (a server rejection only costs one stroke)
	MAX_SPEED = 5000,
	LIMIT_SETTLE = 1.5, -- seconds to wait after a server rejection before counting what survived
	LAND_TIMEOUT = 6, -- max seconds to wait for a stroke's parts to replicate before starting the next
	LAND_EXTRA_FRAMES = 3, -- frames to wait after the last part shows up (server finalise margin)
	MIN_PIXEL = 0.02,
	MAX_PIXEL = 5,
	MIN_WIDTH = 1,
	MAX_WIDTH = 600,
	MAX_SIDE_PX = 1024, -- never fetch more than this many pixels on a side
	KMEANS_ITERS = 7,
	YIELD_BUDGET = 0.006,
	TOGGLE_KEY = Enum.KeyCode.RightShift,
	FOLDER = "freedraw_autodraw",
	FITS = { "contain", "cover", "fill" },
	FIT_LABEL = { contain = "Shape: keep original", cover = "Shape: crop to square", fill = "Shape: stretch to square" },
	DEFAULT_PART_LIMIT = 200000,
	GHOST_COLOR = Color3.fromRGB(80, 160, 255),
})

local Settings = {
	Url = "",
	Width = 40, -- studs across
	Pixel = 0.1, -- studs per image pixel (the game's smallest brush is 0.05)
	Colors = 64,
	Fit = "contain",
	Dither = false, -- Floyd-Steinberg; smoother photos but far more parts
	Distance = 6, -- studs in front of you to the TOP edge of the picture
	Speed = 1000, -- parts per second. The server blocks the whole session (even hand drawing) after heavy bursts.
}

----------------------------------------------------------------------------------------------------
-- Maid
----------------------------------------------------------------------------------------------------
type Maid = { tasks: { any }, Give: (Maid, any) -> any, Cleanup: (Maid) -> () }

local Maid = {}
Maid.__index = Maid

function Maid.new(): Maid
	return (setmetatable({ tasks = {} }, Maid) :: any) :: Maid
end

function Maid:Give(item: any): any
	table.insert(self.tasks, item)
	return item
end

function Maid:Cleanup()
	local tasks = self.tasks
	self.tasks = {}
	for i = #tasks, 1, -1 do
		local item = tasks[i]
		local kind = typeof(item)
		if kind == "RBXScriptConnection" then
			item:Disconnect()
		elseif kind == "thread" then
			pcall(task.cancel, item)
		elseif kind == "function" then
			pcall(item)
		elseif kind == "Instance" then
			pcall(item.Destroy, item)
		elseif kind == "Tween" then
			item:Cancel()
		end
	end
end

local maid = Maid.new()
local state = {
	running = true,
	busy = false,
	stopRequested = false,
	job = nil :: thread?,
	plan = nil :: any,
	planKey = "",
	source = nil :: any,
	sourceKey = "",
	previewImage = nil :: EditableImage?,
	resume = nil :: any, -- { plan, index, strokes = { {id, count} }, strokeId, strokeCount }
	history = {} :: { { { id: string, count: number } } }, -- finished/stopped drawings, for Undo
	ownStrokes = {} :: { [string]: boolean }, -- stroke folder names we created (for the unhide hook)
	tempFiles = {} :: { string },
	fileCounter = 0,
	ghost = nil :: Part?,
	limitHit = false, -- set by StrokeLimitEvent while a draw job runs
	localParts = nil :: Folder?, -- fallback visuals when getconnections is unavailable
}

----------------------------------------------------------------------------------------------------
-- Utilities
----------------------------------------------------------------------------------------------------
local function create(className: string, props: { [string]: any }, children: { Instance }?): any
	local inst = Instance.new(className)
	local parent = props.Parent
	for key, value in props do
		if key ~= "Parent" then
			(inst :: any)[key] = value
		end
	end
	if children then
		for _, child in children do
			child.Parent = inst
		end
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

local yieldClock = os.clock()
local function yieldMaybe()
	if os.clock() - yieldClock > CONST.YIELD_BUDGET then
		task.wait()
		yieldClock = os.clock()
	end
	if state.stopRequested or not state.running then
		error("__STOPPED__", 0)
	end
end

local function partLimit(): number
	local cfg = Game.Config
	return if cfg and type(cfg.partLimit) == "number" then cfg.partLimit else CONST.DEFAULT_PART_LIMIT
end

local function livePartCount(): number
	local cfg = Game.Config
	return if cfg and type(cfg.LivePartCount) == "number" then cfg.LivePartCount else 0
end

local function activeLayer(): (number, number)
	local layers = Game.Layers
	if not layers then
		return 1, 0
	end
	local okL, layer = pcall(layers.getActiveLayer)
	local okZ, z = pcall(layers.getZOffsetForLayer)
	return if okL and type(layer) == "number" then layer else 1, if okZ and type(z) == "number" then z else 0
end

local function newStrokeId(): string
	return `{LocalPlayer.UserId}_PIXEL_{os.time()}_{math.random(1000000)}`
end

local partCounter = 0
local function newPartName(): string
	partCounter += 1
	return `Part_{LocalPlayer.UserId}_{tick()}_{partCounter}`
end

----------------------------------------------------------------------------------------------------
-- Placement: the picture lies flat on the floor in front of you, axis-aligned so every part is a
-- plain unrotated block. "Right" and "down" follow your camera, snapped to the nearest world axis.
----------------------------------------------------------------------------------------------------
type Placement = { origin: Vector3, right: Vector3, down: Vector3, y: number }

local function snapAxis(v: Vector3): Vector3
	if math.abs(v.X) >= math.abs(v.Z) then
		return if v.X >= 0 then Vector3.xAxis else -Vector3.xAxis
	end
	return if v.Z >= 0 then Vector3.zAxis else -Vector3.zAxis
end

local function placement(widthStuds: number, heightStuds: number): Placement
	local camera = workspace.CurrentCamera
	local look = camera.CFrame.LookVector
	local forward = Vector3.new(look.X, 0, look.Z)
	if forward.Magnitude < 0.05 then
		forward = -Vector3.zAxis
	end
	forward = snapAxis(forward)
	local right = snapAxis(forward:Cross(Vector3.yAxis))
	local down = -forward -- top of the picture is the far side (what you see as "up" on screen)
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local base = if root then root.Position else camera.CFrame.Position
	-- top-left corner: `Distance` studs ahead, centred left-right
	local centreAhead = Vector3.new(base.X, 0, base.Z) + forward * (Settings.Distance + heightStuds)
	local origin = centreAhead - right * (widthStuds * 0.5)
	local _, z = activeLayer()
	return { origin = origin, right = right, down = down, y = CONST.PART_Y + z }
end

----------------------------------------------------------------------------------------------------
-- Image loading
----------------------------------------------------------------------------------------------------
local function httpGet(url: string): string
	local ok, res = pcall(Exec.request, { Url = url, Method = "GET" })
	if not ok then
		error("request failed: " .. tostring(res), 0)
	end
	if type(res) ~= "table" or res.StatusCode ~= 200 or type(res.Body) ~= "string" or #res.Body == 0 then
		error("HTTP " .. tostring(res and res.StatusCode), 0)
	end
	return res.Body
end

local function decodeImage(bytes: string, ext: string): EditableImage
	if Exec.makefolder then
		pcall(Exec.makefolder, CONST.FOLDER)
	end
	state.fileCounter += 1
	local path = `{CONST.FOLDER}/img_{os.time()}_{state.fileCounter}.{ext}`
	Exec.writefile(path, bytes)
	table.insert(state.tempFiles, path)
	local asset = Exec.getcustomasset(path)
	local ok, image = pcall(function()
		return AssetService:CreateEditableImageAsync(Content.fromUri(asset))
	end)
	if not ok or image == nil then
		error("could not decode image (" .. tostring(image) .. ")", 0)
	end
	return image :: EditableImage
end

local function sniffExt(bytes: string): string
	if bytes:sub(2, 4) == "PNG" then
		return "png"
	elseif bytes:sub(1, 2) == "\255\216" then
		return "jpg"
	end
	return "png"
end

-- Returns sRGB float arrays (alpha composited onto white) at exactly w x h.
local function fetchSource(url: string, w: number, h: number, fit: string, setStatus: (string) -> ())
	local proxied = "https://images.weserv.nl/?url="
		.. HttpService:UrlEncode(url)
		.. `&w={w}&h={h}&fit={fit}&cbg=ffffff&output=png`

	local image: EditableImage
	local ok, result = pcall(function()
		return decodeImage(httpGet(proxied), "png")
	end)
	if ok then
		image = result
	else
		setStatus("Proxy failed, trying direct link…")
		local directOk, direct = pcall(function()
			local bytes = httpGet(url)
			return decodeImage(bytes, sniffExt(bytes))
		end)
		if not directOk then
			error(`image download failed (proxy: {result}; direct: {direct}). Use a direct link to the image file.`, 0)
		end
		image = direct
	end

	local size = image.Size
	local sw, sh = size.X, size.Y
	local buf = image:ReadPixelsBuffer(Vector2.zero, size)
	image:Destroy()

	-- weserv "contain" keeps the aspect ratio, so the real size can differ from w x h: use the actual one.
	if fit == "contain" then
		w, h = sw, sh
	end
	local count = w * h
	local r, g, b = table.create(count, 0), table.create(count, 0), table.create(count, 0)
	for y = 0, h - 1 do
		local sy0 = math.floor(y * sh / h)
		local sy1 = math.max(sy0 + 1, math.floor((y + 1) * sh / h))
		for x = 0, w - 1 do
			local sx0 = math.floor(x * sw / w)
			local sx1 = math.max(sx0 + 1, math.floor((x + 1) * sw / w))
			local sr, sg, sb, n = 0, 0, 0, 0
			for sy = sy0, sy1 - 1 do
				local row = sy * sw
				for sx = sx0, sx1 - 1 do
					local o = (row + sx) * 4
					local a = buffer.readu8(buf, o + 3) / 255
					local inv = (1 - a) * 255
					sr += buffer.readu8(buf, o) * a + inv
					sg += buffer.readu8(buf, o + 1) * a + inv
					sb += buffer.readu8(buf, o + 2) * a + inv
					n += 1
				end
			end
			local i = y * w + x + 1
			r[i], g[i], b[i] = sr / n, sg / n, sb / n
		end
		yieldMaybe()
	end
	return { w = w, h = h, r = r, g = g, b = b }
end

----------------------------------------------------------------------------------------------------
-- Colour quantisation in Oklab (median cut seeds + k-means), optional Floyd-Steinberg dither
----------------------------------------------------------------------------------------------------
local function srgbToLinear(c: number): number
	c /= 255
	return if c <= 0.04045 then c / 12.92 else ((c + 0.055) / 1.055) ^ 2.4
end

local function toOklab(img: any)
	local n = img.w * img.h
	local L, A, B = table.create(n, 0), table.create(n, 0), table.create(n, 0)
	local lut = table.create(256)
	for v = 0, 255 do
		lut[v + 1] = srgbToLinear(v)
	end
	for i = 1, n do
		local r = lut[math.clamp(math.floor(img.r[i] + 0.5), 0, 255) + 1]
		local g = lut[math.clamp(math.floor(img.g[i] + 0.5), 0, 255) + 1]
		local b = lut[math.clamp(math.floor(img.b[i] + 0.5), 0, 255) + 1]
		local l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b) ^ (1 / 3)
		local m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b) ^ (1 / 3)
		local s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b) ^ (1 / 3)
		L[i] = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
		A[i] = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
		B[i] = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
		if i % 4096 == 0 then
			yieldMaybe()
		end
	end
	return L, A, B
end

local function quantize(img: any, k: number)
	local n = img.w * img.h
	local R, G, B = toOklab(img)

	local all = table.create(n)
	for i = 1, n do
		all[i] = i
	end
	local boxes = { all }
	while #boxes < k do
		local bestBox, bestRange, bestChannel = 0, -1, R
		for bi, box in boxes do
			if #box > 1 then
				local minR, maxR, minG, maxG, minB, maxB = math.huge, -math.huge, math.huge, -math.huge, math.huge, -math.huge
				for _, i in box do
					local cr, cg, cb = R[i], G[i], B[i]
					if cr < minR then minR = cr end
					if cr > maxR then maxR = cr end
					if cg < minG then minG = cg end
					if cg > maxG then maxG = cg end
					if cb < minB then minB = cb end
					if cb > maxB then maxB = cb end
				end
				local range, channel = maxR - minR, R
				if maxG - minG > range then range, channel = maxG - minG, G end
				if maxB - minB > range then range, channel = maxB - minB, B end
				if range > bestRange then
					bestBox, bestRange, bestChannel = bi, range, channel
				end
			end
			yieldMaybe()
		end
		if bestBox == 0 or bestRange <= 0 then
			break
		end
		local box = boxes[bestBox]
		local channel = bestChannel
		table.sort(box, function(a, b)
			return channel[a] < channel[b]
		end)
		local mid = #box // 2
		boxes[bestBox] = table.move(box, 1, mid, 1, table.create(mid))
		table.insert(boxes, table.move(box, mid + 1, #box, 1, table.create(#box - mid)))
	end

	local pr, pg, pb = {}, {}, {}
	for ci, box in boxes do
		local sr, sg, sb = 0, 0, 0
		for _, i in box do
			sr += R[i]
			sg += G[i]
			sb += B[i]
		end
		pr[ci], pg[ci], pb[ci] = sr / #box, sg / #box, sb / #box
	end
	local kk = #boxes

	local assign = table.create(n, 1)
	for iter = 1, CONST.KMEANS_ITERS + 1 do
		for i = 1, n do
			local cr, cg, cb = R[i], G[i], B[i]
			local best, bestD = 1, math.huge
			for c = 1, kk do
				local dr, dg, db = cr - pr[c], cg - pg[c], cb - pb[c]
				local d = dr * dr + dg * dg + db * db
				if d < bestD then
					best, bestD = c, d
				end
			end
			assign[i] = best
			if i % 2048 == 0 then
				yieldMaybe()
			end
		end
		if iter > CONST.KMEANS_ITERS then
			break
		end
		local sr, sg, sb, cnt = table.create(kk, 0), table.create(kk, 0), table.create(kk, 0), table.create(kk, 0)
		for i = 1, n do
			local c = assign[i]
			sr[c] += R[i]
			sg[c] += G[i]
			sb[c] += B[i]
			cnt[c] += 1
		end
		for c = 1, kk do
			if cnt[c] > 0 then
				pr[c], pg[c], pb[c] = sr[c] / cnt[c], sg[c] / cnt[c], sb[c] / cnt[c]
			end
		end
	end

	-- Compact empty clusters; palette colour = mean sRGB of the members (exact integers).
	local remap, sumR, sumG, sumB, counts = {}, {}, {}, {}, {}
	local kept = 0
	for i = 1, n do
		local c = assign[i]
		local nc = remap[c]
		if not nc then
			kept += 1
			nc = kept
			remap[c] = nc
			sumR[nc], sumG[nc], sumB[nc], counts[nc] = 0, 0, 0, 0
		end
		assign[i] = nc
		sumR[nc] += img.r[i]
		sumG[nc] += img.g[i]
		sumB[nc] += img.b[i]
		counts[nc] += 1
	end
	local palette = table.create(kept)
	for c = 1, kept do
		local cnt = counts[c]
		palette[c] = Color3.fromRGB(math.floor(sumR[c] / cnt + 0.5), math.floor(sumG[c] / cnt + 0.5), math.floor(sumB[c] / cnt + 0.5))
	end
	return assign, palette
end

-- Serpentine Floyd-Steinberg (damped) against the k-means palette, in sRGB with redmean distance.
local function dither(img: any, palette: { Color3 }): { number }
	local w, h = img.w, img.h
	local n = w * h
	local pr, pg, pb = table.create(#palette), table.create(#palette), table.create(#palette)
	for c, col in palette do
		pr[c], pg[c], pb[c] = col.R * 255, col.G * 255, col.B * 255
	end
	local r, g, b = table.clone(img.r), table.clone(img.g), table.clone(img.b)
	local grid = table.create(n, 1)
	local damp = 0.75
	for y = 0, h - 1 do
		local leftToRight = y % 2 == 0
		for step = 0, w - 1 do
			local x = if leftToRight then step else w - 1 - step
			local i = y * w + x + 1
			local cr, cg, cb = math.clamp(r[i], 0, 255), math.clamp(g[i], 0, 255), math.clamp(b[i], 0, 255)
			local best, bestD = 1, math.huge
			for c = 1, #palette do
				local dr, dg, db = cr - pr[c], cg - pg[c], cb - pb[c]
				local rm = (cr + pr[c]) * 0.5
				local d = (2 + rm / 256) * dr * dr + 4 * dg * dg + (2 + (255 - rm) / 256) * db * db
				if d < bestD then
					best, bestD = c, d
				end
			end
			grid[i] = best
			local er, eg, eb = (cr - pr[best]) * damp, (cg - pg[best]) * damp, (cb - pb[best]) * damp
			local dx = if leftToRight then 1 else -1
			local nx = x + dx
			if nx >= 0 and nx < w then
				local j = i + dx
				r[j] += er * 7 / 16
				g[j] += eg * 7 / 16
				b[j] += eb * 7 / 16
			end
			if y + 1 < h then
				local j = i + w
				r[j] += er * 5 / 16
				g[j] += eg * 5 / 16
				b[j] += eb * 5 / 16
				if x - dx >= 0 and x - dx < w then
					r[j - dx] += er * 3 / 16
					g[j - dx] += eg * 3 / 16
					b[j - dx] += eb * 3 / 16
				end
				if nx >= 0 and nx < w then
					r[j + dx] += er * 1 / 16
					g[j + dx] += eg * 1 / 16
					b[j + dx] += eb * 1 / 16
				end
			end
		end
		yieldMaybe()
	end
	return grid
end

----------------------------------------------------------------------------------------------------
-- Rectangle merger: every horizontal run of one colour is a part; runs on consecutive rows with the
-- same span and colour are merged into one taller part. Rect = { colour, x0, x1, y0, y1 } (inclusive).
----------------------------------------------------------------------------------------------------
local function buildRects(grid: { number }, w: number, h: number, skip: { [number]: boolean }): { { number } }
	local rects = {}
	local open: { [number]: { number } } = {} -- keyed by x0 of runs on the previous row
	for y = 0, h - 1 do
		local next: { [number]: { number } } = {}
		local x = 0
		local row = y * w
		while x < w do
			local c = grid[row + x + 1]
			if skip[c] then
				x += 1
				continue
			end
			local x0 = x
			while x + 1 < w and grid[row + x + 2] == c do
				x += 1
			end
			local above = open[x0]
			if above and above[1] == c and above[3] == x and above[5] == y - 1 then
				above[5] = y -- extend downwards
				next[x0] = above
			else
				local rect = { c, x0, x, y, y }
				table.insert(rects, rect)
				next[x0] = rect
			end
			x += 1
		end
		open = next
		yieldMaybe()
	end
	return rects
end

local function buildPlan(src: any)
	local w, h = src.w, src.h
	local grid, palette = quantize(src, Settings.Colors)
	if Settings.Dither then
		grid = dither(src, palette)
	end
	-- Pure white is the floor colour; leaving it out saves parts and shows the canvas instead.
	local skip: { [number]: boolean } = {}
	for c, col in palette do
		if col.R >= 0.97 and col.G >= 0.97 and col.B >= 0.97 then
			skip[c] = true
		end
	end
	local rects = buildRects(grid, w, h, skip)
	-- One stroke per colour (see header): keep rects grouped by colour, rows in order inside each group.
	table.sort(rects, function(a, b)
		if a[1] ~= b[1] then
			return a[1] < b[1]
		end
		if a[4] ~= b[4] then
			return a[4] < b[4]
		end
		return a[2] < b[2]
	end)
	return {
		w = w,
		h = h,
		grid = grid,
		palette = palette,
		rects = rects,
		partCount = #rects,
		pixel = Settings.Pixel,
		widthStuds = w * Settings.Pixel,
		heightStuds = h * Settings.Pixel,
	}
end

----------------------------------------------------------------------------------------------------
-- UI
----------------------------------------------------------------------------------------------------
local hostOk, host = pcall(function()
	return if Exec.gethui then Exec.gethui() else CoreGui
end)
if not hostOk or not host then
	host = LocalPlayer:WaitForChild("PlayerGui")
end

local ui: any = {}
ui.Screen = maid:Give(create("ScreenGui", {
	Name = "FreeDraw_AutoDraw",
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	DisplayOrder = 50,
	IgnoreGuiInset = true,
	Parent = host,
}))

ui.Window = create("Frame", {
	Name = "Window",
	AnchorPoint = Vector2.new(0, 0.5),
	Position = UDim2.new(0, 24, 0.5, 0),
	Size = UDim2.fromOffset(Theme.Width, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundColor3 = Theme.Bg,
	BorderSizePixel = 0,
	Active = true,
}, {
	create("UICorner", { CornerRadius = UDim.new(0, 10) }),
	create("UIStroke", { Color = Theme.Stroke, Thickness = 1 }),
})

local titleBar = create("Frame", {
	Name = "TitleBar",
	Size = UDim2.new(1, 0, 0, 34),
	BackgroundTransparency = 1,
	Active = true,
	Parent = ui.Window,
}, {
	create("TextLabel", {
		Size = UDim2.new(1, -24, 1, 0),
		Position = UDim2.fromOffset(12, 0),
		BackgroundTransparency = 1,
		Text = "Image Auto-Draw",
		TextColor3 = Theme.Text,
		FontFace = Theme.FontBold,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
	}),
	create("TextLabel", {
		Size = UDim2.new(1, -24, 1, 0),
		Position = UDim2.fromOffset(12, 0),
		BackgroundTransparency = 1,
		Text = "RShift shows / hides",
		TextColor3 = Theme.SubText,
		FontFace = Theme.Font,
		TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Right,
	}),
})

local body = create("Frame", {
	Name = "Body",
	Position = UDim2.fromOffset(0, 34),
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1,
	Parent = ui.Window,
}, {
	create("UIPadding", {
		PaddingLeft = UDim.new(0, 12),
		PaddingRight = UDim.new(0, 12),
		PaddingBottom = UDim.new(0, 12),
	}),
	create("UIListLayout", {
		Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}),
})

local layoutOrder = 0
local function nextOrder(): number
	layoutOrder += 1
	return layoutOrder
end

local function hoverTween(button: GuiObject, base: Color3, hover: Color3)
	local active: Tween? = nil
	local function to(color: Color3)
		if active then
			active:Cancel()
		end
		active = TweenService:Create(button, Theme.Tween, { BackgroundColor3 = color })
		active:Play()
	end
	maid:Give(button.MouseEnter:Connect(function()
		to(hover)
	end))
	maid:Give(button.MouseLeave:Connect(function()
		to(base)
	end))
	maid:Give(function()
		if active then
			active:Cancel()
		end
	end)
end

local function Button(text: string, color: Color3, hover: Color3, parent: Instance, size: UDim2?): TextButton
	local button = create("TextButton", {
		Size = size or UDim2.new(1, 0, 0, 30),
		BackgroundColor3 = color,
		AutoButtonColor = false,
		BorderSizePixel = 0,
		Text = text,
		TextColor3 = Theme.Text,
		FontFace = Theme.FontBold,
		TextSize = Theme.TextSize,
		LayoutOrder = nextOrder(),
		Parent = parent,
	}, {
		create("UICorner", { CornerRadius = Theme.Corner }),
	})
	hoverTween(button, color, hover)
	return button
end

local function TextField(label: string, value: string, placeholder: string, onCommit: (string) -> string, parent: Instance, width: UDim?)
	local holder = create("Frame", {
		Size = UDim2.new(width or UDim.new(1, 0), UDim.new(0, 44)),
		BackgroundTransparency = 1,
		LayoutOrder = nextOrder(),
		Parent = parent,
	}, {
		create("TextLabel", {
			Size = UDim2.new(1, 0, 0, 14),
			BackgroundTransparency = 1,
			Text = label,
			TextColor3 = Theme.SubText,
			FontFace = Theme.Font,
			TextSize = 11,
			TextXAlignment = Enum.TextXAlignment.Left,
		}),
	})
	local box = create("TextBox", {
		Position = UDim2.fromOffset(0, 16),
		Size = UDim2.new(1, 0, 0, 28),
		BackgroundColor3 = Theme.Field,
		BorderSizePixel = 0,
		ClearTextOnFocus = false,
		Text = value,
		PlaceholderText = placeholder,
		PlaceholderColor3 = Theme.SubText,
		TextColor3 = Theme.Text,
		FontFace = Theme.Font,
		TextSize = Theme.TextSize,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = holder,
	}, {
		create("UICorner", { CornerRadius = Theme.Corner }),
		create("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }),
	})
	maid:Give(box.FocusLost:Connect(function()
		box.Text = onCommit(box.Text)
	end))
	return box
end

local function numberCommit(key: string, lo: number, hi: number, integer: boolean): (string) -> string
	return function(text: string): string
		local n = tonumber(text)
		if n then
			Settings[key] = math.clamp(if integer then math.floor(n + 0.5) else n, lo, hi)
		end
		return tostring(Settings[key])
	end
end

-- Section header + one-line explanation, so each step reads top to bottom.
local function Section(step: string, title: string, hint: string)
	local holder = create("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = nextOrder(),
		Parent = body,
	}, {
		create("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }),
		create("TextLabel", {
			Size = UDim2.new(1, 0, 0, 18),
			BackgroundTransparency = 1,
			Text = `{step}  {title}`,
			TextColor3 = Theme.Accent,
			FontFace = Theme.FontBold,
			TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Left,
			LayoutOrder = 1,
		}),
		create("TextLabel", {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			Text = hint,
			TextColor3 = Theme.SubText,
			FontFace = Theme.Font,
			TextSize = 11,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			LayoutOrder = 2,
		}),
	})
	return holder
end

local function Row(height: number): Frame
	return create("Frame", {
		Size = UDim2.new(1, 0, 0, height),
		BackgroundTransparency = 1,
		LayoutOrder = nextOrder(),
		Parent = body,
	}, {
		create("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
end

-- Step 1: the picture
Section("1", "Pick a picture", "Paste a direct link to an image (png, jpg, webp or gif). Discord and most image hosts work.")
ui.Url = TextField("Image link", "", "https://…", function(text)
	Settings.Url = (text:gsub("^%s+", ""):gsub("%s+$", ""))
	return Settings.Url
end, body)

-- Step 2: size and look
Section("2", "Size and detail", "Width is how wide it is on the floor. Pixel is the size of one dot: smaller = sharper but more parts. Fewer colours = fewer parts.")
local row1 = Row(44)
local third = UDim.new(1 / 3, -6)
TextField("Width (studs)", tostring(Settings.Width), "40", numberCommit("Width", CONST.MIN_WIDTH, CONST.MAX_WIDTH, false), row1, third)
TextField("Pixel size (studs)", tostring(Settings.Pixel), "0.1", numberCommit("Pixel", CONST.MIN_PIXEL, CONST.MAX_PIXEL, false), row1, third)
TextField("Colours", tostring(Settings.Colors), "64", numberCommit("Colors", 2, 256, true), row1, third)
local toggles = Row(28)
ui.Fit = Button(CONST.FIT_LABEL[Settings.Fit], Theme.Field, Theme.FieldHover, toggles, UDim2.new(0.5, -4, 1, 0))
ui.Dither = Button("Smooth shading: Off", Theme.Field, Theme.FieldHover, toggles, UDim2.new(0.5, -4, 1, 0))

-- Step 3: where
Section("3", "Where it goes", "It lands on the floor in front of where you are looking. Press Preview to see a blue outline there.")
local row2 = Row(44)
TextField("Distance ahead (studs)", tostring(Settings.Distance), "6", numberCommit("Distance", 0, 200, false), row2, UDim.new(0.5, -4))
TextField("Speed (parts per second)", tostring(Settings.Speed), "1000", numberCommit("Speed", 50, CONST.MAX_SPEED, true), row2, UDim.new(0.5, -4))

-- Step 4: go
Section("4", "Preview, then Draw", "Preview downloads the picture and shows it below with the part count. Draw sends it. Stop pauses; Draw again continues.")
local actions = Row(34)
ui.PreviewBtn = Button("Preview", Theme.Field, Theme.FieldHover, actions, UDim2.new(1 / 3, -6, 1, 0))
ui.DrawBtn = Button("Draw", Theme.Accent, Theme.AccentHover, actions, UDim2.new(1 / 3, -6, 1, 0))
ui.StopBtn = Button("Stop", Theme.Danger, Theme.Danger:Lerp(Color3.new(1, 1, 1), 0.15), actions, UDim2.new(1 / 3, -4, 1, 0))

ui.Preview = create("ImageLabel", {
	Size = UDim2.new(1, 0, 0, 0),
	BackgroundColor3 = Color3.new(1, 1, 1),
	BorderSizePixel = 0,
	ScaleType = Enum.ScaleType.Fit,
	ResampleMode = Enum.ResamplerMode.Pixelated,
	LayoutOrder = nextOrder(),
	Parent = body,
}, {
	create("UICorner", { CornerRadius = Theme.Corner }),
})
ui.PreviewAspect = create("UIAspectRatioConstraint", { AspectRatio = 1, Parent = ui.Preview })
create("UISizeConstraint", { MaxSize = Vector2.new(math.huge, 200), Parent = ui.Preview })

-- Status box: what is happening right now
local statusBox = create("Frame", {
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundColor3 = Theme.Panel,
	BorderSizePixel = 0,
	LayoutOrder = nextOrder(),
	Parent = body,
}, {
	create("UICorner", { CornerRadius = Theme.Corner }),
	create("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8) }),
	create("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
})
ui.Status = create("TextLabel", {
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1,
	Text = "Waiting. Paste a link above and press Preview.",
	TextColor3 = Theme.SubText,
	FontFace = Theme.Font,
	TextSize = 12,
	TextWrapped = true,
	TextXAlignment = Enum.TextXAlignment.Left,
	LayoutOrder = 1,
	Parent = statusBox,
})
local progressTrack = create("Frame", {
	Size = UDim2.new(1, 0, 0, 6),
	BackgroundColor3 = Theme.Field,
	BorderSizePixel = 0,
	LayoutOrder = 2,
	Parent = statusBox,
}, {
	create("UICorner", { CornerRadius = UDim.new(1, 0) }),
})
ui.ProgressFill = create("Frame", {
	Size = UDim2.fromScale(0, 1),
	BackgroundColor3 = Theme.Accent,
	BorderSizePixel = 0,
	Parent = progressTrack,
}, {
	create("UICorner", { CornerRadius = UDim.new(1, 0) }),
})

-- Extras
Section("", "If something goes wrong", "Undo removes the last drawing. If the game refuses your strokes, Rejoin reconnects you and reopens this window.")
local actions2 = Row(30)
ui.UndoBtn = Button("Undo last drawing", Theme.Panel, Theme.Field, actions2, UDim2.new(1 / 3, -6, 1, 0))
ui.RejoinBtn = Button("Rejoin game", Theme.Panel, Theme.Field, actions2, UDim2.new(1 / 3, -6, 1, 0))
ui.Unload = Button("Close script", Theme.Panel, Theme.Field, actions2, UDim2.new(1 / 3, -4, 1, 0))

ui.Window.Parent = ui.Screen

----------------------------------------------------------------------------------------------------
-- UI state bridge: job threads call game closures (layer module), which on some executors drops the
-- thread's capabilities until it yields. Jobs only write into `view`; Heartbeat applies it change-only.
----------------------------------------------------------------------------------------------------
local view = {
	status = ui.Status.Text,
	statusColor = Theme.SubText,
	progress = 0,
	previewPlan = nil :: any,
	dirty = true,
}
local lastStatus = view.status
local applied = { status = "", statusColor = Theme.SubText, progress = -1 }

local function setStatus(text: string, color: Color3?)
	local c = color or Theme.SubText
	if text ~= view.status or c ~= view.statusColor then
		view.status = text
		view.statusColor = c
		view.dirty = true
		lastStatus = text
	end
end

local function setProgress(alpha: number)
	local q = math.floor(math.clamp(alpha, 0, 1) * 200 + 0.5) / 200
	if q ~= view.progress then
		view.progress = q
		view.dirty = true
	end
end

local function renderPreview(plan: any)
	if state.previewImage then
		state.previewImage:Destroy()
		state.previewImage = nil
	end
	local ok, image = pcall(function()
		return AssetService:CreateEditableImage({ Size = Vector2.new(plan.w, plan.h) })
	end)
	if not ok or not image then
		return
	end
	ui.PreviewAspect.AspectRatio = plan.w / plan.h
	local buf = buffer.create(plan.w * plan.h * 4)
	local palette, grid = plan.palette, plan.grid
	for i = 1, plan.w * plan.h do
		local c = palette[grid[i]]
		local o = (i - 1) * 4
		buffer.writeu8(buf, o, math.floor(c.R * 255 + 0.5))
		buffer.writeu8(buf, o + 1, math.floor(c.G * 255 + 0.5))
		buffer.writeu8(buf, o + 2, math.floor(c.B * 255 + 0.5))
		buffer.writeu8(buf, o + 3, 255)
	end
	image:WritePixelsBuffer(Vector2.zero, image.Size, buf)
	state.previewImage = image
	pcall(function()
		ui.Preview.ImageContent = Content.fromObject(image)
	end)
end

-- Ghost: one translucent local part showing where the picture will land. Updated on Preview only.
local function showGhost(plan: any)
	local place = placement(plan.widthStuds, plan.heightStuds)
	local centre = place.origin + place.right * (plan.widthStuds * 0.5) + place.down * (plan.heightStuds * 0.5)
	local alongX = math.abs(place.right.X) > 0.5
	local size = if alongX then Vector3.new(plan.widthStuds, 0.05, plan.heightStuds) else Vector3.new(plan.heightStuds, 0.05, plan.widthStuds)
	local ghost = state.ghost
	if not ghost then
		ghost = maid:Give(create("Part", {
			Name = "FreeDrawGhost",
			Anchored = true,
			CanCollide = false,
			CanQuery = false,
			CanTouch = false,
			CastShadow = false,
			Material = Enum.Material.SmoothPlastic,
			Color = CONST.GHOST_COLOR,
			Transparency = 0.7,
		}))
		state.ghost = ghost
	end
	ghost.Size = size
	ghost.CFrame = CFrame.new(centre.X, place.y + 0.05, centre.Z)
	ghost.Parent = workspace
end

local function hideGhost()
	if state.ghost then
		state.ghost.Parent = nil
	end
end

maid:Give(RunService.Heartbeat:Connect(function()
	if not view.dirty then
		return
	end
	view.dirty = false
	if view.status ~= applied.status then
		applied.status = view.status
		ui.Status.Text = view.status
	end
	if view.statusColor ~= applied.statusColor then
		applied.statusColor = view.statusColor
		ui.Status.TextColor3 = view.statusColor
	end
	if view.progress ~= applied.progress then
		applied.progress = view.progress
		ui.ProgressFill.Size = UDim2.fromScale(view.progress, 1)
	end
	if view.previewPlan then
		local plan = view.previewPlan
		view.previewPlan = nil
		renderPreview(plan)
		showGhost(plan)
	end
end))

----------------------------------------------------------------------------------------------------
-- Showing our own parts. The game hides the local player's server parts (Transparency forced to 1
-- by a per-part connection) and relies on client-side copies it made while drawing. We made none,
-- so for our strokes we kill that connection and show the server part; without getconnections we
-- build cheap local copies instead.
----------------------------------------------------------------------------------------------------
local function unhide(part: BasePart)
	if Exec.getconnections then
		local okList, list = pcall(Exec.getconnections, part:GetPropertyChangedSignal("Transparency"))
		if okList and type(list) == "table" then
			for _, conn in list do
				pcall(function()
					conn:Disable()
				end)
			end
		end
	end
	part.Transparency = part:GetAttribute("Opacity") or 0
end

local function watchOwnFolder()
	local master = workspace:FindFirstChild("MasterDrawings")
	local folder = master and master:FindFirstChild("Player_" .. LocalPlayer.UserId)
	if not folder then
		return
	end
	maid:Give(folder.DescendantAdded:Connect(function(d: Instance)
		if not d:IsA("BasePart") then
			return
		end
		local parent = d.Parent
		if not parent or not state.ownStrokes[parent.Name] then
			return
		end
		-- the game's own DescendantAdded handler runs first (connected earlier); defer past it
		task.defer(unhide, d)
	end))
end
watchOwnFolder()

----------------------------------------------------------------------------------------------------
-- Drawing
----------------------------------------------------------------------------------------------------
local function startStroke(resume: any)
	local id = newStrokeId()
	resume.strokeId = id
	resume.strokeCount = 0
	resume.strokeStart = resume.index -- first rect index of this stroke (for recovery after a rejection)
	state.ownStrokes["Stroke_" .. id] = true
	table.insert(resume.strokes, { id = id, count = 0 })
	local camera = workspace.CurrentCamera
	local from = camera.CFrame.Position
	local target = resume.place.origin
	Game.StrokeStartEvent:FireServer(id, from, (target - from).Unit)
end

local function makePart(plan: any, place: Placement, rect: { number }): { [string]: any }
	local px = plan.pixel
	local x0, x1, y0, y1 = rect[2], rect[3], rect[4], rect[5]
	local wlen, hlen = (x1 - x0 + 1) * px, (y1 - y0 + 1) * px
	local centre = place.origin + place.right * ((x0 + x1 + 1) * 0.5 * px) + place.down * ((y0 + y1 + 1) * 0.5 * px)
	local alongX = math.abs(place.right.X) > 0.5
	return {
		CFrame = CFrame.new(centre.X, place.y, centre.Z),
		Size = if alongX then Vector3.new(wlen, CONST.PART_THICKNESS, hlen) else Vector3.new(hlen, CONST.PART_THICKNESS, wlen),
		Color = plan.palette[rect[1]],
		Shape = Enum.PartType.Block,
		Opacity = 0,
		PartName = newPartName(),
	}
end

local function landedParts(strokeId: string): number
	local master = workspace:FindFirstChild("MasterDrawings")
	local folder = master and master:FindFirstChild("Player_" .. LocalPlayer.UserId)
	local stroke = folder and folder:FindFirstChild("Stroke_" .. strokeId)
	if not stroke then
		return 0
	end
	local n = 0
	for _, child in stroke:GetChildren() do
		if child:IsA("BasePart") then
			n += 1
		end
	end
	return n
end

if Game.StrokeLimitEvent then
	maid:Give(Game.StrokeLimitEvent.OnClientEvent:Connect(function()
		state.limitHit = true
	end))
end

local function sendBatch(resume: any, batch: { any }, final: boolean)
	local n = #batch
	local layer = resume.layer
	Game.AddPartCountEvent:FireServer(n)
	if Game.AddPartCountBindable then
		pcall(Game.AddPartCountBindable.Fire, Game.AddPartCountBindable, n)
	end
	Game.DrawEvent:FireServer(resume.strokeId, batch, final, layer, 0, false, false, false, resume.zOffset, 1)
	resume.strokeCount += n
	resume.strokes[#resume.strokes].count = resume.strokeCount
end

-- Blocks until the current stroke's parts have all replicated back (or LAND_TIMEOUT passes).
local function waitForStroke(resume: any)
	if resume.strokeCount == 0 then
		return
	end
	local deadline = os.clock() + CONST.LAND_TIMEOUT
	while landedParts(resume.strokeId) < resume.strokeCount do
		RunService.Heartbeat:Wait()
		if state.stopRequested or not state.running or state.limitHit then
			return
		end
		if os.clock() > deadline then
			warn(`[FreeDraw] stroke {resume.strokeId}: {landedParts(resume.strokeId)}/{resume.strokeCount} parts replicated after {CONST.LAND_TIMEOUT}s`)
			break
		end
	end
	for _ = 1, CONST.LAND_EXTRA_FRAMES do
		RunService.Heartbeat:Wait()
	end
end

local function drawPlan(plan: any): number
	local resume = state.resume
	if resume and resume.plan == plan then
		setStatus("Resuming…")
	else
		local layer, z = activeLayer()
		resume = {
			plan = plan,
			index = 1,
			strokes = {},
			strokeId = "",
			strokeCount = 0,
			strokeColour = nil,
			place = placement(plan.widthStuds, plan.heightStuds),
			layer = layer,
			zOffset = z,
		}
		state.resume = resume
		startStroke(resume)
	end
	hideGhost()

	local rects = plan.rects
	local total = #rects
	local limit = partLimit()
	if livePartCount() + (total - resume.index + 1) > limit then
		error(`not enough part budget: {total - resume.index + 1} needed, {limit - livePartCount()} left (Undo or clear first)`, 0)
	end

	local shown = -1
	local acc = 0 -- part budget accumulated from Settings.Speed
	state.limitHit = false
	while resume.index <= total do
		local dt = RunService.Heartbeat:Wait()
		if state.stopRequested or not state.running then
			startStroke(resume) -- resume continues in a fresh stroke; never send an empty "final" batch
			error("__STOPPED__", 0)
		end
		if state.limitHit then
			-- The server rejected a stroke (it also tells the client to undo it). Find out what survived,
			-- rewind to the first missing rect and stop: continuing only digs the session deeper.
			state.limitHit = false
			setStatus("Server rejected a stroke, checking what survived…", Theme.Danger)
			task.wait(CONST.LIMIT_SETTLE)
			local kept = landedParts(resume.strokeId)
			resume.strokes[#resume.strokes].count = kept
			resume.index = resume.strokeStart + kept
			startStroke(resume)
			error("__LIMIT__", 0)
		end
		acc = math.min(acc + Settings.Speed * dt, CONST.BATCH * 4) -- a lag spike never turns into a burst
		while acc >= CONST.BATCH and resume.index <= total do
			local colour = rects[resume.index][1]
			if resume.strokeCount >= CONST.STROKE_PARTS or (resume.strokeCount > 0 and colour ~= resume.strokeColour) then
				waitForStroke(resume) -- the server rejects a new stroke while the old one is still finalising
				if state.stopRequested or not state.running or state.limitHit then
					break
				end
				startStroke(resume)
				acc = 0
			end
			resume.strokeColour = colour
			-- a batch never crosses a colour boundary: the server fixes a stroke's palette from its first batch
			local count = math.min(CONST.BATCH, total - resume.index + 1, CONST.STROKE_PARTS - resume.strokeCount)
			local last = resume.index + count - 1
			while last > resume.index and rects[last][1] ~= colour do
				last -= 1
			end
			count = last - resume.index + 1
			local batch = table.create(count)
			for i = 1, count do
				batch[i] = makePart(plan, resume.place, rects[resume.index + i - 1])
			end
			-- final = this batch ends the stroke (last rect, colour change next, or stroke size cap)
			local final = last == total or rects[last + 1][1] ~= colour or resume.strokeCount + count >= CONST.STROKE_PARTS
			resume.index += count
			sendBatch(resume, batch, final)
			acc -= count
		end
		if resume.index - 1 ~= shown then
			shown = resume.index - 1
			setProgress(shown / total)
			setStatus(`Drawing {shown}/{total} parts… ({math.ceil((total - shown) / Settings.Speed)}s left)`)
		end
	end
	task.wait(CONST.LIMIT_SETTLE) -- a rejection of the final stroke can arrive after the last batch
	if state.limitHit then
		state.limitHit = false
		local kept = landedParts(resume.strokeId)
		resume.strokes[#resume.strokes].count = kept
		resume.index = resume.strokeStart + kept
		startStroke(resume)
		error("__LIMIT__", 0)
	end
	table.insert(state.history, resume.strokes)
	state.resume = nil
	return total
end

----------------------------------------------------------------------------------------------------
-- Jobs
----------------------------------------------------------------------------------------------------
local function sourceDims(): (number, number)
	local w = math.clamp(math.floor(Settings.Width / Settings.Pixel + 0.5), 1, CONST.MAX_SIDE_PX)
	return w, w -- weserv keeps aspect for contain; cover/fill produce a square of this size
end

local function sourceKey(): string
	local w, h = sourceDims()
	return `{Settings.Url}|{Settings.Fit}|{w}x{h}`
end

local function planKey(): string
	return `{sourceKey()}|{Settings.Colors}|{Settings.Dither}|{Settings.Pixel}`
end

local function ensurePlan(): any
	if Settings.Url == "" then
		error("paste an image URL first", 0)
	end
	if state.plan and state.planKey == planKey() then
		return state.plan
	end
	local key = sourceKey()
	if not state.source or state.sourceKey ~= key then
		setStatus("Downloading image…")
		local w, h = sourceDims()
		state.source = fetchSource(Settings.Url, w, h, Settings.Fit, setStatus)
		state.sourceKey = key
	end
	setStatus(`Planning {state.source.w}×{state.source.h} px, {Settings.Colors} colours…`)
	local plan = buildPlan(state.source)
	state.plan = plan
	state.planKey = planKey()
	state.resume = nil
	view.previewPlan = plan
	view.dirty = true
	return plan
end

local function describePlan(plan: any): string
	local left = partLimit() - livePartCount()
	local warning = if plan.partCount > left then ` ⚠ only {left} parts left in your budget` else ""
	return `{plan.w}×{plan.h} px = {string.format("%.1f", plan.widthStuds)}×{string.format("%.1f", plan.heightStuds)} studs, `
		.. `{#plan.palette} colours, {plan.partCount} parts (~{math.ceil(plan.partCount / Settings.Speed)}s). Blue ghost shows placement.{warning}`
end

local function runJob(kind: string)
	if state.busy then
		return
	end
	state.busy = true
	state.stopRequested = false
	setProgress(0)
	state.job = task.spawn(function()
		local ok, err = pcall(function()
			local plan = ensurePlan()
			if kind == "preview" then
				setStatus(describePlan(plan), Theme.Text)
				return
			end
			local sent = drawPlan(plan)
			setStatus(`Done! {sent} parts sent.`, Theme.Good)
		end)
		if not ok then
			if err == "__STOPPED__" then
				setStatus(if state.resume then "Stopped — Draw resumes where it left off." else "Stopped.", Theme.SubText)
			elseif err == "__LIMIT__" then
				local done = if state.resume then state.resume.index - 1 else 0
				setStatus(`Server stroke limit hit after {done} parts. Press Draw to resume; if it keeps failing, press Rejoin (the server has blocked this session).`, Theme.Danger)
			else
				warn("[FreeDraw]", err)
				setStatus("Error: " .. tostring(err), Theme.Danger)
			end
		end
		state.busy = false
		state.job = nil
	end)
end

local function undoLast()
	if state.busy then
		return
	end
	local strokes = if state.resume then state.resume.strokes else table.remove(state.history)
	if state.resume then
		state.resume = nil
	end
	if not strokes or #strokes == 0 then
		setStatus("Nothing to undo.")
		return
	end
	local removed = 0
	for _, s in strokes do
		Game.RemovePartEvent:FireServer(s.id, s.count)
		if Game.AddPartCountBindable then
			pcall(Game.AddPartCountBindable.Fire, Game.AddPartCountBindable, -s.count)
		end
		removed += s.count
		state.ownStrokes["Stroke_" .. s.id] = nil
	end
	setStatus(`Removed {removed} parts.`, Theme.Good)
end

----------------------------------------------------------------------------------------------------
-- Input & events
----------------------------------------------------------------------------------------------------
maid:Give(ui.PreviewBtn.Activated:Connect(function()
	state.plan = nil -- re-plan so a new camera direction/position moves the ghost
	runJob("preview")
end))
maid:Give(ui.DrawBtn.Activated:Connect(function()
	runJob("draw")
end))
maid:Give(ui.StopBtn.Activated:Connect(function()
	state.stopRequested = true
end))
maid:Give(ui.UndoBtn.Activated:Connect(undoLast))
-- A blocked session (server refuses every stroke) only clears by rejoining; the script relaunches itself.
maid:Give(ui.RejoinBtn.Activated:Connect(function()
	state.stopRequested = true
	setStatus("Rejoining… the script restarts after the teleport.", Theme.Text)
	teleportToGame()
end))
maid:Give(ui.Fit.Activated:Connect(function()
	local fits = CONST.FITS
	local i = table.find(fits, Settings.Fit) or 1
	Settings.Fit = fits[i % #fits + 1]
	ui.Fit.Text = CONST.FIT_LABEL[Settings.Fit]
end))
maid:Give(ui.Dither.Activated:Connect(function()
	Settings.Dither = not Settings.Dither
	ui.Dither.Text = if Settings.Dither then "Smooth shading: On" else "Smooth shading: Off"
end))

local drag = { active = false, startMouse = Vector2.zero, startPos = UDim2.new() }
maid:Give(titleBar.InputBegan:Connect(function(input: InputObject)
	local t = input.UserInputType
	if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
		drag.active = true
		drag.startMouse = Vector2.new(input.Position.X, input.Position.Y)
		drag.startPos = ui.Window.Position
	end
end))
maid:Give(UserInputService.InputChanged:Connect(function(input: InputObject)
	if not drag.active then
		return
	end
	local t = input.UserInputType
	if t ~= Enum.UserInputType.MouseMovement and t ~= Enum.UserInputType.Touch then
		return
	end
	local delta = Vector2.new(input.Position.X, input.Position.Y) - drag.startMouse
	local viewport = ui.Screen.AbsoluteSize
	local size = ui.Window.AbsoluteSize
	local start = drag.startPos
	local x = math.clamp(start.X.Offset + delta.X, 0, math.max(0, viewport.X - size.X))
	local y = math.clamp(start.Y.Offset + delta.Y, size.Y * 0.5, math.max(size.Y * 0.5, viewport.Y - size.Y * 0.5))
	ui.Window.Position = UDim2.fromOffset(x, y)
end))
maid:Give(UserInputService.InputEnded:Connect(function(input: InputObject)
	local t = input.UserInputType
	if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
		drag.active = false
	end
end))
maid:Give(UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end
	if input.KeyCode == CONST.TOGGLE_KEY then
		ui.Window.Visible = not ui.Window.Visible
	end
end))

----------------------------------------------------------------------------------------------------
-- Cleanup
----------------------------------------------------------------------------------------------------
local controller = {}

function controller.Cleanup()
	if not state.running then
		return
	end
	state.running = false
	state.stopRequested = true
	if state.job and coroutine.status(state.job) ~= "dead" then
		pcall(task.cancel, state.job)
	end
	if state.previewImage then
		state.previewImage:Destroy()
		state.previewImage = nil
	end
	if Exec.delfile then
		for _, path in state.tempFiles do
			pcall(Exec.delfile, path)
		end
	end
	table.clear(state.tempFiles)
	maid:Cleanup()
	if genv.__FREEDRAW_AUTODRAW == controller then
		genv.__FREEDRAW_AUTODRAW = nil
	end
end

-- Scripting API: getgenv().__FREEDRAW_AUTODRAW.Settings.Url = "..."; .Preview() / .Draw() / .Stop() / .Undo()
controller.Settings = Settings
function controller.Preview()
	state.plan = nil
	runJob("preview")
end
function controller.Draw()
	runJob("draw")
end
function controller.Stop()
	state.stopRequested = true
end
function controller.Undo()
	undoLast()
end
function controller.Status(): (string, boolean, any)
	return lastStatus, state.busy, state.plan
end

maid:Give(ui.Unload.Activated:Connect(controller.Cleanup))
genv.__FREEDRAW_AUTODRAW = controller

task.defer(function()
	if not state.running then
		return
	end
	local viewport = ui.Screen.AbsoluteSize
	ui.Window.AnchorPoint = Vector2.new(0, 0.5)
	ui.Window.Position = UDim2.fromOffset(24, viewport.Y * 0.5)
end)
