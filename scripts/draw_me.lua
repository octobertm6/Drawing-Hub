-- Draw Me! — Head Auto-Draw
-- Renders the head of the player you are drawing (face + every accessory attached to the head, nothing
-- below the neck) straight from their in-game meshes and textures, then paints it onto your canvas.
-- "Draw: Whole avatar" renders every body part + all accessories instead (R15 shirt/pants templates
-- are mapped with the body meshes' UVs; R6 bodies get plain part colours).
--
-- How it works (verified live in "Draw Me!", PlaceId 80898524797320):
--   * The round target is DrawingCamera.OtherPlayerBeingDrawn (PlayerScripts.DrawingGame.Canvas.DrawingCamera).
--   * The canvas is a layered EditableImage stack (Gold.Shared.DrawingCanvas3). On Submit / round end the
--     game reads Canvas.Internal.RenderEditableImage and sends that pixel buffer, so whatever we composite
--     into the active layer + render image is what gets submitted.
--   * Head / accessory meshes load with AssetService:CreateEditableMeshAsync and textures with
--     CreateEditableImageAsync. We software-rasterise them (orthographic, z-buffered, supersampled).
--
-- Assumptions: Potassium-style executor (getrenv, setthreadidentity, gethui). Head-attached = an accessory
-- whose Handle is joined to the Head (weld / RigidConstraint) or carries an attachment the Head also has.

if not game:IsLoaded() then
	game.Loaded:Wait()
end

----------------------------------------------------------------------------------------------------
-- Re-execution guard
----------------------------------------------------------------------------------------------------
local genv: any = if type(getgenv) == "function" then getgenv() else _G
if genv.__DRAWME_HEAD and type(genv.__DRAWME_HEAD.Cleanup) == "function" then
	pcall(genv.__DRAWME_HEAD.Cleanup)
end

----------------------------------------------------------------------------------------------------
-- Services & executor features
----------------------------------------------------------------------------------------------------
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local AssetService = game:GetService("AssetService")
local CoreGui = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer

local Exec = {
	getrenv = (if type(getrenv) == "function" then getrenv else nil) :: any,
	setidentity = (if type(setthreadidentity) == "function" then setthreadidentity elseif type(setidentity) == "function" then setidentity else nil) :: any,
	getidentity = (if type(getthreadidentity) == "function" then getthreadidentity elseif type(getidentity) == "function" then getidentity else nil) :: any,
	gethui = (if type(gethui) == "function" then gethui else nil) :: any,
	writefile = (if type(writefile) == "function" then writefile else nil) :: any,
	gethiddenproperty = (if type(gethiddenproperty) == "function" then gethiddenproperty else nil) :: any,
}
if not Exec.getrenv or not Exec.setidentity then
	error("[HeadDraw] executor is missing getrenv / setthreadidentity")
end

----------------------------------------------------------------------------------------------------
-- Theme & constants
----------------------------------------------------------------------------------------------------
local Theme = table.freeze({
	Bg = Color3.fromRGB(18, 20, 26),
	Field = Color3.fromRGB(36, 40, 51),
	FieldHover = Color3.fromRGB(46, 51, 64),
	Stroke = Color3.fromRGB(56, 62, 78),
	Text = Color3.fromRGB(232, 235, 242),
	SubText = Color3.fromRGB(150, 158, 176),
	Accent = Color3.fromRGB(255, 140, 66),
	AccentHover = Color3.fromRGB(255, 166, 107),
	Danger = Color3.fromRGB(226, 72, 84),
	DangerHover = Color3.fromRGB(240, 98, 110),
	Good = Color3.fromRGB(90, 200, 120),
	Font = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Medium),
	FontBold = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold),
	TextSize = 13,
	Corner = UDim.new(0, 6),
	Width = 280,
	Tween = TweenInfo.new(0.14, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
})

local CONST = table.freeze({
	SUPERSAMPLE = 3, -- samples per axis; capped so the internal buffer stays <= MAX_INTERNAL
	MAX_INTERNAL = 1600,
	YIELD_BUDGET = 0.008, -- seconds of render work per frame before yielding
	AMBIENT = 0.62,
	DIFFUSE = 0.48,
	OUTLINE_COLOR = { 34, 30, 38 },
	CUTOUT_ALPHA = 110, -- SpecialMesh / SurfaceAppearance texels below this alpha are see-through
	PODIUM_RADIUS = 12,
	TOGGLE_KEY = Enum.KeyCode.RightShift,
	VIEWS = { 0, 30, -30 },
	VIEW_LABEL = { [0] = "View: Front", [30] = "View: ¾ Left", [-30] = "View: ¾ Right" },
	HEAD_ATTACHMENTS = { "HatAttachment", "HairAttachment", "FaceFrontAttachment", "FaceCenterAttachment" },
	-- Body-mode camera basis, first match wins (R15, then R6).
	BODY_BASIS = { "HumanoidRootPart", "UpperTorso", "Torso" },
})

-- Hand-drawn style tuning. Block sizes are in pixels on a 512 canvas (scaled for 1024).
local SKETCH = table.freeze({
	BLOCKS = { 3, 5, 7, 10 },
	COLORS = { 6, 10, 16, 24 },
	MISTAKE_LABEL = { [0] = "Mistakes: Off", [1] = "Mistakes: Some", [2] = "Mistakes: Lots" },
	WOBBLE = 0.035, -- shape wobble amplitude as a fraction of the canvas (at "Lots")
	WOBBLE_FREQ = 2.2, -- wobble waves across the canvas
	EDGE_LUMA = 70, -- inner lines only where neighbouring colours differ this much in brightness
	HOLE_NOISE = { 0.5, 0.38 }, -- noise above this leaves a missed (uncoloured) patch: Some, Lots
	HOLE_FREQ = 0.14, -- low frequency = a few bigger missed patches instead of speckles
	DARK_DETAIL = 70, -- a block keeps its darkest sample when it is this much darker than the average
	GAP_NOISE = { 0.5, 0.42 }, -- noise above this breaks the outline: Some, Lots
	COLOR_JITTER = 16, -- how far a picked colour may be off (0..255, at "Lots")
	KMEANS_ITERS = 8,
})

local Settings = {
	Style = "Drawn", -- "Drawn" (blocky, flat colours, human mistakes) | "Realistic"
	Blocky = 5,
	Colors = 10,
	Mistakes = 1, -- 0 off, 1 some, 2 lots
	WholeBody = false, -- false = head + head accessories only; true = entire avatar
	Fill = 88, -- % of the canvas the head covers
	View = 0, -- yaw in degrees around the head's up axis
	Shading = true,
	Outline = true,
	OutlineWidth = 2,
	ClearFirst = false,
	TargetName = nil :: string?, -- nil = auto (round target)
}

----------------------------------------------------------------------------------------------------
-- Maid
----------------------------------------------------------------------------------------------------
local Maid = {}
Maid.__index = Maid

function Maid.new()
	return setmetatable({ tasks = {} }, Maid)
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
		elseif kind == "Object" then
			pcall(function()
				item:Destroy()
			end)
		end
	end
end

local maid = Maid.new()
local state = {
	running = true,
	busy = false,
	job = nil :: thread?,
	last = nil :: any, -- last render: { size, buf, target }
	preview = nil :: EditableImage?,
	meshCache = {} :: { [string]: any },
	texCache = {} :: { [string]: any },
	pendingStatus = nil :: { text: string, color: Color3 }?,
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

-- Cooperative yielding: long loops call this so rendering never freezes the game.
local yieldClock = os.clock()
local function yieldMaybe()
	if os.clock() - yieldClock > CONST.YIELD_BUDGET then
		task.wait()
		yieldClock = os.clock()
	end
end

-- Game code (Gold modules, canvas methods) must run at game identity; executor identity is restored after.
local baseIdentity = if Exec.getidentity then Exec.getidentity() else 8
local function asGame<T...>(fn: (...any) -> T..., ...): T...
	Exec.setidentity(2)
	local results = table.pack(pcall(fn, ...))
	Exec.setidentity(baseIdentity)
	if not results[1] then
		error(results[2], 0)
	end
	return table.unpack(results, 2, results.n)
end

local function setStatus(text: string, color: Color3?)
	-- Applied on Heartbeat: after calling game closures this thread may lack UI capability until it yields.
	state.pendingStatus = { text = text, color = color or Theme.SubText }
end

----------------------------------------------------------------------------------------------------
-- Game access
----------------------------------------------------------------------------------------------------
local GameApi = {}

function GameApi.context(): any
	return asGame(function()
		return Exec.getrenv()._G.Gold.Shared.Mana().get("ClientContext"):Get()
	end)
end

function GameApi.canvas(): any
	local ctx = GameApi.context()
	local canvas = ctx and rawget(ctx, "Canvas")
	if type(canvas) ~= "table" or type(canvas.Internal) ~= "table" then
		error("canvas not ready", 0)
	end
	return canvas
end

local drawingCameraModule: ModuleScript? = nil
pcall(function()
	drawingCameraModule = LocalPlayer.PlayerScripts.DrawingGame.Canvas.DrawingCamera
end)

function GameApi.roundTarget(): Player?
	if drawingCameraModule then
		local ok, cam = pcall(asGame, require, drawingCameraModule)
		if ok and type(cam) == "table" then
			local target = rawget(cam, "OtherPlayerBeingDrawn")
			if typeof(target) == "Instance" and target:IsA("Player") and target.Parent then
				return target
			end
		end
	end
	-- Fallback: whoever stands on the podium.
	local podium: Attachment? = nil
	pcall(function()
		podium = workspace.DrawMe.ScriptedParts.PodiumAttachments.DrawnPlayerStandingPosition
	end)
	if not podium then
		return nil
	end
	local best, bestDist = nil, CONST.PODIUM_RADIUS
	for _, player in Players:GetPlayers() do
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			local dist = (root.Position - podium.WorldPosition).Magnitude
			if dist < bestDist then
				best, bestDist = player, dist
			end
		end
	end
	return best
end

local function resolveTarget(): Player?
	if Settings.TargetName then
		local player = Players:FindFirstChild(Settings.TargetName)
		if player and player:IsA("Player") then
			return player
		end
		Settings.TargetName = nil
	end
	return GameApi.roundTarget()
end

local function unwrapImage(image: any): any
	if type(image) == "table" then
		return rawget(image, "EditableImage")
	end
	return image
end

----------------------------------------------------------------------------------------------------
-- Asset loading (meshes & textures), cached by asset id
----------------------------------------------------------------------------------------------------
local function assetKey(uri: string): string
	return uri:match("%d+$") or uri
end

-- Smooth normals for meshes that ship without them: average adjacent face normals per position.
local function computeNormals(positions: { Vector3 }, tris: { number }): { Vector3 }
	local acc = table.create(#positions, Vector3.zero)
	for t = 1, #tris, 3 do
		local a, b, c = tris[t], tris[t + 1], tris[t + 2]
		local n = (positions[b] - positions[a]):Cross(positions[c] - positions[a])
		acc[a] += n
		acc[b] += n
		acc[c] += n
	end
	for i, n in acc do
		acc[i] = if n.Magnitude > 1e-9 then n.Unit else Vector3.yAxis
	end
	return acc
end

-- Returns { positions, tris (position indices), cu, cv (per corner), cn (per-corner normals), min, max }.
local function loadMesh(uri: string): any
	local key = assetKey(uri)
	local cached = state.meshCache[key]
	if cached then
		return cached
	end
	local mesh = AssetService:CreateEditableMeshAsync(Content.fromUri(uri))
	local ok, result = pcall(function()
		local index: { [any]: number } = {}
		local positions: { Vector3 } = {}
		local tris, cu, cv, cn = {}, {}, {}, {}
		local hasNormals = true
		local minV, maxV = Vector3.one * math.huge, -Vector3.one * math.huge
		for _, vid in mesh:GetVertices() do
			local p = mesh:GetPosition(vid)
			table.insert(positions, p)
			index[vid] = #positions
			minV = minV:Min(p)
			maxV = maxV:Max(p)
		end
		for _, fid in mesh:GetFaces() do
			local verts = mesh:GetFaceVertices(fid)
			if #verts == 3 then
				local uvs = mesh:GetFaceUVs(fid)
				local okN, normals = pcall(mesh.GetFaceNormals, mesh, fid)
				for k = 1, 3 do
					table.insert(tris, index[verts[k]])
					local uvId = uvs and uvs[k]
					local uv = if uvId then mesh:GetUV(uvId) else nil
					table.insert(cu, if uv then uv.X else 0)
					table.insert(cv, if uv then uv.Y else 0)
					local nId = okN and normals and normals[k]
					local n = if nId then mesh:GetNormal(nId) else nil
					if n and n.Magnitude > 1e-6 then
						table.insert(cn, n.Unit)
					else
						hasNormals = false
						table.insert(cn, Vector3.yAxis)
					end
				end
			end
			yieldMaybe()
		end
		if not hasNormals then
			local smooth = computeNormals(positions, tris)
			for k, pi in tris do
				cn[k] = smooth[pi]
			end
		end
		return { positions = positions, tris = tris, cu = cu, cv = cv, cn = cn, min = minV, max = maxV }
	end)
	mesh:Destroy()
	if not ok then
		error(result, 0)
	end
	state.meshCache[key] = result
	return result
end

local function loadTexture(uri: string): any
	if uri == "" then
		return nil
	end
	local key = assetKey(uri)
	local cached = state.texCache[key]
	if cached ~= nil then
		return cached or nil
	end
	local ok, image = pcall(function()
		return AssetService:CreateEditableImageAsync(Content.fromUri(uri))
	end)
	if not ok or not image then
		warn("[HeadDraw] texture failed to load:", uri, image)
		state.texCache[key] = false
		return nil
	end
	local size = image.Size
	local tex = { w = size.X, h = size.Y, buf = image:ReadPixelsBuffer(Vector2.zero, size) }
	image:Destroy()
	state.texCache[key] = tex
	return tex
end

-- Procedural shapes for classic parts (unit space, -0.5..0.5).
local Shapes = {}

local function lathe(profile: { Vector2 }, segments: number): any
	local positions, tris = {}, {}
	for _, pr in profile do
		for s = 0, segments - 1 do
			local a = s / segments * math.pi * 2
			table.insert(positions, Vector3.new(math.cos(a) * pr.X, pr.Y, math.sin(a) * pr.X))
		end
	end
	for r = 0, #profile - 2 do
		for s = 0, segments - 1 do
			local a = r * segments + s + 1
			local b = r * segments + (s + 1) % segments + 1
			local c = a + segments
			local d = b + segments
			table.insert(tris, a)
			table.insert(tris, c)
			table.insert(tris, b)
			table.insert(tris, b)
			table.insert(tris, c)
			table.insert(tris, d)
		end
	end
	return positions, tris
end

local function finishShape(positions: { Vector3 }, tris: { number }): any
	local normals = computeNormals(positions, tris)
	local cu, cv, cn = {}, {}, {}
	for k, pi in tris do
		cu[k], cv[k], cn[k] = 0, 0, normals[pi]
	end
	return { positions = positions, tris = tris, cu = cu, cv = cv, cn = cn, min = -Vector3.one * 0.5, max = Vector3.one * 0.5 }
end

function Shapes.get(kind: string): any
	local cached = state.meshCache["shape:" .. kind]
	if cached then
		return cached
	end
	local positions, tris
	if kind == "head" then
		-- Classic rounded-cylinder head.
		positions, tris = lathe({
			Vector2.new(0, -0.5), Vector2.new(0.32, -0.5), Vector2.new(0.44, -0.46), Vector2.new(0.5, -0.34),
			Vector2.new(0.5, 0.34), Vector2.new(0.44, 0.46), Vector2.new(0.32, 0.5), Vector2.new(0, 0.5),
		}, 28)
	elseif kind == "sphere" then
		local profile = {}
		for i = 0, 12 do
			local a = -math.pi / 2 + i / 12 * math.pi
			table.insert(profile, Vector2.new(math.cos(a) * 0.5, math.sin(a) * 0.5))
		end
		positions, tris = lathe(profile, 24)
	elseif kind == "cylinder" then
		positions, tris = lathe({ Vector2.new(0, -0.5), Vector2.new(0.5, -0.5), Vector2.new(0.5, 0.5), Vector2.new(0, 0.5) }, 24)
	else -- box
		positions = {}
		for i = 0, 7 do
			table.insert(positions, Vector3.new(if i % 2 == 0 then -0.5 else 0.5, if (i // 2) % 2 == 0 then -0.5 else 0.5, if i // 4 == 0 then -0.5 else 0.5))
		end
		tris = { 1, 3, 2, 2, 3, 4, 5, 6, 7, 6, 8, 7, 1, 2, 5, 2, 6, 5, 3, 7, 4, 4, 7, 8, 1, 5, 3, 3, 5, 7, 2, 4, 6, 4, 8, 6 }
	end
	local shape = finishShape(positions, tris)
	state.meshCache["shape:" .. kind] = shape
	return shape
end

----------------------------------------------------------------------------------------------------
-- Gathering the head + head accessories
----------------------------------------------------------------------------------------------------
local function isAttachedToHead(handle: BasePart, head: BasePart): boolean
	for _, child in handle:GetChildren() do
		if child:IsA("JointInstance") then
			if child.Part0 == head or child.Part1 == head then
				return true
			end
		elseif child:IsA("RigidConstraint") or child:IsA("WeldConstraint") then
			local ok, linked = pcall(function()
				if child:IsA("WeldConstraint") then
					return child.Part0 == head or child.Part1 == head
				end
				local a0, a1 = child.Attachment0, child.Attachment1
				return (a0 ~= nil and a0.Parent == head) or (a1 ~= nil and a1.Parent == head)
			end)
			if ok and linked then
				return true
			end
		end
	end
	-- No joint found (not built yet / custom rig): match by attachment name.
	for _, name in CONST.HEAD_ATTACHMENTS do
		if handle:FindFirstChild(name) and head:FindFirstChild(name) then
			return true
		end
	end
	return false
end

local function visible(part: BasePart): boolean
	return part.Transparency < 0.9
end

local function surfaceColorMap(sa: Instance): string
	for _, prop in { "ColorMap", "ColorMapContent" } do
		local ok, value = pcall(function()
			return (sa :: any)[prop]
		end)
		if not ok and Exec.gethiddenproperty then
			ok, value = pcall(Exec.gethiddenproperty, sa, prop)
		end
		if ok then
			if typeof(value) == "Content" then
				value = value.Uri
			end
			if type(value) == "string" and value ~= "" then
				return value
			end
		end
	end
	return ""
end

-- One drawable: mesh data + how to place it + how to colour it.
type Drawable = {
	part: BasePart,
	mesh: any,
	toLocal: (Vector3) -> Vector3, -- mesh space -> part space
	normalScale: Vector3,
	color: { number },
	tex: any,
	texMode: string, -- "blend" (alpha reveals part colour) | "cutout" (alpha is see-through)
	tint: { number },
	clothing: any?, -- box-projected classic template info (see loadClothing), R15 body parts only
	decals: { any },
	decalExtent: Vector3, -- part-space size the Front decal is stretched over
}

local function buildDrawable(part: BasePart, setText: (string) -> (), clothing: any?): Drawable?
	if not visible(part) then
		return nil
	end
	local color = { part.Color.R * 255, part.Color.G * 255, part.Color.B * 255 }
	local d: any = {
		part = part,
		color = color,
		tint = { 1, 1, 1 },
		texMode = "blend",
		clothing = clothing,
		decals = {},
		normalScale = Vector3.one,
	}
	local size = part.Size
	local special = part:FindFirstChildOfClass("SpecialMesh")
	if part:IsA("MeshPart") and part.MeshId ~= "" then
		setText("Loading mesh " .. part.Name .. "…")
		d.mesh = loadMesh(part.MeshId)
		local extent = d.mesh.max - d.mesh.min
		local scale = Vector3.new(size.X / math.max(extent.X, 1e-4), size.Y / math.max(extent.Y, 1e-4), size.Z / math.max(extent.Z, 1e-4))
		local center = (d.mesh.min + d.mesh.max) / 2
		d.toLocal = function(p: Vector3): Vector3
			return (p - center) * scale
		end
		d.normalScale = Vector3.one / scale
		d.decalExtent = size
		local sa = part:FindFirstChildOfClass("SurfaceAppearance")
		local texUri = part.TextureID
		if sa then
			local mapUri = surfaceColorMap(sa)
			if mapUri ~= "" then
				texUri = mapUri
				local okMode, alphaMode = pcall(function()
					return (sa :: any).AlphaMode
				end)
				d.texMode = if okMode and alphaMode == Enum.AlphaMode.Overlay then "blend" else "cutout"
			end
		end
		d.tex = loadTexture(texUri)
	elseif special and special.MeshType == Enum.MeshType.FileMesh and special.MeshId ~= "" then
		setText("Loading mesh " .. part.Name .. "…")
		d.mesh = loadMesh(special.MeshId)
		local scale, offset = special.Scale, special.Offset
		d.toLocal = function(p: Vector3): Vector3
			return p * scale + offset
		end
		d.normalScale = Vector3.one / scale
		d.decalExtent = (d.mesh.max - d.mesh.min) * scale
		d.tex = loadTexture(special.TextureId)
		d.texMode = "cutout"
		local vc = special.VertexColor
		d.tint = { vc.X, vc.Y, vc.Z }
	else
		local kind, dims = "box", size
		if special then
			local scale = special.Scale
			if special.MeshType == Enum.MeshType.Head then
				local w = math.min(size.X, size.Z)
				kind, dims = "head", Vector3.new(w * scale.X, size.Y * scale.Y, w * scale.Z)
			elseif special.MeshType == Enum.MeshType.Sphere then
				kind, dims = "sphere", size * scale
			elseif special.MeshType == Enum.MeshType.Cylinder then
				kind, dims = "cylinder", size * scale
			else
				dims = size * scale
			end
		elseif part:IsA("Part") then
			if part.Shape == Enum.PartType.Ball then
				kind = "sphere"
			elseif part.Shape == Enum.PartType.Cylinder then
				kind = "cylinder"
			end
		end
		d.mesh = Shapes.get(kind)
		d.toLocal = function(p: Vector3): Vector3
			return p * dims
		end
		d.normalScale = Vector3.one / dims
		d.decalExtent = dims
	end
	for _, child in part:GetChildren() do
		if child:IsA("Decal") and child.Face == Enum.NormalId.Front and child.Transparency < 0.95 then
			local tex = loadTexture(child.Texture)
			if tex then
				local c = child.Color3
				table.insert(d.decals, { tex = tex, opacity = 1 - child.Transparency, tint = { c.R, c.G, c.B } })
			end
		end
	end
	return d
end

-- Classic clothing for the whole-body mode.
-- R15 body meshes do NOT use template UVs (each part spans 0..1; verified), so clothing is box-projected
-- the way the classic 585x559 template is laid out: every limb is a box whose four sides are 64x128 strips
-- (upper part, lower part and hand/foot stacked top to bottom) plus 64x64 top/bottom caps; the torso is
-- 128x128 front/back, 64x128 sides, 128x64 caps (UpperTorso above LowerTorso).
-- Face ids: 1 front(-Z) 2 back(+Z) 3 -X side 4 +X side 5 top(+Y) 6 bottom(-Y). Rects are { x, y, w, h }.
-- Strip order follows the unfolded box: right of the front face is the -X side (the viewer's right).
local TEMPLATE = table.freeze({
	W = 585,
	H = 559,
	TORSO = { { 231, 74, 128, 128 }, { 427, 74, 128, 128 }, { 361, 74, 64, 128 }, { 165, 74, 64, 128 }, { 231, 8, 128, 64 }, { 231, 204, 128, 64 } },
	-- Left half of the template = the character's RIGHT limb, right half = LEFT limb.
	RIGHT_LIMB = { { 217, 355, 64, 128 }, { 85, 355, 64, 128 }, { 19, 355, 64, 128 }, { 151, 355, 64, 128 }, { 217, 289, 64, 64 }, { 217, 485, 64, 64 } },
	LEFT_LIMB = { { 308, 355, 64, 128 }, { 440, 355, 64, 128 }, { 374, 355, 64, 128 }, { 506, 355, 64, 128 }, { 308, 289, 64, 64 }, { 308, 485, 64, 64 } },
})

local CLOTHING_GROUPS = table.freeze({
	{ parts = { "UpperTorso", "LowerTorso" }, rects = TEMPLATE.TORSO, layers = "torso" },
	{ parts = { "RightUpperArm", "RightLowerArm", "RightHand" }, rects = TEMPLATE.RIGHT_LIMB, layers = "arms" },
	{ parts = { "LeftUpperArm", "LeftLowerArm", "LeftHand" }, rects = TEMPLATE.LEFT_LIMB, layers = "arms" },
	{ parts = { "RightUpperLeg", "RightLowerLeg", "RightFoot" }, rects = TEMPLATE.RIGHT_LIMB, layers = "legs" },
	{ parts = { "LeftUpperLeg", "LeftLowerLeg", "LeftFoot" }, rects = TEMPLATE.LEFT_LIMB, layers = "legs" },
})

-- Returns { [BasePart] = clothing info } for the R15 body parts, plus the T-shirt texture.
-- The template's limb strips are shared: on a shirt they are the arms, on pants the legs, so arms take
-- ONLY the shirt, legs ONLY the pants, and the torso gets pants with the shirt on top.
local function loadClothing(character: Model): ({ [BasePart]: any }, any)
	local pants = character:FindFirstChildOfClass("Pants")
	local shirt = character:FindFirstChildOfClass("Shirt")
	local graphic = character:FindFirstChildOfClass("ShirtGraphic")
	local pantsTex = if pants then loadTexture(pants.PantsTemplate) else nil
	local shirtTex = if shirt then loadTexture(shirt.ShirtTemplate) else nil
	local layerSets = { arms = {}, legs = {}, torso = {} }
	if shirtTex then
		table.insert(layerSets.arms, shirtTex)
	end
	if pantsTex then
		table.insert(layerSets.legs, pantsTex)
		table.insert(layerSets.torso, pantsTex)
	end
	if shirtTex then
		table.insert(layerSets.torso, shirtTex)
	end

	local map = {}
	for _, group in CLOTHING_GROUPS do
		local layers = layerSets[group.layers]
		if #layers == 0 then
			continue
		end
		local chain, total = {}, 0
		for _, name in group.parts do
			local part = character:FindFirstChild(name)
			if part and part:IsA("BasePart") then
				table.insert(chain, part)
				total += part.Size.Y
			end
		end
		local offset = 0
		for i, part in chain do
			map[part] = {
				layers = layers,
				rects = group.rects,
				vOffset = offset,
				vTotal = total,
				isTop = i == 1,
				isBottom = i == #chain,
			}
			offset += part.Size.Y
		end
	end
	return map, if graphic then loadTexture(graphic.Graphic) else nil
end

-- Template pixel (x, y in 585x559 space) for a part-space point on the given box face, or nil.
local function templatePoint(info: any, face: number, px: number, py: number, pz: number, size: Vector3): (number?, number?)
	local u, v
	if face == 5 or face == 6 then
		-- Caps exist only at the ends of a chain (shoulder / sole); inner joints show no clothing.
		if (face == 5 and not info.isTop) or (face == 6 and not info.isBottom) then
			return nil, nil
		end
		u = 0.5 - px / size.X
		v = if face == 5 then 0.5 - pz / size.Z else 0.5 + pz / size.Z
	else
		if face == 1 then
			u = 0.5 - px / size.X
		elseif face == 2 then
			u = 0.5 + px / size.X
		elseif face == 3 then
			u = 0.5 + pz / size.Z
		else
			u = 0.5 - pz / size.Z
		end
		v = (info.vOffset + (0.5 - py / size.Y) * size.Y) / info.vTotal
	end
	local rect = info.rects[face]
	u = math.clamp(u, 0, 0.999)
	v = math.clamp(v, 0, 0.999)
	return rect[1] + u * rect[3], rect[2] + v * rect[4]
end

local function gatherParts(character: Model, wholeBody: boolean, setText: (string) -> ()): { Drawable }
	local head = character:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then
		error("target has no head", 0)
	end
	local parts: { BasePart } = { head }
	local bodyParts: { [BasePart]: boolean } = {}
	if wholeBody then
		for _, child in character:GetChildren() do
			if child:IsA("BasePart") and child ~= head and child.Name ~= "HumanoidRootPart" then
				table.insert(parts, child)
				bodyParts[child] = true
			end
		end
	end
	for _, item in character:GetChildren() do
		if item:IsA("Accessory") or item:IsA("Hat") then
			local handle = item:FindFirstChild("Handle")
			if handle and handle:IsA("BasePart") and (wholeBody or isAttachedToHead(handle, head)) then
				table.insert(parts, handle)
			end
		end
	end

	local clothing, tshirt = {}, nil
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local isR15 = humanoid ~= nil and humanoid.RigType == Enum.HumanoidRigType.R15
	if wholeBody and isR15 then
		setText("Loading clothing…")
		clothing, tshirt = loadClothing(character)
	end

	local drawables = {}
	for _, part in parts do
		local ok, d = pcall(buildDrawable, part, setText, if bodyParts[part] then clothing[part] else nil)
		if ok and d and tshirt and part.Name == "UpperTorso" then
			table.insert(d.decals, { tex = tshirt, opacity = 1, tint = { 1, 1, 1 } })
		end
		if ok and d then
			table.insert(drawables, d)
		elseif not ok then
			warn("[HeadDraw] skipped", part:GetFullName(), d)
		end
	end
	return drawables
end

----------------------------------------------------------------------------------------------------
-- Software rasteriser
----------------------------------------------------------------------------------------------------
-- Orthographic camera looking at the head's face. Screen +x = camera right, +y = down.
-- `front` is the direction the face/body points; parts can be rotated inside their model (one avatar's
-- Head part faced backwards), so callers derive it from attachments / the root rather than part.CFrame.
local function cameraBasis(center: Vector3, front: Vector3, up: Vector3, yawDeg: number)
	up = up.Unit
	front = front - up * front:Dot(up)
	front = if front.Magnitude > 1e-4 then front.Unit else Vector3.zAxis
	front = CFrame.fromAxisAngle(up, math.rad(yawDeg)):VectorToWorldSpace(front)
	local dir = -front -- camera looks back at the face
	local right = dir:Cross(up).Unit
	up = right:Cross(dir).Unit
	-- Light from upper-left in front of the face.
	local light = (-right * 0.45 + up * 0.55 - dir * 0.75).Unit
	return { origin = center, right = right, up = up, dir = dir, light = light }
end

type Target = { W: number, H: number, col: buffer, z: buffer }

local function newTarget(W: number, H: number): Target
	local z = buffer.create(W * H * 4)
	for i = 0, W * H - 1 do
		buffer.writef32(z, i * 4, math.huge)
	end
	return { W = W, H = H, col = buffer.create(W * H * 4), z = z }
end

-- Projects a drawable's vertices into screen space and per-corner lighting.
local function project(d: Drawable, cam: any, scale: number, ox: number, oy: number, shading: boolean)
	local mesh = d.mesh
	local cf = d.part.CFrame
	local positions = mesh.positions
	local n = #positions
	local sx, sy, sz = table.create(n, 0), table.create(n, 0), table.create(n, 0)
	local lx, ly = table.create(n, 0), table.create(n, 0)
	-- Part-space positions, only needed to box-project clothing.
	local clothed = d.clothing ~= nil
	local ppx, ppy, ppz = {}, {}, {}
	local origin, right, up, dir = cam.origin, cam.right, cam.up, cam.dir
	local toLocal = d.toLocal
	local extent = d.decalExtent
	for i = 1, n do
		local localPos = toLocal(positions[i])
		local rel = cf:PointToWorldSpace(localPos) - origin
		sx[i] = rel:Dot(right) * scale + ox
		sy[i] = -rel:Dot(up) * scale + oy
		sz[i] = rel:Dot(dir)
		-- Front decal UVs: viewer facing the Front (-Z) face sees part -X on their right.
		lx[i] = 0.5 - localPos.X / extent.X
		ly[i] = 0.5 - localPos.Y / extent.Y
		if clothed then
			ppx[i], ppy[i], ppz[i] = localPos.X, localPos.Y, localPos.Z
		end
	end
	local cn = mesh.cn
	local corners = #mesh.tris
	local inten, front = table.create(corners, 1), table.create(corners, 0)
	local ns = d.normalScale
	local light = cam.light
	local local3: { Vector3 } = {}
	local faces = {}
	for k = 1, corners do
		local nl = cn[k] * ns
		nl = if nl.Magnitude > 1e-9 then nl.Unit else Vector3.yAxis
		front[k] = -nl.Z
		if shading then
			local nw = cf:VectorToWorldSpace(nl)
			if nw:Dot(dir) > 0 then
				nw = -nw -- back face seen from inside: light it as if it faced us
			end
			inten[k] = CONST.AMBIENT + CONST.DIFFUSE * math.max(0, nw:Dot(light))
		end
		if clothed then
			-- One template face per triangle (from its averaged normal) so a triangle never straddles two faces.
			local slot = (k - 1) % 3 + 1
			local3[slot] = nl
			if slot == 3 then
				local a = local3[1] + local3[2] + local3[3]
				local ax, ay, az = math.abs(a.X), math.abs(a.Y), math.abs(a.Z)
				local face
				if az >= ax and az >= ay then
					face = if a.Z < 0 then 1 else 2
				elseif ax >= ay then
					face = if a.X < 0 then 3 else 4
				else
					face = if a.Y > 0 then 5 else 6
				end
				faces[k - 2] = face
			end
		end
	end
	return {
		sx = sx, sy = sy, sz = sz, lx = lx, ly = ly, inten = inten, front = front,
		px = ppx, py = ppy, pz = ppz, faces = faces,
	}
end

local function bounds(drawables: { Drawable }, cam: any): (number, number, number, number)
	local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
	for _, d in drawables do
		local cf = d.part.CFrame
		for _, p in d.mesh.positions do
			local rel = cf:PointToWorldSpace(d.toLocal(p)) - cam.origin
			local x, y = rel:Dot(cam.right), -rel:Dot(cam.up)
			minX, maxX = math.min(minX, x), math.max(maxX, x)
			minY, maxY = math.min(minY, y), math.max(maxY, y)
		end
		yieldMaybe()
	end
	return minX, minY, maxX, maxY
end

local function rasterise(target: Target, d: Drawable, P: any)
	local sx, sy, sz, lx, ly, inten, front = P.sx, P.sy, P.sz, P.lx, P.ly, P.inten, P.front
	local ppx, ppy, ppz, faces = P.px, P.py, P.pz, P.faces
	local W, H, col, zb = target.W, target.H, target.col, target.z
	local tris, cu, cv = d.mesh.tris, d.mesh.cu, d.mesh.cv
	local baseR, baseG, baseB = d.color[1], d.color[2], d.color[3]
	local tintR, tintG, tintB = d.tint[1], d.tint[2], d.tint[3]
	local tex = d.tex
	local tw, th, tb = 0, 0, nil :: buffer?
	if tex then
		tw, th, tb = tex.w, tex.h, tex.buf
	end
	local cutout = d.texMode == "cutout"
	local clothing = d.clothing
	local hasClothing = clothing ~= nil
	local partSize = d.part.Size
	local decals = d.decals
	local hasDecal = #decals > 0
	local cutAlpha = CONST.CUTOUT_ALPHA
	local floor, min, max = math.floor, math.min, math.max

	for k = 1, #tris, 3 do
		local i0, i1, i2 = tris[k], tris[k + 1], tris[k + 2]
		local x0, y0, x1, y1, x2, y2 = sx[i0], sy[i0], sx[i1], sy[i1], sx[i2], sy[i2]
		local area = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0)
		if area > -1e-9 and area < 1e-9 then
			continue
		end
		local minX = max(0, floor(min(x0, x1, x2)))
		local maxX = min(W - 1, floor(max(x0, x1, x2)))
		local minY = max(0, floor(min(y0, y1, y2)))
		local maxY = min(H - 1, floor(max(y0, y1, y2)))
		if minX > maxX or minY > maxY then
			continue
		end
		local inv = 1 / area
		local z0, z1, z2 = sz[i0], sz[i1], sz[i2]
		local u0, u1, u2 = cu[k], cu[k + 1], cu[k + 2]
		local v0, v1, v2 = cv[k], cv[k + 1], cv[k + 2]
		local l0, l1, l2 = inten[k], inten[k + 1], inten[k + 2]
		for py = minY, maxY do
			local fy = py + 0.5
			local row = py * W
			for px = minX, maxX do
				local fx = px + 0.5
				local w0 = ((x1 - fx) * (y2 - fy) - (x2 - fx) * (y1 - fy)) * inv
				if w0 < -1e-7 then
					continue
				end
				local w1 = ((x2 - fx) * (y0 - fy) - (x0 - fx) * (y2 - fy)) * inv
				if w1 < -1e-7 then
					continue
				end
				local w2 = 1 - w0 - w1
				if w2 < -1e-7 then
					continue
				end
				local idx = (row + px) * 4
				local depth = w0 * z0 + w1 * z1 + w2 * z2
				if depth >= buffer.readf32(zb, idx) then
					continue
				end
				local r, g, b = baseR, baseG, baseB
				if tb then
					local u = w0 * u0 + w1 * u1 + w2 * u2
					local v = w0 * v0 + w1 * v1 + w2 * v2
					u -= floor(u)
					v -= floor(v)
					local tx = min(tw - 1, floor(u * tw))
					local ty = min(th - 1, floor(v * th))
					local o = (ty * tw + tx) * 4
					local ta = buffer.readu8(tb, o + 3)
					if cutout then
						if ta < cutAlpha then
							continue
						end
						r = buffer.readu8(tb, o) * tintR
						g = buffer.readu8(tb, o + 1) * tintG
						b = buffer.readu8(tb, o + 2) * tintB
					else
						local a = ta / 255
						r += (buffer.readu8(tb, o) - r) * a
						g += (buffer.readu8(tb, o + 1) - g) * a
						b += (buffer.readu8(tb, o + 2) - b) * a
					end
				end
				if hasClothing then
					local tx, ty = templatePoint(
						clothing,
						faces[k],
						w0 * ppx[i0] + w1 * ppx[i1] + w2 * ppx[i2],
						w0 * ppy[i0] + w1 * ppy[i1] + w2 * ppy[i2],
						w0 * ppz[i0] + w1 * ppz[i1] + w2 * ppz[i2],
						partSize
					)
					if tx then
						for _, layer in clothing.layers do
							-- Templates come in any resolution (2x HD templates are common): scale from 585x559.
							local lxp = min(layer.w - 1, floor(tx * layer.w / TEMPLATE.W))
							local lyp = min(layer.h - 1, floor(ty * layer.h / TEMPLATE.H))
							local o = (lyp * layer.w + lxp) * 4
							local a = buffer.readu8(layer.buf, o + 3) / 255
							if a > 0 then
								r += (buffer.readu8(layer.buf, o) - r) * a
								g += (buffer.readu8(layer.buf, o + 1) - g) * a
								b += (buffer.readu8(layer.buf, o + 2) - b) * a
							end
						end
					end
				end
				if hasDecal and (w0 * front[k] + w1 * front[k + 1] + w2 * front[k + 2]) > 0.2 then
					local du = w0 * lx[i0] + w1 * lx[i1] + w2 * lx[i2]
					local dv = w0 * ly[i0] + w1 * ly[i1] + w2 * ly[i2]
					if du >= 0 and du < 1 and dv >= 0 and dv < 1 then
						for _, decal in decals do
							local dt = decal.tex
							local o = (floor(dv * dt.h) * dt.w + floor(du * dt.w)) * 4
							local a = buffer.readu8(dt.buf, o + 3) / 255 * decal.opacity
							if a > 0 then
								r += (buffer.readu8(dt.buf, o) * decal.tint[1] - r) * a
								g += (buffer.readu8(dt.buf, o + 1) * decal.tint[2] - g) * a
								b += (buffer.readu8(dt.buf, o + 2) * decal.tint[3] - b) * a
							end
						end
					end
				end
				local li = w0 * l0 + w1 * l1 + w2 * l2
				r = min(255, floor(r * li + 0.5))
				g = min(255, floor(g * li + 0.5))
				b = min(255, floor(b * li + 0.5))
				buffer.writeu32(col, idx, r + g * 256 + b * 65536 + 0xFF000000)
				buffer.writef32(zb, idx, depth)
			end
		end
		yieldMaybe()
	end
end

-- Box-filters the supersampled target down to N x N straight-alpha RGBA.
local function downsample(target: Target, ss: number, N: number): buffer
	local out = buffer.create(N * N * 4)
	local col, W = target.col, target.W
	local samples = ss * ss
	for y = 0, N - 1 do
		for x = 0, N - 1 do
			local r, g, b, covered = 0, 0, 0, 0
			for sy = 0, ss - 1 do
				local base = ((y * ss + sy) * W + x * ss) * 4
				for sxi = 0, ss - 1 do
					local o = base + sxi * 4
					if buffer.readu8(col, o + 3) > 0 then
						r += buffer.readu8(col, o)
						g += buffer.readu8(col, o + 1)
						b += buffer.readu8(col, o + 2)
						covered += 1
					end
				end
			end
			if covered > 0 then
				local o = (y * N + x) * 4
				buffer.writeu8(out, o, r // covered)
				buffer.writeu8(out, o + 1, g // covered)
				buffer.writeu8(out, o + 2, b // covered)
				buffer.writeu8(out, o + 3, (covered * 255) // samples)
			end
		end
		yieldMaybe()
	end
	return out
end

-- Dark silhouette outline drawn behind the head (only where the head is not already opaque).
local function addOutline(img: buffer, N: number, width: number)
	local alpha = buffer.create(N * N)
	for i = 0, N * N - 1 do
		buffer.writeu8(alpha, i, buffer.readu8(img, i * 4 + 3))
	end
	local cr, cg, cb = CONST.OUTLINE_COLOR[1], CONST.OUTLINE_COLOR[2], CONST.OUTLINE_COLOR[3]
	local w2 = width * width
	for y = 0, N - 1 do
		for x = 0, N - 1 do
			local i = y * N + x
			local own = buffer.readu8(alpha, i)
			if own >= 250 then
				continue
			end
			local best = 0
			for dy = -width, width do
				local yy = y + dy
				if yy < 0 or yy >= N then
					continue
				end
				for dx = -width, width do
					local xx = x + dx
					if xx >= 0 and xx < N and dx * dx + dy * dy <= w2 then
						local a = buffer.readu8(alpha, yy * N + xx)
						if a > best then
							best = a
						end
					end
				end
			end
			if best > own then
				-- Head over outline: blend the existing (partial) head pixel over the outline colour.
				local o = i * 4
				local fa = own / 255
				buffer.writeu8(img, o, math.floor(buffer.readu8(img, o) * fa + cr * (1 - fa)))
				buffer.writeu8(img, o + 1, math.floor(buffer.readu8(img, o + 1) * fa + cg * (1 - fa)))
				buffer.writeu8(img, o + 2, math.floor(buffer.readu8(img, o + 2) * fa + cb * (1 - fa)))
				buffer.writeu8(img, o + 3, best)
			end
		end
		yieldMaybe()
	end
end

----------------------------------------------------------------------------------------------------
-- Hand-drawn stylizer: wobbly shapes -> big blocks -> few flat colours -> thick crayon outline,
-- plus colouring that misses the lines a little, missed spots and outline gaps.
----------------------------------------------------------------------------------------------------
local Sketch = {}
Sketch.NEIGHBOURS = table.freeze({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } })

local function colorDist(r1: number, g1: number, b1: number, r2: number, g2: number, b2: number): number
	local dr, dg, db = r1 - r2, g1 - g2, b1 - b2
	return 2 * dr * dr + 4 * dg * dg + 3 * db * db
end

-- k-means over the filled cells; returns palette arrays and a label per cell.
function Sketch.quantize(cells: { number }, cr, cg, cb, k: number)
	local count = #cells
	k = math.min(k, count)
	local pr, pg, pb = {}, {}, {}
	-- Farthest-point seeding: start at a random cell, then keep adding the cell farthest from all seeds.
	local first = cells[math.random(1, count)]
	pr[1], pg[1], pb[1] = cr[first], cg[first], cb[first]
	local nearest = table.create(count, math.huge)
	for c = 2, k do
		local bestCell, bestDist = cells[1], -1
		for i, idx in cells do
			local d = colorDist(cr[idx], cg[idx], cb[idx], pr[c - 1], pg[c - 1], pb[c - 1])
			if d < nearest[i] then
				nearest[i] = d
			end
			if nearest[i] > bestDist then
				bestCell, bestDist = idx, nearest[i]
			end
		end
		pr[c], pg[c], pb[c] = cr[bestCell], cg[bestCell], cb[bestCell]
	end
	local label = {}
	for _ = 1, SKETCH.KMEANS_ITERS do
		local sr, sg, sb, sn = table.create(k, 0), table.create(k, 0), table.create(k, 0), table.create(k, 0)
		for _, idx in cells do
			local r, g, b = cr[idx], cg[idx], cb[idx]
			local best, bestDist = 1, math.huge
			for c = 1, k do
				local d = colorDist(r, g, b, pr[c], pg[c], pb[c])
				if d < bestDist then
					best, bestDist = c, d
				end
			end
			label[idx] = best
			sr[best] += r
			sg[best] += g
			sb[best] += b
			sn[best] += 1
		end
		for c = 1, k do
			if sn[c] > 0 then
				pr[c], pg[c], pb[c] = sr[c] / sn[c], sg[c] / sn[c], sb[c] / sn[c]
			end
		end
		yieldMaybe()
	end
	return pr, pg, pb, label
end

function Sketch.apply(src: buffer, N: number): buffer
	local mistakes = Settings.Mistakes
	local mf = mistakes / 2
	local B = math.max(2, math.floor(Settings.Blocky * N / 512 + 0.5))
	local G = math.ceil(N / B)
	local seed = math.random() * 1000
	local amp = N * SKETCH.WOBBLE * mf
	local freq = SKETCH.WOBBLE_FREQ / N
	local total = G * G

	-- 1. Sample each block at a wobbled position (math.noise is smooth, so shapes bend instead of fraying).
	local cr, cg, cb = table.create(total, 0), table.create(total, 0), table.create(total, 0)
	local filled = table.create(total, false)
	local cells = {}
	local q = B / 4
	for gy = 0, G - 1 do
		for gx = 0, G - 1 do
			local cx, cy = (gx + 0.5) * B, (gy + 0.5) * B
			if amp > 0 then
				local nx, ny = cx * freq, cy * freq
				cx += math.noise(nx, ny, seed) * amp * 2
				cy += math.noise(nx + 31.7, ny - 11.3, seed) * amp * 2
			end
			local r, g, b, covered = 0, 0, 0, 0
			local darkR, darkG, darkB, darkLuma = 0, 0, 0, math.huge
			for s = 0, 8 do
				-- 3x3 samples across the block (centre included) so thin features are not stepped over.
				local x = math.floor(cx + ((s % 3) - 1) * q * 1.5)
				local y = math.floor(cy + ((s // 3) - 1) * q * 1.5)
				if x >= 0 and x < N and y >= 0 and y < N then
					local o = (y * N + x) * 4
					if buffer.readu8(src, o + 3) >= 128 then
						local sr, sg, sb = buffer.readu8(src, o), buffer.readu8(src, o + 1), buffer.readu8(src, o + 2)
						r += sr
						g += sg
						b += sb
						covered += 1
						local l = 0.299 * sr + 0.587 * sg + 0.114 * sb
						if l < darkLuma then
							darkR, darkG, darkB, darkLuma = sr, sg, sb, l
						end
					end
				end
			end
			if covered >= 5 then
				local idx = gy * G + gx + 1
				filled[idx] = true
				r, g, b = r / covered, g / covered, b / covered
				-- Eyes, mouth and other small dark marks would average away; a person draws them anyway.
				if 0.299 * r + 0.587 * g + 0.114 * b - darkLuma > SKETCH.DARK_DETAIL then
					r, g, b = darkR, darkG, darkB
				end
				cr[idx], cg[idx], cb[idx] = r, g, b
				table.insert(cells, idx)
			end
		end
		yieldMaybe()
	end
	if #cells == 0 then
		return buffer.create(N * N * 4)
	end

	-- 2. Few flat colours, then a 3x3 majority filter so texture noise turns into clean patches.
	local pr, pg, pb, label = Sketch.quantize(cells, cr, cg, cb, Settings.Colors)
	local smooth = table.clone(label)
	local votes = {}
	for _, idx in cells do
		local gx, gy = (idx - 1) % G, (idx - 1) // G
		table.clear(votes)
		local own = label[idx]
		local best, bestVotes = own, 0
		for dy = -1, 1 do
			for dx = -1, 1 do
				local x, y = gx + dx, gy + dy
				if x >= 0 and x < G and y >= 0 and y < G then
					local l = label[y * G + x + 1]
					if l then
						local v = (votes[l] or 0) + 1
						votes[l] = v
						if v > bestVotes or (v == bestVotes and l == own) then
							best, bestVotes = l, v
						end
					end
				end
			end
		end
		smooth[idx] = best
	end
	label = smooth

	-- A person never picks the exact colour: nudge each palette entry a little.
	local jitter = SKETCH.COLOR_JITTER * mf
	for c = 1, #pr do
		pr[c] = math.clamp(math.floor(pr[c] + (math.random() - 0.5) * jitter + 0.5), 0, 255)
		pg[c] = math.clamp(math.floor(pg[c] + (math.random() - 0.5) * jitter + 0.5), 0, 255)
		pb[c] = math.clamp(math.floor(pb[c] + (math.random() - 0.5) * jitter + 0.5), 0, 255)
	end

	-- 3. Outline: silhouette blocks plus blocks where brightness jumps between colour patches.
	local outline = table.create(total, false)
	if Settings.Outline then
		local function luma(l: number): number
			return 0.299 * pr[l] + 0.587 * pg[l] + 0.114 * pb[l]
		end
		for _, idx in cells do
			local gx, gy = (idx - 1) % G, (idx - 1) // G
			local own = luma(label[idx])
			for _, dir in Sketch.NEIGHBOURS do
				local x, y = gx + dir[1], gy + dir[2]
				local nIdx = y * G + x + 1
				if x < 0 or x >= G or y < 0 or y >= G or not filled[nIdx] then
					outline[idx] = true
					break
				end
				-- Inner line on the darker side only, so lines stay one block thick.
				local other = luma(label[nIdx])
				if label[nIdx] ~= label[idx] and other - own > SKETCH.EDGE_LUMA then
					outline[idx] = true
					break
				end
			end
		end
	end

	-- 4. Paint blocks. The fill is shifted a block off the lines (colouring outside / short of them),
	--    with missed spots inside and small breaks in the outline.
	local shiftX, shiftY = 0, 0
	if mistakes > 0 then
		repeat
			shiftX, shiftY = math.random(-1, 1), math.random(-1, 1)
		until mistakes < 2 or shiftX ~= 0 or shiftY ~= 0
	end
	local holeAt = if mistakes > 0 then SKETCH.HOLE_NOISE[mistakes] else math.huge
	local gapAt = if mistakes > 0 then SKETCH.GAP_NOISE[mistakes] else math.huge
	local ocR, ocG, ocB = CONST.OUTLINE_COLOR[1], CONST.OUTLINE_COLOR[2], CONST.OUTLINE_COLOR[3]
	local out = buffer.create(N * N * 4)
	for gy = 0, G - 1 do
		for gx = 0, G - 1 do
			local idx = gy * G + gx + 1
			local packed = 0
			if outline[idx] and math.noise(gx * 0.55, gy * 0.55, seed + 9.1) <= gapAt then
				packed = ocR + ocG * 256 + ocB * 65536 + 0xFF000000
			else
				local sx, sy = gx - shiftX, gy - shiftY
				if sx >= 0 and sx < G and sy >= 0 and sy < G then
					local sIdx = sy * G + sx + 1
					local l = label[sIdx]
					local hole = math.noise(gx * SKETCH.HOLE_FREQ, gy * SKETCH.HOLE_FREQ, seed + 4.7) > holeAt
					if l and not outline[sIdx] and not hole then
						packed = pr[l] + pg[l] * 256 + pb[l] * 65536 + 0xFF000000
					end
				end
			end
			if packed ~= 0 then
				local x0, y0 = gx * B, gy * B
				for y = y0, math.min(N, y0 + B) - 1 do
					local row = y * N
					for x = x0, math.min(N, x0 + B) - 1 do
						buffer.writeu32(out, (row + x) * 4, packed)
					end
				end
			end
		end
		yieldMaybe()
	end
	return out
end

local function renderHead(player: Player, N: number, setText: (string) -> ()): buffer
	local character = player.Character
	if not character then
		error(player.Name .. " has no character", 0)
	end
	local wholeBody = Settings.WholeBody
	local drawables = gatherParts(character, wholeBody, setText)
	if #drawables == 0 then
		error("nothing to draw on " .. player.Name, 0)
	end
	-- Head mode faces the face (FaceFrontAttachment sits in front of it); body mode faces the root
	-- (the head may be turned by the pose).
	local head = character:FindFirstChild("Head") :: BasePart
	local front, up = head.CFrame.LookVector, head.CFrame.UpVector
	if wholeBody then
		for _, name in CONST.BODY_BASIS do
			local part = character:FindFirstChild(name)
			if part and part:IsA("BasePart") then
				front, up = part.CFrame.LookVector, part.CFrame.UpVector
				break
			end
		end
	else
		local faceFront = head:FindFirstChild("FaceFrontAttachment")
		if faceFront and faceFront:IsA("Attachment") then
			local offset = faceFront.WorldPosition - head.Position
			if offset.Magnitude > 0.05 then
				front = offset
			end
		end
	end
	local cam = cameraBasis(head.Position, front, up, Settings.View)

	local ss = math.max(1, math.min(CONST.SUPERSAMPLE, CONST.MAX_INTERNAL // N))
	local W = N * ss
	setText("Rendering " .. #drawables .. " parts…")
	local minX, minY, maxX, maxY = bounds(drawables, cam)
	local span = math.max(maxX - minX, maxY - minY, 1e-3)
	local scale = W * (Settings.Fill / 100) / span
	local ox = W / 2 - (minX + maxX) / 2 * scale
	local oy = W / 2 - (minY + maxY) / 2 * scale

	local target = newTarget(W, W)
	for _, d in drawables do
		rasterise(target, d, project(d, cam, scale, ox, oy, Settings.Shading))
	end
	setText("Smoothing…")
	local img = downsample(target, ss, N)
	if Settings.Style == "Drawn" then
		setText("Making it look hand-drawn…")
		return Sketch.apply(img, N)
	end
	if Settings.Outline then
		addOutline(img, N, Settings.OutlineWidth)
	end
	return img
end

----------------------------------------------------------------------------------------------------
-- Canvas output
----------------------------------------------------------------------------------------------------
local function canvasSize(): number
	local canvas = GameApi.canvas()
	local size = canvas.Internal.RenderEditableImageCanvasSize
	return if typeof(size) == "Vector2" then size.X else 512
end

-- Blends the head over the active layer, re-composites the canvas the same way the game does
-- (white base + visible layers, BlendSourceOver) and pushes an undo state so Ctrl+Z still works.
local function paintOntoCanvas(img: buffer, N: number)
	local canvas = GameApi.canvas()
	local internal = canvas.Internal
	while internal.SynchronousRenderJobActive or internal.RenderJobActive do
		task.wait()
	end
	local size = internal.RenderEditableImageCanvasSize
	if size.X ~= N or size.Y ~= N then
		error("canvas size changed, press Draw again", 0)
	end
	local layers = canvas.Layers
	local layer = asGame(function()
		return canvas:GetLayerFromIndex(layers.ActiveLayerIndex or 1)
	end) or layers.List[1]
	if not layer then
		error("no canvas layer", 0)
	end
	local raw = unwrapImage(layer.Internal.EditableImage)
	if #canvas.History.UndoStack == 0 then
		asGame(canvas.SaveCanvasState, canvas)
	end

	local dst = if Settings.ClearFirst then buffer.create(N * N * 4) else raw:ReadPixelsBuffer(Vector2.zero, size)
	for i = 0, N * N - 1 do
		local o = i * 4
		local sa = buffer.readu8(img, o + 3)
		if sa == 0 then
			continue
		end
		if sa == 255 then
			buffer.writeu32(dst, o, buffer.readu32(img, o))
			continue
		end
		local fa = sa / 255
		local da = buffer.readu8(dst, o + 3) / 255
		local outA = fa + da * (1 - fa)
		for c = 0, 2 do
			local v = (buffer.readu8(img, o + c) * fa + buffer.readu8(dst, o + c) * da * (1 - fa)) / outA
			buffer.writeu8(dst, o + c, math.floor(v + 0.5))
		end
		buffer.writeu8(dst, o + 3, math.floor(outA * 255 + 0.5))
	end
	raw:WritePixelsBuffer(Vector2.zero, size, dst)

	local render = unwrapImage(internal.RenderEditableImage)
	render:WritePixelsBuffer(Vector2.zero, size, internal.WhiteEditableImagePixelBuffer)
	for _, l in layers.List do
		if l.Visible then
			render:DrawImage(Vector2.zero, unwrapImage(l.Internal.EditableImage), Enum.ImageCombineType.BlendSourceOver)
		end
	end
	asGame(canvas.SaveCanvasState, canvas)
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
	Name = "DrawMe_HeadDraw",
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	DisplayOrder = 60,
	IgnoreGuiInset = true,
	Parent = host,
}))

ui.Window = create("Frame", {
	Name = "Window",
	AnchorPoint = Vector2.new(1, 0.5),
	Position = UDim2.new(1, -24, 0.5, 0),
	Size = UDim2.fromOffset(Theme.Width, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundColor3 = Theme.Bg,
	BorderSizePixel = 0,
	Active = true,
	Parent = ui.Screen,
}, {
	create("UICorner", { CornerRadius = UDim.new(0, 10) }),
	create("UIStroke", { Color = Theme.Stroke, Thickness = 1 }),
})

local titleBar = create("Frame", {
	Size = UDim2.new(1, 0, 0, 34),
	BackgroundTransparency = 1,
	Active = true,
	Parent = ui.Window,
}, {
	create("TextLabel", {
		Size = UDim2.new(1, -24, 1, 0),
		Position = UDim2.fromOffset(12, 0),
		BackgroundTransparency = 1,
		Text = "Head Auto-Draw",
		TextColor3 = Theme.Text,
		FontFace = Theme.FontBold,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
	}),
	create("TextLabel", {
		Size = UDim2.new(1, -24, 1, 0),
		Position = UDim2.fromOffset(12, 0),
		BackgroundTransparency = 1,
		Text = "RShift hides",
		TextColor3 = Theme.SubText,
		FontFace = Theme.Font,
		TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Right,
	}),
})

local body = create("Frame", {
	Position = UDim2.fromOffset(0, 34),
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1,
	Parent = ui.Window,
}, {
	create("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12), PaddingBottom = UDim.new(0, 12) }),
	create("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }),
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

-- Target picker: ◀ [Auto: name] ▶
local targetRow = Row(30)
ui.Prev = Button("◀", Theme.Field, Theme.FieldHover, targetRow, UDim2.fromOffset(30, 30))
ui.Target = Button("Auto", Theme.Field, Theme.FieldHover, targetRow, UDim2.new(1, -76, 1, 0))
ui.Target.TextTruncate = Enum.TextTruncate.AtEnd
ui.Next = Button("▶", Theme.Field, Theme.FieldHover, targetRow, UDim2.fromOffset(30, 30))

local half = UDim2.new(0.5, -4, 1, 0)
local row1 = Row(28)
ui.View = Button(CONST.VIEW_LABEL[Settings.View], Theme.Field, Theme.FieldHover, row1, half)
ui.Fill = Button("Size: " .. Settings.Fill .. "%", Theme.Field, Theme.FieldHover, row1, half)
local row2 = Row(28)
ui.Shading = Button("Shading: On", Theme.Field, Theme.FieldHover, row2, half)
ui.Outline = Button("Outline: On", Theme.Field, Theme.FieldHover, row2, half)
local row3 = Row(28)
ui.Mode = Button("Draw: Head only", Theme.Field, Theme.FieldHover, row3, half)
ui.Clear = Button("Clear layer: Off", Theme.Field, Theme.FieldHover, row3, half)
local row4 = Row(28)
ui.Style = Button("Style: Hand-drawn", Theme.Field, Theme.FieldHover, row4, half)
ui.Mistakes = Button(SKETCH.MISTAKE_LABEL[Settings.Mistakes], Theme.Field, Theme.FieldHover, row4, half)
local row5 = Row(28)
ui.Blocky = Button("Blocky: " .. Settings.Blocky, Theme.Field, Theme.FieldHover, row5, half)
ui.Colors = Button("Colours: " .. Settings.Colors, Theme.Field, Theme.FieldHover, row5, half)

ui.Preview = create("ImageLabel", {
	Size = UDim2.new(1, 0, 0, 0),
	BackgroundColor3 = Color3.new(1, 1, 1),
	BorderSizePixel = 0,
	ScaleType = Enum.ScaleType.Fit,
	LayoutOrder = nextOrder(),
	Parent = body,
}, {
	create("UICorner", { CornerRadius = Theme.Corner }),
	create("UIAspectRatioConstraint", { AspectRatio = 1 }),
})

local actions = Row(32)
ui.PreviewButton = Button("Preview", Theme.Field, Theme.FieldHover, actions, half)
ui.Draw = Button("Draw head", Theme.Accent, Theme.AccentHover, actions, half)

ui.Status = create("TextLabel", {
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1,
	Text = "Ready.",
	TextColor3 = Theme.SubText,
	FontFace = Theme.Font,
	TextSize = 12,
	TextWrapped = true,
	TextXAlignment = Enum.TextXAlignment.Left,
	LayoutOrder = nextOrder(),
	Parent = body,
})

ui.Unload = Button("Unload", Theme.Danger, Theme.DangerHover, body, UDim2.new(1, 0, 0, 26))

----------------------------------------------------------------------------------------------------
-- UI behaviour
----------------------------------------------------------------------------------------------------
local lastTargetText = ""
local function refreshTargetLabel()
	local text
	if Settings.TargetName then
		text = Settings.TargetName
	else
		local target = GameApi.roundTarget()
		text = "Auto: " .. (if target then target.Name else "no round target")
	end
	if text ~= lastTargetText then
		lastTargetText = text
		ui.Target.Text = text
	end
end

local function cycleTarget(step: number)
	local names = { "" } -- "" = auto
	for _, player in Players:GetPlayers() do
		table.insert(names, player.Name)
	end
	table.sort(names)
	local current = Settings.TargetName or ""
	local index = table.find(names, current) or 1
	index = (index - 1 + step) % #names + 1
	Settings.TargetName = if names[index] == "" then nil else names[index]
	refreshTargetLabel()
end

local function showPreview(img: buffer, N: number)
	local preview = state.preview
	if not preview or preview.Size.X ~= N then
		if preview then
			preview:Destroy()
		end
		preview = AssetService:CreateEditableImage({ Size = Vector2.new(N, N) })
		state.preview = preview
	end
	-- Preview on white so it matches the canvas.
	local shown = buffer.create(N * N * 4)
	for i = 0, N * N - 1 do
		local o = i * 4
		local a = buffer.readu8(img, o + 3) / 255
		for c = 0, 2 do
			buffer.writeu8(shown, o + c, math.floor(buffer.readu8(img, o + c) * a + 255 * (1 - a) + 0.5))
		end
		buffer.writeu8(shown, o + 3, 255)
	end
	preview:WritePixelsBuffer(Vector2.zero, preview.Size, shown)
	ui.Preview.ImageContent = Content.fromObject(preview)
end

local function startJob(drawIt: boolean)
	if state.busy then
		return
	end
	state.busy = true
	state.job = task.spawn(function()
		local ok, err = pcall(function()
			local player = resolveTarget()
			if not player then
				error("no target — pick a player with ◀ ▶", 0)
			end
			local N = canvasSize()
			local t0 = os.clock()
			local img = renderHead(player, N, function(text)
				setStatus(text)
			end)
			state.last = { img = img, N = N, target = player.Name }
			task.wait() -- regain UI capability before touching the preview
			showPreview(img, N)
			if drawIt then
				setStatus("Painting onto canvas…")
				paintOntoCanvas(img, N)
				local what = if Settings.WholeBody then "avatar" else "head"
				setStatus(string.format("Drew %s's %s (%.1fs). Submit when ready.", player.Name, what, os.clock() - t0), Theme.Good)
			else
				setStatus(string.format("Preview of %s (%.1fs). Press Draw head to paint it.", player.Name, os.clock() - t0), Theme.Good)
			end
		end)
		if not ok then
			setStatus("Error: " .. tostring(err), Theme.Danger)
			warn("[HeadDraw]", err)
		end
		state.busy = false
		state.job = nil
	end)
end

maid:Give(ui.Prev.Activated:Connect(function()
	cycleTarget(-1)
end))
maid:Give(ui.Next.Activated:Connect(function()
	cycleTarget(1)
end))
maid:Give(ui.Target.Activated:Connect(function()
	Settings.TargetName = nil
	refreshTargetLabel()
end))
maid:Give(ui.View.Activated:Connect(function()
	local index = table.find(CONST.VIEWS, Settings.View) or 1
	Settings.View = CONST.VIEWS[index % #CONST.VIEWS + 1]
	ui.View.Text = CONST.VIEW_LABEL[Settings.View]
end))
maid:Give(ui.Fill.Activated:Connect(function()
	Settings.Fill = if Settings.Fill >= 96 then 60 else Settings.Fill + 8
	ui.Fill.Text = "Size: " .. Settings.Fill .. "%"
end))
maid:Give(ui.Shading.Activated:Connect(function()
	Settings.Shading = not Settings.Shading
	ui.Shading.Text = "Shading: " .. (if Settings.Shading then "On" else "Off")
end))
maid:Give(ui.Outline.Activated:Connect(function()
	Settings.Outline = not Settings.Outline
	ui.Outline.Text = "Outline: " .. (if Settings.Outline then "On" else "Off")
end))
maid:Give(ui.Mode.Activated:Connect(function()
	Settings.WholeBody = not Settings.WholeBody
	ui.Mode.Text = if Settings.WholeBody then "Draw: Whole avatar" else "Draw: Head only"
	ui.Draw.Text = if Settings.WholeBody then "Draw avatar" else "Draw head"
end))
local function cycle(list: { number }, current: number): number
	local index = table.find(list, current) or 0
	return list[index % #list + 1]
end
maid:Give(ui.Style.Activated:Connect(function()
	Settings.Style = if Settings.Style == "Drawn" then "Realistic" else "Drawn"
	ui.Style.Text = if Settings.Style == "Drawn" then "Style: Hand-drawn" else "Style: Realistic"
end))
maid:Give(ui.Mistakes.Activated:Connect(function()
	Settings.Mistakes = (Settings.Mistakes + 1) % 3
	ui.Mistakes.Text = SKETCH.MISTAKE_LABEL[Settings.Mistakes]
end))
maid:Give(ui.Blocky.Activated:Connect(function()
	Settings.Blocky = cycle(SKETCH.BLOCKS, Settings.Blocky)
	ui.Blocky.Text = "Blocky: " .. Settings.Blocky
end))
maid:Give(ui.Colors.Activated:Connect(function()
	Settings.Colors = cycle(SKETCH.COLORS, Settings.Colors)
	ui.Colors.Text = "Colours: " .. Settings.Colors
end))
maid:Give(ui.Clear.Activated:Connect(function()
	Settings.ClearFirst = not Settings.ClearFirst
	ui.Clear.Text = "Clear layer: " .. (if Settings.ClearFirst then "On" else "Off")
end))
maid:Give(ui.PreviewButton.Activated:Connect(function()
	startJob(false)
end))
maid:Give(ui.Draw.Activated:Connect(function()
	startJob(true)
end))

-- Dragging by the title bar (one persistent InputChanged connection gated by a flag).
do
	local dragging, dragStart, startPos = false, Vector2.zero, ui.Window.Position
	maid:Give(titleBar.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = Vector2.new(input.Position.X, input.Position.Y)
			startPos = ui.Window.Position
		end
	end))
	maid:Give(UserInputService.InputChanged:Connect(function(input: InputObject)
		if not dragging then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
			local delta = Vector2.new(input.Position.X, input.Position.Y) - dragStart
			ui.Window.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
		end
	end))
	maid:Give(UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end))
end

maid:Give(UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
	if not processed and input.KeyCode == CONST.TOGGLE_KEY then
		ui.Screen.Enabled = not ui.Screen.Enabled
	end
end))

-- Status + target label applier (throttled to 4 Hz for the target lookup).
do
	local acc = 0
	maid:Give(RunService.Heartbeat:Connect(function(dt: number)
		local pending = state.pendingStatus
		if pending then
			state.pendingStatus = nil
			ui.Status.Text = pending.text
			ui.Status.TextColor3 = pending.color
		end
		acc += dt
		if acc >= 0.25 and ui.Screen.Enabled then
			acc = 0
			pcall(refreshTargetLabel)
		end
	end))
end

----------------------------------------------------------------------------------------------------
-- Cleanup registration
----------------------------------------------------------------------------------------------------
local function Cleanup()
	if not state.running then
		return
	end
	state.running = false
	if state.job then
		pcall(task.cancel, state.job)
		state.job = nil
	end
	-- If a job was cancelled mid game-call, put the executor identity back.
	pcall(Exec.setidentity, baseIdentity)
	maid:Cleanup()
	if state.preview then
		state.preview:Destroy()
		state.preview = nil
	end
	table.clear(state.meshCache)
	table.clear(state.texCache)
	if genv.__DRAWME_HEAD and genv.__DRAWME_HEAD.Cleanup == Cleanup then
		genv.__DRAWME_HEAD = nil
	end
end

maid:Give(ui.Unload.Activated:Connect(Cleanup))

genv.__DRAWME_HEAD = {
	Cleanup = Cleanup,
	Settings = Settings,
	-- Debug: writes the last render as "W H\n" + raw RGBA so it can be inspected outside the game.
	Export = function(path: string)
		local last = state.last
		if last and Exec.writefile then
			Exec.writefile(path, last.N .. " " .. last.N .. "\n" .. buffer.tostring(last.img))
			return true
		end
		return false
	end,
	Render = function(drawIt: boolean?)
		startJob(drawIt == true)
	end,
	IsBusy = function()
		return state.busy
	end,
}

refreshTargetLabel()
setStatus("Ready. Target follows the round automatically.")
