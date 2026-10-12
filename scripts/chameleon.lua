-- Chameleon! — Auto Camouflage
-- One button (or C) repaints your whole character to match what's around you, through the game's own
-- UV painter, so it replicates to everyone like normal painting.
--
-- How it works (verified in-game, PlaceId 84449017742177, 2026-10-12):
--   * The game's paint controller (a shared table with meshContextByPart, drawLocalUVPaintPoint,
--     finishPendingUVStroke…) is reached through the PaintCharacterBatch listener's upvalues.
--   * Each hider UV mesh has a context with Triangles (UVs, FaceId, bind-pose Positions, VertexIds) and
--     skinning data (PosedRaycastCache.VertexDataById: bone influences). We pose the vertices exactly like
--     the game does, then walk a G x G grid over the UV texture: every grid cell inside a triangle gets a
--     3D point and normal on your body.
--   * Colour for a point = what a viewer looking straight at that spot would see behind you: a ray from the
--     point along -normal, through your own body, skipping see-through parts. Part / union colour, terrain
--     material colour, the actual pixel of a Decal / Texture on the hit face, or a textured mesh's average.
--   * Points go out through drawLocalUVPaintPoint (draws locally + queues "UVStrokeBatch" points), paced at
--     the game's own rate (60 points per 0.05 s), then finishPendingUVStroke ends the stroke.

if not game:IsLoaded() then
	game.Loaded:Wait()
end

----------------------------------------------------------------------------------------------------
-- Re-execution guard
----------------------------------------------------------------------------------------------------
local genv: any = if type(getgenv) == "function" then getgenv() else _G
if genv.__CHAMELEON_PAINT and type(genv.__CHAMELEON_PAINT.Cleanup) == "function" then
	pcall(genv.__CHAMELEON_PAINT.Cleanup)
end

----------------------------------------------------------------------------------------------------
-- Services
----------------------------------------------------------------------------------------------------
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AssetService = game:GetService("AssetService")
local MaterialService = game:GetService("MaterialService")
local CoreGui = game:GetService("CoreGui")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer

if type(getconnections) ~= "function" or type(debug.getupvalues) ~= "function" then
	error("[Camo] executor needs getconnections + debug.getupvalues")
end

local Remotes = ReplicatedStorage:WaitForChild("Remotes", 30)
local BatchRemote = Remotes and Remotes:WaitForChild("PaintCharacterBatch", 30)
if not BatchRemote then
	error("[Camo] this isn't Chameleon! (no Remotes.PaintCharacterBatch)")
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
	Accent = Color3.fromRGB(90, 200, 120),
	AccentHover = Color3.fromRGB(120, 220, 145),
	Danger = Color3.fromRGB(226, 72, 84),
	Font = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Medium),
	FontBold = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold),
	Corner = UDim.new(0, 8),
	Width = 250,
	Tween = TweenInfo.new(0.14, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
})

local CONST = table.freeze({
	PAINT_KEY = Enum.KeyCode.C,
	ESP_KEY = Enum.KeyCode.G, -- V, F, E, Q, R are the game's hider keys
	TOGGLE_KEY = Enum.KeyCode.K, -- the game already uses RightShift
	POINTS_PER_TICK = 60, -- the game's own batch size…
	TICK = 0.05, -- …and send interval
	STROKES_PER_TICK = 3, -- stroke ends (each one is a remote send) allowed per tick
	RAY_LENGTH = 400,
	RAY_SKIP_LIMIT = 6, -- see-through parts to look past before giving up
	SEE_THROUGH = 0.7, -- parts at least this transparent are looked through
	RADIUS_SCALE = 0.8, -- brush radius vs grid cell (slight overlap, no gaps)
	FILTER_TAPS = 6, -- max samples per side when averaging the patch of texture one paint dot covers
	YIELD_BUDGET = 0.006,
	SKY = Color3.fromRGB(170, 190, 215), -- nothing behind you at all
	ESP_INTERVAL = 0.25,
	ENEMY_FILL = Color3.fromRGB(255, 60, 90),
	ENEMY_OUTLINE = Color3.fromRGB(255, 255, 255),
	MAX_ORIGIN = 18, -- the shotgun's MaxCameraOriginDistance: how far from you a shot may start
	WALL_RANGE = 4, -- a wall this close to your middle counts as "the wall you're hiding against"
	WALL_RAYS = 24,
	-- Where a MaterialVariant's tile starts on a part face: "center" (tile corner at the face centre) or
	-- "corner" (decal-style, from the face's top-left). Not documented by Roblox; see chameleon_snapshot.json.
	VARIANT_ORIGIN = "center",
})

local Settings = {
	Detail = 128, -- UV grid cells per side (512 px texture: 128 = one dot every 4 px)
	Brightness = 100, -- % of the texture colour (your body gets the same lighting as the wall, so 100 matches)
	-- seeker
	ShowEnemies = true,
	RapidFire = false,
	ShotDelay = 620, -- ms between rapid shots; the server drops shots closer than ~0.45-0.6 s apart
	Wallbang = false,
	AimRadius = 300, -- px from the crosshair an enemy can be to get the through-wall shot
}

----------------------------------------------------------------------------------------------------
-- Maid & state
----------------------------------------------------------------------------------------------------
local tasks: { any } = {}
local function give(item: any): any
	table.insert(tasks, item)
	return item
end

local state = {
	running = true,
	busy = false,
	stop = false,
	controller = nil :: any,
	pendingStatus = nil :: any,
	pendingProgress = nil :: number?,
	textureCache = {} :: { [string]: any }, -- asset uri -> sampled texture, or false if it can't be read
	variantCache = {} :: { [string]: any }, -- "Material/Name" -> { tex, studs } or false
	decalCache = setmetatable({}, { __mode = "k" }) :: { [BasePart]: { Decal } },
}

local yieldClock = os.clock()
local function yieldMaybe()
	if os.clock() - yieldClock > CONST.YIELD_BUDGET then
		task.wait()
		yieldClock = os.clock()
	end
	if state.stop or not state.running then
		error("__STOPPED__", 0)
	end
end

local function setStatus(text: string, good: boolean?)
	state.pendingStatus = { text = text, color = if good == false then Theme.Danger elseif good then Theme.Accent else Theme.SubText }
end

----------------------------------------------------------------------------------------------------
-- The game's paint controller
----------------------------------------------------------------------------------------------------
local function findController(): any
	local cached = state.controller
	if cached and rawget(cached, "meshContextByPart") ~= nil then
		return cached
	end
	local function scan(fn: any): any
		local ok, ups = pcall(debug.getupvalues, fn)
		if not ok then
			return nil
		end
		for _, up in ups do
			if type(up) == "table" and rawget(up, "meshContextByPart") ~= nil and type(rawget(up, "drawLocalUVPaintPoint")) == "function" then
				return up
			end
		end
		return nil
	end
	for _, conn in getconnections(BatchRemote.OnClientEvent) do
		local fn = conn.Function
		if type(fn) == "function" then
			local found = scan(fn)
			if not found then
				local ok, ups = pcall(debug.getupvalues, fn)
				if ok then
					for _, up in ups do
						if type(up) == "function" then
							found = scan(up)
							if found then
								break
							end
						end
					end
				end
			end
			if found then
				state.controller = found
				return found
			end
		end
	end
	return nil
end

----------------------------------------------------------------------------------------------------
-- Posing the body: the same skinning maths as the game (bone TransformedWorldCFrame x bind pose)
----------------------------------------------------------------------------------------------------
local function posedVertices(meshPart: MeshPart, cache: any): { [any]: Vector3 }
	local scale = cache.RenderScale
	local out = {}
	for i, id in cache.VertexIds do
		local data = cache.VertexDataById[id]
		if data and data.IsValid then
			local p = data.BindMeshPosition
			if #data.Influences > 0 then
				local sum = Vector3.zero
				for _, inf in data.Influences do
					local rel = meshPart.CFrame:ToObjectSpace(inf.Bone.TransformedWorldCFrame)
					local pos = rel.Position
					local scaled = Vector3.new(
						if scale.X == 0 then 0 else pos.X / scale.X,
						if scale.Y == 0 then 0 else pos.Y / scale.Y,
						if scale.Z == 0 then 0 else pos.Z / scale.Z
					)
					local boneCF = CFrame.fromMatrix(scaled, rel.XVector, rel.YVector, rel.ZVector)
					sum += (boneCF * inf.BindMeshCFrame:Inverse()):PointToWorldSpace(data.BindMeshPosition) * inf.Weight
				end
				p = sum
			end
			out[id] = meshPart.CFrame:PointToWorldSpace(Vector3.new(p.X * scale.X, p.Y * scale.Y, p.Z * scale.Z))
		end
		if i % 2000 == 0 then
			yieldMaybe()
		end
	end
	return out
end

-- Every grid cell of the UV texture that lies on the body: { part, uv, faceId, pos, normal }.
local function bodySamples(controller: any, meshPart: MeshPart, grid: number): { any }
	local ctx = controller.meshContextByPart[meshPart]
	if not (ctx and ctx.UVMaskReady) then
		error("your paint texture isn't ready yet (open the paint editor once, then try again)", 0)
	end
	local cache = ctx.PosedRaycastCache
	if not (cache and cache.Triangles and cache.VertexDataById) then
		error("body mesh data isn't built yet (open the paint editor once, then try again)", 0)
	end
	local world = posedVertices(meshPart, cache)
	local taken = {}
	local samples = {}
	for ti, tri in cache.Triangles do
		local a, b, c = world[tri.VertexIds[1]], world[tri.VertexIds[2]], world[tri.VertexIds[3]]
		if a and b and c and ctx.FaceToIsland[tri.FaceId] then
			local ua, ub, uc = tri.UVs[1], tri.UVs[2], tri.UVs[3]
			local cross = (b - a):Cross(c - a)
			if cross.Magnitude > 1e-9 then
				local normal = cross.Unit
				-- barycentric set-up in UV space
				local v0x, v0y = ub.X - ua.X, ub.Y - ua.Y
				local v1x, v1y = uc.X - ua.X, uc.Y - ua.Y
				local den = v0x * v1y - v1x * v0y
				if math.abs(den) > 1e-12 then
					-- studs of body surface one grid cell covers on this triangle
					local cell = math.sqrt(cross.Magnitude / math.abs(den)) / grid
					local x0 = math.max(0, math.floor(math.min(ua.X, ub.X, uc.X) * grid))
					local x1 = math.min(grid - 1, math.floor(math.max(ua.X, ub.X, uc.X) * grid))
					local y0 = math.max(0, math.floor(math.min(ua.Y, ub.Y, uc.Y) * grid))
					local y1 = math.min(grid - 1, math.floor(math.max(ua.Y, ub.Y, uc.Y) * grid))
					for gy = y0, y1 do
						for gx = x0, x1 do
							local key = gy * grid + gx
							if not taken[key] then
								local u, v = (gx + 0.5) / grid, (gy + 0.5) / grid
								local px, py = u - ua.X, v - ua.Y
								local w1 = (px * v1y - v1x * py) / den
								local w2 = (v0x * py - px * v0y) / den
								local w0 = 1 - w1 - w2
								if w0 >= -1e-4 and w1 >= -1e-4 and w2 >= -1e-4 then
									taken[key] = true
									table.insert(samples, {
										gx = gx,
										gy = gy,
										island = ctx.FaceToIsland[tri.FaceId],
										part = meshPart,
										uv = Vector2.new(u, v),
										faceId = tri.FaceId,
										pos = a * w0 + b * w1 + c * w2,
										normal = normal,
										cell = cell,
									})
								end
							end
						end
					end
				end
			end
		end
		if ti % 400 == 0 then
			yieldMaybe()
		end
	end
	-- Other players' clients join consecutive points of one stroke with a line, so order the cells as a
	-- snake (row by row, alternating direction) inside each UV island: almost every point then sits next
	-- to the one before it, and runs() cuts a new stroke wherever it doesn't.
	local islandIndex = {}
	local islandCount = 0
	for _, s in samples do
		if islandIndex[s.island] == nil then
			islandCount += 1
			islandIndex[s.island] = islandCount
		end
		s.islandIndex = islandIndex[s.island]
	end
	table.sort(samples, function(p, q)
		if p.islandIndex ~= q.islandIndex then
			return p.islandIndex < q.islandIndex
		end
		if p.gy ~= q.gy then
			return p.gy < q.gy
		end
		if p.gy % 2 == 0 then
			return p.gx < q.gx
		end
		return p.gx > q.gx
	end)
	return samples
end

-- Splits ordered samples into strokes of touching cells (same part + island, at most one cell apart).
local function runs(samples: { any }): { { any } }
	local out = {}
	local current = nil
	local previous = nil
	for _, s in samples do
		local touching = previous ~= nil
			and previous.part == s.part
			and previous.island == s.island
			and math.abs(previous.gx - s.gx) <= 1
			and math.abs(previous.gy - s.gy) <= 1
		if not touching then
			current = {}
			table.insert(out, current)
		end
		table.insert(current, s)
		previous = s
	end
	return out
end

----------------------------------------------------------------------------------------------------
-- Colour of whatever is behind a point
----------------------------------------------------------------------------------------------------
-- A texture kept at full resolution as a raw RGBA buffer (the EditableImage itself is freed straight
-- away). Shrinking fine patterns like damask wallpaper first turns them into noise, so we don't.
local function loadTexture(uri: string): any
	local cached = state.textureCache[uri]
	if cached ~= nil then
		return cached or nil
	end
	state.textureCache[uri] = false -- mark as tried (failures stay cached)
	local ok, image = pcall(function()
		return AssetService:CreateEditableImageAsync(Content.fromUri(uri))
	end)
	if not ok or not image then
		return nil
	end
	local size = image.Size
	local okRead, buf = pcall(image.ReadPixelsBuffer, image, Vector2.zero, size)
	pcall(image.Destroy, image)
	if not okRead then
		return nil
	end
	local w, h = size.X, size.Y
	local sumR, sumG, sumB, sumA = 0, 0, 0, 0
	local step = math.max(1, (w * h) // 4096)
	for i = 0, w * h - 1, step do
		local o = i * 4
		local alpha = buffer.readu8(buf, o + 3)
		sumR += buffer.readu8(buf, o) * alpha
		sumG += buffer.readu8(buf, o + 1) * alpha
		sumB += buffer.readu8(buf, o + 2) * alpha
		sumA += alpha
	end
	local tex = {
		buf = buf,
		w = w,
		h = h,
		avg = if sumA > 0 then Color3.new(sumR / sumA / 255, sumG / sumA / 255, sumB / sumA / 255) else Color3.new(1, 1, 1),
	}
	state.textureCache[uri] = tex
	return tex
end

-- Wrapping sample of a texture at (u, v) in tiles. spanU / spanV are how much of a tile one paint dot
-- covers: a dot covering several texels gets their average (no moiré), a smaller one is bilinear.
local function texel(tex: any, u: number, v: number, spanU: number, spanV: number): (Color3, number)
	local buf, w, h = tex.buf, tex.w, tex.h
	local cx = (u % 1) * w
	local cy = (v % 1) * h
	local kx = spanU * w
	local ky = spanV * h
	if kx <= 1.5 and ky <= 1.5 then
		local fx, fy = cx - 0.5, cy - 0.5
		local x0, y0 = math.floor(fx), math.floor(fy)
		local tx, ty = fx - x0, fy - y0
		local xa, xb = x0 % w, (x0 + 1) % w
		local ya, yb = y0 % h, (y0 + 1) % h
		local o00, o10 = (ya * w + xa) * 4, (ya * w + xb) * 4
		local o01, o11 = (yb * w + xa) * 4, (yb * w + xb) * 4
		local w00, w10, w01, w11 = (1 - tx) * (1 - ty), tx * (1 - ty), (1 - tx) * ty, tx * ty
		local r = buffer.readu8(buf, o00) * w00 + buffer.readu8(buf, o10) * w10 + buffer.readu8(buf, o01) * w01 + buffer.readu8(buf, o11) * w11
		local g = buffer.readu8(buf, o00 + 1) * w00 + buffer.readu8(buf, o10 + 1) * w10 + buffer.readu8(buf, o01 + 1) * w01 + buffer.readu8(buf, o11 + 1) * w11
		local b = buffer.readu8(buf, o00 + 2) * w00 + buffer.readu8(buf, o10 + 2) * w10 + buffer.readu8(buf, o01 + 2) * w01 + buffer.readu8(buf, o11 + 2) * w11
		local a = buffer.readu8(buf, o00 + 3) * w00 + buffer.readu8(buf, o10 + 3) * w10 + buffer.readu8(buf, o01 + 3) * w01 + buffer.readu8(buf, o11 + 3) * w11
		return Color3.new(r / 255, g / 255, b / 255), a / 255
	end
	-- box average over the dot's footprint, at most FILTER_TAPS² reads
	local taps = CONST.FILTER_TAPS
	local nx = math.clamp(math.ceil(kx), 1, taps)
	local ny = math.clamp(math.ceil(ky), 1, taps)
	local sx, sy = kx / nx, ky / ny
	local r, g, b, a = 0, 0, 0, 0
	for j = 0, ny - 1 do
		local y = math.floor(cy - ky / 2 + (j + 0.5) * sy) % h
		for i = 0, nx - 1 do
			local x = math.floor(cx - kx / 2 + (i + 0.5) * sx) % w
			local o = (y * w + x) * 4
			local alpha = buffer.readu8(buf, o + 3)
			r += buffer.readu8(buf, o) * alpha
			g += buffer.readu8(buf, o + 1) * alpha
			b += buffer.readu8(buf, o + 2) * alpha
			a += alpha
		end
	end
	if a <= 0 then
		return Color3.new(0, 0, 0), 0
	end
	return Color3.new(r / a / 255, g / a / 255, b / a / 255), a / (nx * ny * 255)
end

-- Which face of a part a world normal hit, and the decal-style (u, v) of the hit point on it.
local function faceUV(part: BasePart, position: Vector3, normal: Vector3): (Enum.NormalId, number, number, number, number)
	local localPos = part.CFrame:PointToObjectSpace(position)
	local n = part.CFrame:VectorToObjectSpace(normal)
	local s = part.Size
	local ax, ay, az = math.abs(n.X), math.abs(n.Y), math.abs(n.Z)
	if ax >= ay and ax >= az then
		if n.X > 0 then
			return Enum.NormalId.Right, (s.Z / 2 - localPos.Z) / s.Z, (s.Y / 2 - localPos.Y) / s.Y, s.Z, s.Y
		end
		return Enum.NormalId.Left, (localPos.Z + s.Z / 2) / s.Z, (s.Y / 2 - localPos.Y) / s.Y, s.Z, s.Y
	elseif ay >= az then
		if n.Y > 0 then
			return Enum.NormalId.Top, (localPos.X + s.X / 2) / s.X, (localPos.Z + s.Z / 2) / s.Z, s.X, s.Z
		end
		return Enum.NormalId.Bottom, (localPos.X + s.X / 2) / s.X, (s.Z / 2 - localPos.Z) / s.Z, s.X, s.Z
	end
	if n.Z > 0 then
		return Enum.NormalId.Back, (localPos.X + s.X / 2) / s.X, (s.Y / 2 - localPos.Y) / s.Y, s.X, s.Y
	end
	return Enum.NormalId.Front, (s.X / 2 - localPos.X) / s.X, (s.Y / 2 - localPos.Y) / s.Y, s.X, s.Y
end

local function meshTextureUri(part: BasePart): string?
	local surface = part:FindFirstChildOfClass("SurfaceAppearance")
	if surface then
		local ok, content = pcall(function()
			return (surface :: any).ColorMapContent
		end)
		if ok and content and content.Uri and content.Uri ~= "" then
			return content.Uri
		end
		local okId, id = pcall(function()
			return (surface :: any).ColorMap
		end)
		if okId and type(id) == "string" and id ~= "" then
			return id
		end
	end
	if part:IsA("MeshPart") then
		local ok, content = pcall(function()
			return part.TextureContent
		end)
		if ok and content and content.Uri and content.Uri ~= "" then
			return content.Uri
		end
		if part.TextureID ~= "" then
			return part.TextureID
		end
	end
	return nil
end

local function blend(a: Color3, b: Color3, t: number): Color3
	return a:Lerp(b, math.clamp(t, 0, 1))
end

-- The MaterialVariant a part renders with (its own, or the place's override for its base material),
-- as a sampled colour map plus how many studs one tile covers.
local function variantTexture(part: BasePart): any
	local material = part.Material
	local name = part.MaterialVariant
	if name == "" then
		local ok, override = pcall(MaterialService.GetBaseMaterialOverride, MaterialService, material)
		name = if ok and type(override) == "string" then override else ""
	end
	if name == "" then
		return nil
	end
	local key = `{material.Name}/{name}`
	local cached = state.variantCache[key]
	if cached ~= nil then
		return cached or nil
	end
	state.variantCache[key] = false
	local okVariant, variant = pcall(MaterialService.GetMaterialVariant, MaterialService, material, name)
	if not okVariant or not variant then
		return nil
	end
	local uri = nil
	local okContent, content = pcall(function()
		return (variant :: any).ColorMapContent
	end)
	if okContent and content and content.Uri and content.Uri ~= "" then
		uri = content.Uri
	elseif variant.ColorMap ~= "" then
		uri = variant.ColorMap
	end
	local tex = uri and loadTexture(uri)
	if not tex then
		return nil
	end
	local entry = { tex = tex, studs = math.max(variant.StudsPerTile, 0.01) }
	state.variantCache[key] = entry
	return entry
end

local function colourOf(hit: RaycastResult, footprint: number): Color3
	local inst = hit.Instance
	if inst:IsA("Terrain") then
		if hit.Material == Enum.Material.Water then
			return workspace.Terrain.WaterColor
		end
		local ok, colour = pcall(workspace.Terrain.GetMaterialColor, workspace.Terrain, hit.Material)
		return if ok then colour else Color3.new(0.5, 0.5, 0.5)
	end
	local part = inst :: BasePart
	local colour = part.Color
	local face, u, v, faceW, faceH
	-- custom materials (wallpaper, carpet…): the material texture's pixel at this spot, tinted by the
	-- part colour. Tiles every StudsPerTile studs across the face.
	local variant = variantTexture(part)
	if variant then
		face, u, v, faceW, faceH = faceUV(part, hit.Position, hit.Normal)
		local tu, tv = u * faceW, v * faceH
		if CONST.VARIANT_ORIGIN == "center" then
			tu, tv = (u - 0.5) * faceW, (v - 0.5) * faceH
		end
		local span = footprint / variant.studs
		local px = texel(variant.tex, tu / variant.studs, tv / variant.studs, span, span)
		colour = Color3.new(px.R * colour.R, px.G * colour.G, px.B * colour.B)
	end
	-- textured meshes / SurfaceAppearance: the texture's average, tinted by the part colour
	local uri = meshTextureUri(part)
	if uri then
		local tex = loadTexture(uri)
		if tex then
			local avg = tex.avg
			colour = Color3.new(avg.R * colour.R, avg.G * colour.G, avg.B * colour.B)
		end
	end
	-- decals / textures on the face we hit: the actual pixel
	local decals = state.decalCache[part]
	if decals == nil then
		decals = {}
		for _, child in part:GetChildren() do
			if child:IsA("Decal") then -- Texture is a Decal subclass
				table.insert(decals, child)
			end
		end
		state.decalCache[part] = decals
	end
	for _, child in decals do
		if not face then
			face, u, v, faceW, faceH = faceUV(part, hit.Position, hit.Normal)
		end
		if child.Face == face and child.Transparency < 0.95 then
			local tex = loadTexture(child.Texture)
			if tex then
				local u2, v2 = u, v
				local spanU, spanV = footprint / math.max(faceW, 0.01), footprint / math.max(faceH, 0.01)
				if child:IsA("Texture") then
					local t = child :: Texture
					local tileU, tileV = math.max(t.StudsPerTileU, 0.01), math.max(t.StudsPerTileV, 0.01)
					u2 = (u * faceW + t.OffsetStudsU) / tileU
					v2 = (v * faceH + t.OffsetStudsV) / tileV
					spanU, spanV = footprint / tileU, footprint / tileV
				end
				local px, alpha = texel(tex, u2, v2, spanU, spanV)
				local tint = child.Color3
				px = Color3.new(px.R * tint.R, px.G * tint.G, px.B * tint.B)
				colour = blend(colour, px, alpha * (1 - child.Transparency))
			end
		end
	end
	return colour
end

-- One RaycastParams for every ray; its ignore list is reset per sample.
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
local rayIgnore: { Instance } = {}

-- What a viewer looking along `direction` would see past `origin`, skipping your own body and anything
-- mostly see-through (glass, invisible walls). Other players count as background.
local function backgroundColour(origin: Vector3, direction: Vector3, character: Model, footprint: number): Color3
	table.clear(rayIgnore)
	rayIgnore[1] = character
	local remaining = CONST.RAY_LENGTH
	local from = origin
	for _ = 1, CONST.RAY_SKIP_LIMIT do
		rayParams.FilterDescendantsInstances = rayIgnore
		local hit = workspace:Raycast(from, direction * remaining, rayParams)
		if not hit then
			return CONST.SKY
		end
		local inst = hit.Instance
		if inst == workspace.Terrain or (inst :: BasePart).Transparency < CONST.SEE_THROUGH then
			return colourOf(hit, footprint)
		end
		table.insert(rayIgnore, inst)
		remaining -= hit.Distance
		from = hit.Position
	end
	return CONST.SKY
end

----------------------------------------------------------------------------------------------------
-- Camouflage
----------------------------------------------------------------------------------------------------
-- The wall you're pressed against: the closest near-vertical surface around your middle, if any.
local function findWall(character: Model): RaycastResult?
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return nil
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	local best: RaycastResult? = nil
	for i = 0, CONST.WALL_RAYS - 1 do
		local angle = i / CONST.WALL_RAYS * math.pi * 2
		for _, height in { 0, 1, -1 } do
			local origin = root.Position + Vector3.new(0, height, 0)
			local hit = workspace:Raycast(origin, Vector3.new(math.cos(angle), 0, math.sin(angle)) * CONST.WALL_RANGE, params)
			if hit and math.abs(hit.Normal.Y) < 0.5 and hit.Instance.Transparency < CONST.SEE_THROUGH and (best == nil or hit.Distance < best.Distance) then
				best = hit
			end
		end
	end
	return best
end

-- Writes what the camouflage was based on (camera, wall part, its material) so a screenshot of the
-- result can be lined up against it afterwards.
local function saveSnapshot(character: Model, wall: RaycastResult?)
	if type(writefile) ~= "function" then
		return
	end
	local camera = workspace.CurrentCamera
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local data: { [string]: any } = {
		time = os.time(),
		camera = { camera.CFrame:GetComponents() },
		fov = camera.FieldOfView,
		viewport = { camera.ViewportSize.X, camera.ViewportSize.Y },
		root = root and { root.CFrame:GetComponents() },
		origin = CONST.VARIANT_ORIGIN,
	}
	if wall then
		local part = wall.Instance :: BasePart
		data.wall = {
			name = part:GetFullName(),
			class = part.ClassName,
			cframe = { part.CFrame:GetComponents() },
			size = { part.Size.X, part.Size.Y, part.Size.Z },
			material = part.Material.Name,
			variant = part.MaterialVariant,
			hit = { wall.Position.X, wall.Position.Y, wall.Position.Z },
			normal = { wall.Normal.X, wall.Normal.Y, wall.Normal.Z },
		}
	end
	local ok, err = pcall(writefile, "chameleon_snapshot.json", HttpService:JSONEncode(data))
	if not ok then
		warn("[Camo] snapshot:", err)
	end
end

local function camouflage()
	local controller = findController()
	if not controller then
		error("couldn't find the game's painter (wait for the game to load)", 0)
	end
	local character = LocalPlayer.Character
	if not character then
		error("no character", 0)
	end
	local meshes = controller.getOwnPaintableUVMeshes(character)
	if #meshes == 0 then
		error("no paintable body (are you a hider?)", 0)
	end
	local grid = math.clamp(math.floor(Settings.Detail), 16, 256)
	table.clear(state.decalCache)
	setStatus("Reading your body…")
	local all = {}
	for _, mesh in meshes do
		local ctx = controller.meshContextByPart[mesh]
		local texW = ctx and ctx.Width or 512
		local list = bodySamples(controller, mesh, grid)
		for _, s in list do
			s.radius = math.max(1, (texW / grid) * CONST.RADIUS_SCALE)
			table.insert(all, s)
		end
	end
	if #all == 0 then
		error("found no paintable surface on your body", 0)
	end
	-- Against a wall: every spot copies the wall point straight behind it (what someone facing you sees,
	-- lined up exactly). In the open: every spot copies whatever is behind it along its own normal.
	local wall = findWall(character)
	saveSnapshot(character, wall)
	local wallDirection = wall and -wall.Normal
	setStatus(if wall then `Copying the wall behind you ({#all} spots)…` else `Looking around ({#all} spots)…`)
	local brightness = math.clamp(Settings.Brightness, 10, 200) / 100
	for i, s in all do
		-- start just inside the skin and look straight through the body
		local raw = if wallDirection
			then backgroundColour(s.pos, wallDirection, character, s.cell)
			else backgroundColour(s.pos + s.normal * 0.02, -s.normal, character, s.cell)
		s.colour = Color3.new(math.min(1, raw.R * brightness), math.min(1, raw.G * brightness), math.min(1, raw.B * brightness))
		if i % 150 == 0 then
			state.pendingProgress = i / #all * 0.5
			yieldMaybe()
		end
	end

	-- Paint through the game's own painter at the game's own pace: up to POINTS_PER_TICK points and
	-- STROKES_PER_TICK finished strokes per TICK. Each run of touching cells is its own stroke, so no
	-- client ever joins two far-apart cells with a line.
	local strokes = runs(all)
	local total = #all
	local sent = 0
	local strokeId: number? = nil
	local function nextStroke(): number
		controller.nextStrokeId = (tonumber(controller.nextStrokeId) or 0) + 1
		local id = controller.nextStrokeId
		controller.activeStrokeId = id
		controller.resetLocalStrokeSegment()
		return id
	end
	local function endStroke()
		if strokeId then
			pcall(controller.finishPendingUVStroke, strokeId)
			if controller.activeStrokeId == strokeId then
				controller.activeStrokeId = nil
			end
			controller.resetLocalStrokeSegment()
			strokeId = nil
		end
	end
	local ok, err = pcall(function()
		local runIndex, pointIndex = 1, 1
		while runIndex <= #strokes do
			if state.stop or not state.running then
				error("__STOPPED__", 0)
			end
			local points, ended = 0, 0
			while runIndex <= #strokes and points < CONST.POINTS_PER_TICK and ended < CONST.STROKES_PER_TICK do
				local run = strokes[runIndex]
				if pointIndex == 1 then
					strokeId = nextStroke()
				end
				local last = math.min(#run, pointIndex + CONST.POINTS_PER_TICK - points - 1)
				for i = pointIndex, last do
					local s = run[i]
					controller.drawLocalUVPaintPoint({ Part = s.part, UV = s.uv, FaceId = s.faceId }, s.colour, s.radius, strokeId)
				end
				points += last - pointIndex + 1
				sent += last - pointIndex + 1
				if last >= #run then
					endStroke()
					ended += 1
					runIndex += 1
					pointIndex = 1
				else
					pointIndex = last + 1
				end
			end
			state.pendingProgress = 0.5 + sent / total * 0.5
			setStatus(`Painting {sent}/{total}…`)
			task.wait(CONST.TICK)
		end
	end)
	endStroke()
	if not ok then
		error(err, 0)
	end
	return sent, #strokes
end

local function startCamo()
	if state.busy then
		return
	end
	state.busy = true
	state.stop = false
	state.pendingProgress = 0
	task.spawn(function()
		local t0 = os.clock()
		local ok, result, strokeCount = pcall(camouflage)
		if state.running then
			if ok then
				setStatus(`Camouflaged! {result} spots ({strokeCount} strokes) in {string.format("%.1f", os.clock() - t0)}s.`, true)
				state.pendingProgress = 1
			elseif result == "__STOPPED__" then
				setStatus("Stopped.")
			else
				warn("[Camo]", result)
				setStatus("Error: " .. tostring(result), false)
			end
		end
		state.busy = false
	end)
end

----------------------------------------------------------------------------------------------------
-- UI
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

local hostOk, host = pcall(function()
	return if type(gethui) == "function" then gethui() else CoreGui
end)
if not hostOk or not host then
	host = LocalPlayer:WaitForChild("PlayerGui")
end

local screen = give(create("ScreenGui", {
	Name = "ChameleonCamo",
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	DisplayOrder = 70,
	IgnoreGuiInset = true,
	Parent = host,
}))

local window = create("Frame", {
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -20, 0, 120),
	Size = UDim2.fromOffset(Theme.Width, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundColor3 = Theme.Bg,
	BorderSizePixel = 0,
	Active = true,
}, {
	create("UICorner", { CornerRadius = UDim.new(0, 10) }),
	create("UIStroke", { Color = Theme.Stroke, Thickness = 1 }),
	create("UIPadding", {
		PaddingLeft = UDim.new(0, 12),
		PaddingRight = UDim.new(0, 12),
		PaddingTop = UDim.new(0, 10),
		PaddingBottom = UDim.new(0, 12),
	}),
	create("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }),
})

local order = 0
local function nextOrder(): number
	order += 1
	return order
end

local title = create("TextLabel", {
	Size = UDim2.new(1, 0, 0, 20),
	BackgroundTransparency = 1,
	Text = "Auto Camouflage",
	TextColor3 = Theme.Text,
	FontFace = Theme.FontBold,
	TextSize = 15,
	TextXAlignment = Enum.TextXAlignment.Left,
	LayoutOrder = nextOrder(),
	Active = true,
	Parent = window,
})

local function Button(text: string, base: Color3, over: Color3, height: number): TextButton
	local button = create("TextButton", {
		Size = UDim2.new(1, 0, 0, height),
		BackgroundColor3 = base,
		AutoButtonColor = false,
		BorderSizePixel = 0,
		Text = text,
		TextColor3 = Theme.Text,
		FontFace = Theme.FontBold,
		TextSize = 14,
		LayoutOrder = nextOrder(),
		Parent = window,
	}, {
		create("UICorner", { CornerRadius = Theme.Corner }),
	})
	local active: Tween? = nil
	local function to(colour: Color3)
		if active then
			active:Cancel()
		end
		active = TweenService:Create(button, Theme.Tween, { BackgroundColor3 = colour })
		active:Play()
	end
	give(button.MouseEnter:Connect(function()
		to(over)
	end))
	give(button.MouseLeave:Connect(function()
		to(base)
	end))
	return button
end

local camoBtn = Button("Camouflage me  (C)", Theme.Accent, Theme.AccentHover, 40)

-- Number fields
local function NumberField(label: string, key: string, low: number, high: number)
	local row = create("Frame", {
		Size = UDim2.new(1, 0, 0, 26),
		BackgroundTransparency = 1,
		LayoutOrder = nextOrder(),
		Parent = window,
	}, {
		create("TextLabel", {
			Size = UDim2.new(0.6, 0, 1, 0),
			BackgroundTransparency = 1,
			Text = label,
			TextColor3 = Theme.SubText,
			FontFace = Theme.Font,
			TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Left,
		}),
	})
	local box = create("TextBox", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0.38, 0, 1, 0),
		BackgroundColor3 = Theme.Field,
		BorderSizePixel = 0,
		ClearTextOnFocus = false,
		Text = tostring(Settings[key]),
		TextColor3 = Theme.Text,
		FontFace = Theme.Font,
		TextSize = 13,
		Parent = row,
	}, {
		create("UICorner", { CornerRadius = Theme.Corner }),
	})
	give(box.FocusLost:Connect(function()
		local n = tonumber(box.Text)
		if n then
			Settings[key] = math.clamp(math.floor(n), low, high)
		end
		box.Text = tostring(Settings[key])
	end))
end
NumberField("Detail (cells per side)", "Detail", 16, 256)
NumberField("Brightness %", "Brightness", 10, 200)

local progressTrack = create("Frame", {
	Size = UDim2.new(1, 0, 0, 6),
	BackgroundColor3 = Theme.Field,
	BorderSizePixel = 0,
	LayoutOrder = nextOrder(),
	Parent = window,
}, {
	create("UICorner", { CornerRadius = UDim.new(1, 0) }),
})
local progressFill = create("Frame", {
	Size = UDim2.fromScale(0, 1),
	BackgroundColor3 = Theme.Accent,
	BorderSizePixel = 0,
	Parent = progressTrack,
}, {
	create("UICorner", { CornerRadius = UDim.new(1, 0) }),
})

local status = create("TextLabel", {
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1,
	Text = "Stand where you want to hide, then press Camouflage me.",
	TextColor3 = Theme.SubText,
	FontFace = Theme.Font,
	TextSize = 12,
	TextWrapped = true,
	TextXAlignment = Enum.TextXAlignment.Left,
	LayoutOrder = nextOrder(),
	Parent = window,
})

local stopBtn = Button("Stop", Theme.Field, Theme.FieldHover, 26)
stopBtn.TextSize = 12
-- Seeker section
create("TextLabel", {
	Size = UDim2.new(1, 0, 0, 18),
	BackgroundTransparency = 1,
	Text = "Seeker",
	TextColor3 = Theme.Text,
	FontFace = Theme.FontBold,
	TextSize = 13,
	TextXAlignment = Enum.TextXAlignment.Left,
	LayoutOrder = nextOrder(),
	Parent = window,
})

local toggleRenderers: { () -> () } = {}
function state.refreshToggles()
	for _, render in toggleRenderers do
		render()
	end
end
local function Toggle(label: string, key: string)
	local button = Button("", Theme.Field, Theme.FieldHover, 26)
	button.TextSize = 12
	local function render()
		local on = Settings[key] == true
		button.Text = `{label}: {if on then "ON" else "OFF"}`
		button.TextColor3 = if on then Theme.Accent else Theme.SubText
	end
	render()
	table.insert(toggleRenderers, render)
	give(button.Activated:Connect(function()
		Settings[key] = not Settings[key]
		render()
	end))
end
Toggle("Show enemies (G)", "ShowEnemies")
Toggle("Rapid fire (hold click)", "RapidFire")
NumberField("Shot delay (ms)", "ShotDelay", 100, 2000)
Toggle("Shoot through walls", "Wallbang")
NumberField("Aim radius (px)", "AimRadius", 20, 2000)

local seekerInfo = create("TextLabel", {
	Size = UDim2.new(1, 0, 0, 16),
	BackgroundTransparency = 1,
	Text = "",
	TextColor3 = Theme.SubText,
	FontFace = Theme.Font,
	TextSize = 12,
	TextXAlignment = Enum.TextXAlignment.Left,
	LayoutOrder = nextOrder(),
	Parent = window,
})

local closeBtn = Button("Close", Theme.Field, Theme.FieldHover, 24)
closeBtn.TextSize = 12

window.Parent = screen

----------------------------------------------------------------------------------------------------
-- Seeker: enemy highlights, rapid fire, through-wall shots
--   The shotgun fires FireShot:FireServer(cameraOrigin, aimDirection, trailStart) and the server traces
--   the shot from that origin, which may sit up to MaxCameraOriginDistance (18) studs from you. A shot
--   "through" a wall starts on the far side of it, as close to the enemy as that allows, aimed at them.
----------------------------------------------------------------------------------------------------
local Seeker = {
	highlights = {} :: { [Player]: Highlight },
	enemyCount = 0,
	sent = 0, -- rapid shots sent this session
	confirmed = 0, -- shots of ours the server broadcast (accepted)
	fireRemote = nil :: RemoteEvent?,
	tool = nil :: Tool?,
	triggerHeld = false,
	fireClock = 0,
	espClock = 0,
}

function Seeker.roleOf(player: Player): string
	local values = player:FindFirstChild("RoundValues")
	local role = values and values:FindFirstChild("Role")
	return if role and role:IsA("StringValue") then role.Value else ""
end

function Seeker.isEnemy(player: Player): boolean
	if player == LocalPlayer then
		return false
	end
	local theirs = Seeker.roleOf(player)
	if theirs == "" then
		return false
	end
	local values = player:FindFirstChild("RoundValues")
	local eliminated = values and values:FindFirstChild("Eliminated")
	if eliminated and eliminated:IsA("BoolValue") and eliminated.Value then
		return false
	end
	local mine = Seeker.roleOf(LocalPlayer)
	if mine == "Seeker" or mine == "" then
		return theirs ~= "Seeker" -- seekers (and spectators) see the hiders
	end
	return theirs == "Seeker" -- hiders see the seekers
end

-- The point to shoot at on an enemy: the middle of their body mesh.
function Seeker.bodyPoint(character: Model): Vector3?
	local mesh = character:FindFirstChild("UVMesh", true)
	if mesh and mesh:IsA("BasePart") then
		return mesh.Position
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root.Position else nil
end

-- Enemy closest to the crosshair (within AimRadius px), walls ignored.
function Seeker.pickTarget(): Vector3?
	local camera = workspace.CurrentCamera
	local centre = camera.ViewportSize / 2
	local best, bestDist = nil, Settings.AimRadius
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character and Seeker.isEnemy(player) then
			local point = Seeker.bodyPoint(character)
			if point then
				local screen = camera:WorldToViewportPoint(point)
				if screen.Z > 0 then
					local d = (Vector2.new(screen.X, screen.Y) - centre).Magnitude
					if d < bestDist then
						best, bestDist = point, d
					end
				end
			end
		end
	end
	return best
end

-- Shot arguments that start past any wall, as close to the target as the server allows.
function Seeker.wallbangArgs(target: Vector3): (Vector3?, Vector3?)
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		return nil
	end
	local anchor = root.Position + Vector3.new(0, 1.5, 0)
	local offset = target - anchor
	local distance = offset.Magnitude
	if distance < 1e-3 then
		return nil
	end
	local reach = math.max(0, math.min(distance - 2, CONST.MAX_ORIGIN - 1))
	local origin = anchor + offset.Unit * reach
	return origin, (target - origin).Unit
end

-- Rewrites the game's own FireShot calls when through-wall shots are on (see the namecall hook below).
function Seeker.rewrite(remote: Instance, origin: any, direction: any, trail: any): (Vector3?, Vector3?, any)
	if not rawequal(remote, Seeker.fireRemote) or not Settings.Wallbang then
		return nil
	end
	local target = Seeker.pickTarget()
	if not target then
		return nil
	end
	local newOrigin, newDirection = Seeker.wallbangArgs(target)
	if not newOrigin then
		return nil
	end
	return newOrigin, newDirection, trail
end

function Seeker.fireOnce()
	local remote = Seeker.fireRemote
	local tool = Seeker.tool
	if not (remote and tool) then
		return
	end
	local camera = workspace.CurrentCamera
	local viewport = camera.ViewportSize
	local ray = camera:ViewportPointToRay(viewport.X / 2, viewport.Y / 2)
	local origin, direction = ray.Origin, ray.Direction.Unit
	if Settings.Wallbang then
		local target = Seeker.pickTarget()
		if target then
			local o, d = Seeker.wallbangArgs(target)
			if o then
				origin, direction = o, d
			end
		end
	end
	local handle = tool:FindFirstChild("Handle")
	local trail = if handle and handle:IsA("BasePart") then handle.Position else origin
	remote:FireServer(origin, direction, trail)
	Seeker.sent += 1
end

-- Keeps one Highlight per enemy (reused, never more than the players in the server).
function Seeker.updateHighlights()
	local count = 0
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local want = Settings.ShowEnemies and character ~= nil and Seeker.isEnemy(player)
		local highlight = Seeker.highlights[player]
		if want then
			count += 1
			if not highlight then
				highlight = create("Highlight", {
					Name = "EnemyHighlight",
					FillColor = CONST.ENEMY_FILL,
					FillTransparency = 0.45,
					OutlineColor = CONST.ENEMY_OUTLINE,
					OutlineTransparency = 0,
					DepthMode = Enum.HighlightDepthMode.AlwaysOnTop,
					Parent = screen,
				})
				Seeker.highlights[player] = highlight
			end
			if highlight.Adornee ~= character then
				highlight.Adornee = character
			end
			if not highlight.Enabled then
				highlight.Enabled = true
			end
		elseif highlight and highlight.Enabled then
			highlight.Enabled = false
		end
	end
	Seeker.enemyCount = count
end

function Seeker.releasePlayer(player: Player)
	local highlight = Seeker.highlights[player]
	if highlight then
		highlight:Destroy()
		Seeker.highlights[player] = nil
	end
end

function Seeker.refreshTool()
	local character = LocalPlayer.Character
	local tool = character and character:FindFirstChildOfClass("Tool")
	local folder = tool and tool:FindFirstChild("ShotgunRemotes")
	local remote = folder and folder:FindFirstChild("FireShot")
	if remote and remote:IsA("RemoteEvent") then
		Seeker.tool, Seeker.fireRemote = tool, remote
	else
		Seeker.tool, Seeker.fireRemote = nil, nil
	end
end


-- Calling the game's code can leave a thread unable to touch our UI until it yields, so the paint
-- thread only writes into state; this connection applies it (change-only).
local shownProgress = -1
give(RunService.Heartbeat:Connect(function()
	local pending = state.pendingStatus
	if pending then
		state.pendingStatus = nil
		if status.Text ~= pending.text then
			status.Text = pending.text
		end
		if status.TextColor3 ~= pending.color then
			status.TextColor3 = pending.color
		end
	end
	local progress = state.pendingProgress
	if progress and math.abs(progress - shownProgress) > 0.004 then
		shownProgress = progress
		progressFill.Size = UDim2.fromScale(math.clamp(progress, 0, 1), 1)
	end
end))

-- Seeker loop: highlights + tool lookup are throttled; rapid fire runs on an accumulator so the rate
-- is the same at any frame rate.
local shownSeekerText = ""
give(RunService.Heartbeat:Connect(function(dt: number)
	Seeker.espClock += dt
	if Seeker.espClock >= CONST.ESP_INTERVAL then
		Seeker.espClock = 0
		Seeker.refreshTool()
		Seeker.updateHighlights()
		local text = `Role: {if Seeker.roleOf(LocalPlayer) == "" then "none" else Seeker.roleOf(LocalPlayer)}  ·  enemies: {Seeker.enemyCount}{if Seeker.fireRemote then `  ·  shots ok {Seeker.confirmed}` else ""}`
		if text ~= shownSeekerText then
			shownSeekerText = text
			seekerInfo.Text = text
		end
	end
	if Settings.RapidFire and Seeker.triggerHeld and Seeker.fireRemote then
		-- at most one shot per frame, so a hitch never dumps a burst
		local interval = math.clamp(Settings.ShotDelay, 100, 2000) / 1000
		Seeker.fireClock = math.min(Seeker.fireClock + dt, interval)
		if Seeker.fireClock >= interval then
			Seeker.fireClock -= interval
			Seeker.fireOnce()
		end
	else
		Seeker.fireClock = 0
	end
end))
give(Players.PlayerRemoving:Connect(Seeker.releasePlayer))

-- The server broadcasts every accepted shot as ShotgunFireFX(player, tool, hitPos, …). The game hides
-- the shooter's own copy (its local effects already played), but rapid shots have no local effects,
-- so show them, and count ours as confirmed.
do
	local globals = ReplicatedStorage:FindFirstChild("ShotgunGlobalRemotes")
	local fx = globals and globals:FindFirstChild("ShotgunFireFX")
	if fx and fx:IsA("RemoteEvent") then
		give(fx.OnClientEvent:Connect(function(player: any)
			if player == LocalPlayer then
				Seeker.confirmed += 1
			end
		end))
	end
	local system = ReplicatedStorage:FindFirstChild("ShotgunSystem")
	local module = system and system:FindFirstChild("SETTINGS")
	if module and module:IsA("ModuleScript") then
		local ok, shared = pcall(require, module)
		if ok and type(shared) == "table" then
			Seeker.sharedSettings = shared
			Seeker.savedIgnoreOwnFx = shared.IgnoreGlobalFireFXForLocalShooter
			shared.IgnoreGlobalFireFXForLocalShooter = false
		end
	end
end

-- Through-wall shots for the game's own clicks: one namecall hook per session (kept across re-runs)
-- that forwards FireServer calls to whichever script instance is current.
genv.__CHAMELEON_SHOT_REWRITE = Seeker.rewrite
if not genv.__CHAMELEON_NAMECALL_HOOKED then
	if type(hookmetamethod) == "function" and type(getnamecallmethod) == "function" then
		local isOwnCall = if type(checkcaller) == "function" then checkcaller else function()
			return false
		end
		local original
		original = hookmetamethod(game, "__namecall", function(self, ...)
			local rewrite = genv.__CHAMELEON_SHOT_REWRITE
			if rewrite and not isOwnCall() and getnamecallmethod() == "FireServer" then
				local ok, origin, direction, trail = pcall(rewrite, self, ...)
				if ok and origin then
					return original(self, origin, direction, trail)
				end
			end
			return original(self, ...)
		end)
		genv.__CHAMELEON_NAMECALL_HOOKED = true
	else
		warn("[Camo] no hookmetamethod: through-wall shots only work with rapid fire")
	end
end

give(camoBtn.Activated:Connect(startCamo))
give(stopBtn.Activated:Connect(function()
	state.stop = true
end))

-- Dragging by the title
local drag = { active = false, startMouse = Vector2.zero, startPos = UDim2.new() }
give(title.InputBegan:Connect(function(input: InputObject)
	local t = input.UserInputType
	if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
		drag.active = true
		drag.startMouse = Vector2.new(input.Position.X, input.Position.Y)
		drag.startPos = window.Position
	end
end))
give(UserInputService.InputChanged:Connect(function(input: InputObject)
	if not drag.active then
		return
	end
	local t = input.UserInputType
	if t ~= Enum.UserInputType.MouseMovement and t ~= Enum.UserInputType.Touch then
		return
	end
	local delta = Vector2.new(input.Position.X, input.Position.Y) - drag.startMouse
	local start = drag.startPos
	window.Position = UDim2.new(start.X.Scale, start.X.Offset + delta.X, start.Y.Scale, start.Y.Offset + delta.Y)
end))
give(UserInputService.InputEnded:Connect(function(input: InputObject)
	local t = input.UserInputType
	if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
		drag.active = false
	end
	if t == Enum.UserInputType.MouseButton1 then
		Seeker.triggerHeld = false
	end
end))

-- Keys (ignored while typing): C camouflages, G toggles enemy highlights, K hides the window.
give(UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	-- The shotgun binds its trigger through ContextActionService, which marks clicks as processed, so
	-- the trigger is read before the gameProcessed check (but never while typing).
	if input.UserInputType == Enum.UserInputType.MouseButton1 and not UserInputService:GetFocusedTextBox() then
		Seeker.triggerHeld = true
		Seeker.fireClock = 1 -- clamped to one interval: the first rapid shot goes out next frame
		return
	end
	if gameProcessed then
		return
	end
	if input.KeyCode == CONST.ESP_KEY then
		Settings.ShowEnemies = not Settings.ShowEnemies
		state.refreshToggles()
	elseif input.KeyCode == CONST.PAINT_KEY then
		startCamo()
	elseif input.KeyCode == CONST.TOGGLE_KEY then
		window.Visible = not window.Visible
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
	state.stop = true
	if genv.__CHAMELEON_SHOT_REWRITE == Seeker.rewrite then
		genv.__CHAMELEON_SHOT_REWRITE = nil
	end
	for player in Seeker.highlights do
		pcall(Seeker.releasePlayer, player)
	end
	if Seeker.sharedSettings then
		Seeker.sharedSettings.IgnoreGlobalFireFXForLocalShooter = Seeker.savedIgnoreOwnFx
	end
	-- A thread that has just run the game's code can't touch Instances until it yields, so anything
	-- that fails here is released again from a fresh thread a frame later.
	local leftovers = {}
	for i = #tasks, 1, -1 do
		local item = tasks[i]
		local ok = pcall(function()
			if typeof(item) == "RBXScriptConnection" then
				item:Disconnect()
			elseif typeof(item) == "Instance" then
				item:Destroy()
			end
		end)
		if not ok then
			table.insert(leftovers, item)
		end
	end
	table.clear(tasks)
	if #leftovers > 0 then
		task.spawn(function()
			task.wait()
			for _, item in leftovers do
				local ok, err = pcall(function()
					if typeof(item) == "RBXScriptConnection" then
						item:Disconnect()
					else
						item:Destroy()
					end
				end)
				if not ok then
					warn("[Camo] cleanup:", err)
				end
			end
		end)
	end
	table.clear(state.textureCache)
	table.clear(state.decalCache)
	table.clear(state.variantCache)
	if genv.__CHAMELEON_PAINT == controller then
		genv.__CHAMELEON_PAINT = nil
	end
end
controller.Settings = Settings
controller.Seeker = Seeker
controller.Camouflage = startCamo
function controller.Status(): (string, boolean)
	return status.Text, state.busy
end
give(closeBtn.Activated:Connect(controller.Cleanup))
genv.__CHAMELEON_PAINT = controller
