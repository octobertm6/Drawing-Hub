-- WELDING Bricklayer — Brick Launcher
-- Spawns a piece, grabs it with the game's own grab system and drives it under any player's feet
-- (you ride a brick, other players get a Steel Plate). It follows them, then rises at the chosen speed
-- and lets go, so they keep flying up.
--
-- How it works (verified in-game, PlaceId 100877684758792, 2026-10-12):
--   * BrickBuilderEvent:FireServer("Spawn", position, normal) makes a brick owned by you in workspace.Bricks.
--   * "GrabStart"(brick, cframe, grabLocal) works from any distance; the server adds DragAttachment +
--     DragAlignPosition (MaxForce 1e7) and marks it ClientDriven, so this client simulates the brick and
--     moves it by setting DragAlignPosition.Position. The grab only stays alive while "GrabMove" keeps
--     arriving (the game sends it every 0.125 s), so we send it every GRAB_KEEPALIVE seconds.
--   * Character legs don't collide (R15), but a humanoid stands on whatever is under it, so a brick rising
--     under someone's feet carries them up with it; stopping it suddenly launches them.

if not game:IsLoaded() then
	game.Loaded:Wait()
end

----------------------------------------------------------------------------------------------------
-- Re-execution guard
----------------------------------------------------------------------------------------------------
local genv: any = if type(getgenv) == "function" then getgenv() else _G
if genv.__BRICK_LAUNCHER and type(genv.__BRICK_LAUNCHER.Cleanup) == "function" then
	pcall(genv.__BRICK_LAUNCHER.Cleanup)
end

----------------------------------------------------------------------------------------------------
-- Services
----------------------------------------------------------------------------------------------------
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CoreGui = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer
local BrickEvent = ReplicatedStorage:WaitForChild("BrickBuilderEvent", 30) :: RemoteEvent
local BricksFolder = workspace:WaitForChild("Bricks", 30)
if not (BrickEvent and BricksFolder) then
	error("[BrickLauncher] this isn't WELDING Bricklayer (no BrickBuilderEvent / Bricks)")
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
	Accent = Color3.fromRGB(255, 140, 66),
	AccentHover = Color3.fromRGB(255, 166, 107),
	Selected = Color3.fromRGB(70, 110, 190),
	Danger = Color3.fromRGB(226, 72, 84),
	Good = Color3.fromRGB(90, 200, 120),
	Font = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Medium),
	FontBold = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold),
	Corner = UDim.new(0, 6),
	Width = 260,
	Tween = TweenInfo.new(0.14, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
})

local CONST = table.freeze({
	GRAB_KEEPALIVE = 0.1, -- seconds between GrabMove packets (the game itself uses 0.125)
	GRAB_TIMEOUT = 5, -- seconds to keep asking for the grab (the server ignores GrabStart for a moment
	-- right after a spawn / release)
	GRAB_RETRY = 0.25, -- seconds between GrabStart requests
	GRAB_RANGE = 60, -- only reuse bricks this close to you (85 studs worked, 219 didn't)
	VOID_SPEED = 4000, -- studs/s a piece is thrown down when deleting
	VOID_TIMEOUT = 3, -- seconds per piece before giving up on it
	SINK_TARGET_Y = -3000, -- where the drag aims (far below FallenPartsDestroyHeight = -500)
	SINK_RELEASE_Y = -60, -- let go once it's this far down: it's falling fast and the server finishes it
	HOP_OFFSET = Vector3.new(0, 4, 4), -- where we stand next to a far piece while grabbing it
	DELETE_PASSES = 2,
	OWNED_AGE = 0.1, -- ReceiveAge below this = our client is simulating the piece
	SINK_ALL_TIME = 1.2, -- seconds to throw owned pieces through the floor
	ORBIT_KEY = Enum.KeyCode.O,
	ORBIT_PER_RING = 12, -- pieces per ring before starting the next (wider, higher) ring
	ORBIT_RING_GAP = 4, -- studs between rings
	ORBIT_GAIN = 12, -- how hard pieces are pulled onto their slot (velocity = gap x gain)
	ORBIT_MAX_SPEED = 500,
	ORBIT_SPAWN_TIMEOUT = 1.2,
	ORBIT_SPAWN_GAP = 0.25, -- seconds between spawn attempts
	SPAWN_TYPE_TRIES = 3, -- refused spawns of one item type before moving on to the next type
	SPAWN_GIVE_UP = 30, -- refusals in a row (every type, several times) = the server's limit
	SPAWN_RETRY_LATER = 10, -- seconds to wait before trying again once the limit is hit
	COLLECT_SCAN = 0.5, -- seconds between scans for loose parts to bring
	BRING_MAX_SPEED = 20, -- parts moving faster than this (flung about) aren't picked up
	LOST_GRACE = 2.5, -- seconds a collected part may belong to someone else before we let it go
	PASS_SETTLE = 0.6, -- seconds for released pieces to finish falling before re-checking
	CONFIRM_TIME = 3, -- seconds the "click again to confirm" state of the delete button lasts
	SPAWN_TIMEOUT = 3,
	APPROACH_TIME = 0.6, -- seconds parked under the feet before rising
	APPROACH_MAX = 4, -- give up approaching after this long (target unreachable)
	BOOST_VELOCITY = 1.5, -- MaxVelocity = speed x this, so the brick can keep up with the climb
	TOGGLE_KEY = Enum.KeyCode.RightShift,
	LAUNCH_KEY = Enum.KeyCode.L,
	LIST_HEIGHT = 150,
})

local Settings = {
	Speed = 120, -- studs per second while rising
	Time = 1.5, -- seconds of rising before letting go
	OrbitRadius = 10, -- studs from you (extra rings sit further out)
	OrbitSpeed = 4, -- radians per second around you (x radius = studs per second)
	OrbitSpin = 80, -- how fast each piece spins (radians per second); fast spin flings harder
	BringAll = true, -- also pull anyone's non-cemented parts lying near you into the orbit
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
	target = LocalPlayer :: Player?,
	job = nil :: thread?,
	stop = false,
	pieces = {} :: { [string]: BasePart }, -- launcher piece per kind, reused between launches
	pendingStatus = nil :: any,
	spawnBusy = false,
	orbitOn = false,
	orbit = {} :: { BasePart }, -- pieces circling us
	orbitSet = {} :: { [BasePart]: boolean },
	orbitGen = 0,
	orbitAngle = 0,
	spawnedSet = {} :: { [BasePart]: boolean }, -- orbit pieces we spawned ourselves (sent to the void on off)
	assemblyParts = {} :: { [BasePart]: { BasePart } }, -- parts of each orbit assembly (by root)
}

----------------------------------------------------------------------------------------------------
-- Pieces: a brick lifts you; other players get the big Steel Plate (8 x 5 studs), which is much
-- easier to get under someone's feet. Both are grabbed the same way.
----------------------------------------------------------------------------------------------------
type PieceKind = { name: string, folder: Instance, spawn: (Vector3, Vector3) -> (), isOurs: (Instance) -> boolean }

local PlacedItems = workspace:WaitForChild("PlacedItems", 10)
local KINDS: { [string]: PieceKind } = {
	Brick = {
		name = "brick",
		folder = BricksFolder,
		spawn = function(position, normal)
			BrickEvent:FireServer("Spawn", position, normal)
		end,
		isOurs = function(piece)
			return piece:GetAttribute("IsBrick") == true
		end,
	},
	Plate = {
		name = "steel plate",
		folder = PlacedItems or BricksFolder,
		spawn = function(position, normal)
			BrickEvent:FireServer("SpawnItem", "Steel Plate", position, normal)
		end,
		isOurs = function(piece)
			return piece:GetAttribute("ItemId") == "Steel Plate"
		end,
	},
}

local function ownsPiece(kind: PieceKind, piece: Instance?): boolean
	return piece ~= nil
		and piece.Parent == kind.folder
		and piece:IsA("BasePart")
		and piece:GetAttribute("Owner") == LocalPlayer.UserId
		and kind.isOurs(piece)
end

local function rootOf(player: Player): (BasePart?, Humanoid?)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if root and root:IsA("BasePart") and humanoid and humanoid.Health > 0 then
		return root, humanoid
	end
	return nil, nil
end

-- A loose piece of ours (not anchored, not glued / cemented into a build) close enough to grab.
local function looseAndNear(kind: PieceKind, piece: Instance?, from: Vector3): boolean
	return ownsPiece(kind, piece)
		and not (piece :: BasePart).Anchored
		and (piece :: BasePart):FindFirstChild("Glue") == nil
		and #(piece :: BasePart):GetJoints() == 0
		and ((piece :: BasePart).Position - from).Magnitude <= CONST.GRAB_RANGE
end

-- Spawns one piece on the ground at `offset` from us and returns it once it replicates. Spawns are
-- serialised (the launcher and the orbit both spawn) so each caller gets its own piece. The server
-- accepts about one spawn a second; a refused spawn just times out.
local function spawnPiece(kindName: string, offset: Vector3, timeout: number): BasePart?
	local kind = KINDS[kindName]
	while state.spawnBusy and state.running do
		task.wait()
	end
	local root = rootOf(LocalPlayer)
	if not root or not state.running then
		return nil
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { LocalPlayer.Character :: Instance }
	local hit = workspace:Raycast(root.Position + offset + Vector3.new(0, 4, 0), Vector3.new(0, -60, 0), params)
	if not hit then
		return nil
	end
	state.spawnBusy = true
	local spawned: BasePart? = nil
	local conn = kind.folder.ChildAdded:Connect(function(child)
		-- Owner / ItemId are set on the server before the piece replicates
		if spawned == nil and ownsPiece(kind, child) then
			spawned = child :: BasePart
		end
	end)
	kind.spawn(hit.Position, hit.Normal)
	local deadline = os.clock() + timeout
	while spawned == nil and os.clock() < deadline do
		task.wait()
	end
	conn:Disconnect()
	state.spawnBusy = false
	return spawned
end

-- The launcher piece of this kind: reuse the last one if it's still close, else spawn one next to us.
local function getPiece(kindName: string): BasePart?
	local kind = KINDS[kindName]
	local root = rootOf(LocalPlayer)
	if not root then
		return nil
	end
	local cache = genv.__BRICK_LAUNCHER_PIECES or {}
	genv.__BRICK_LAUNCHER_PIECES = cache
	local piece = state.pieces[kindName] or cache[kindName]
	if looseAndNear(kind, piece, root.Position) and not state.orbitSet[piece] then
		state.pieces[kindName] = piece
		return piece
	end
	local spawned = spawnPiece(kindName, root.CFrame.LookVector * 5, CONST.SPAWN_TIMEOUT)
	if spawned then
		state.pieces[kindName] = spawned
		cache[kindName] = spawned
	end
	return spawned
end

local function grab(brick: BasePart): AlignPosition?
	local existing = brick:FindFirstChild("DragAlignPosition")
	if existing and existing:IsA("AlignPosition") then
		return existing
	end
	local deadline = os.clock() + CONST.GRAB_TIMEOUT
	local lastAsk = -math.huge
	while os.clock() < deadline and brick.Parent do
		local ap = brick:FindFirstChild("DragAlignPosition")
		if ap and ap:IsA("AlignPosition") then
			return ap
		end
		if os.clock() - lastAsk >= CONST.GRAB_RETRY then
			lastAsk = os.clock()
			BrickEvent:FireServer("GrabStart", brick, brick.CFrame, Vector3.zero)
		end
		task.wait()
	end
	return nil
end

local function release()
	pcall(BrickEvent.FireServer, BrickEvent, "GrabEnd")
end

----------------------------------------------------------------------------------------------------
-- Launch
----------------------------------------------------------------------------------------------------
local function setStatus(text: string, color: Color3?)
	state.pendingStatus = { text = text, color = color or Theme.SubText }
end

-- Sends a piece we're holding into the void. While held our client simulates it, so we turn its
-- collision off (on our side), aim the drag far below the map and give it a big downward speed. As
-- soon as it's well below the floor we let go: the server carries on the fall and Roblox deletes it
-- under FallenPartsDestroyHeight, for everyone. Returns once it's gone, falling, or timed out.
local function sinkHeld(piece: BasePart)
	local deadline = os.clock() + CONST.VOID_TIMEOUT
	local lastSend = 0
	while piece.Parent and os.clock() < deadline and state.running do
		local ap = piece:FindFirstChild("DragAlignPosition") :: AlignPosition?
		if not ap then
			break -- grab ended (server or someone else); nothing more we can do with it
		end
		local target = Vector3.new(piece.Position.X, CONST.SINK_TARGET_Y, piece.Position.Z)
		piece.CanCollide = false
		ap.MaxVelocity = CONST.VOID_SPEED
		ap.Position = target
		piece.AssemblyLinearVelocity = Vector3.new(0, -CONST.VOID_SPEED, 0)
		if piece.Position.Y < CONST.SINK_RELEASE_Y then
			break -- falling fast under the floor: the server finishes it off
		end
		if os.clock() - lastSend >= CONST.GRAB_KEEPALIVE then
			lastSend = os.clock()
			-- keep-alive only: our client drives the piece, so tell the server a harmless spot near
			-- us (a target thousands of studs away makes it drop the grab)
			local root = rootOf(LocalPlayer)
			BrickEvent:FireServer("GrabMove", if root then root.Position else piece.Position, 0, nil)
		end
		RunService.Heartbeat:Wait()
	end
	release()
end

local function footY(root: BasePart, humanoid: Humanoid): number
	return root.Position.Y - humanoid.HipHeight - root.Size.Y / 2
end

local function launch(player: Player)
	local root, humanoid = rootOf(player)
	if not (root and humanoid) then
		error(player.Name .. " has no character right now", 0)
	end
	-- you ride a brick; everyone else gets the big steel plate
	local kindName = if player == LocalPlayer then "Brick" else "Plate"
	local pieceName = KINDS[kindName].name
	setStatus(`Getting a {pieceName}…`)
	local brick = getPiece(kindName)
	if not brick then
		error(`couldn't spawn a {pieceName} (stand on something and try again)`, 0)
	end
	local ap = grab(brick)
	if not ap then
		error(`the game didn't let us grab the {pieceName}`, 0)
	end
	ap.MaxVelocity = math.max(ap.MaxVelocity, Settings.Speed * CONST.BOOST_VELOCITY)
	local half = brick.Size.Y / 2
	local orientation = brick:FindFirstChild("DragAlignOrientation") :: AlignOrientation?

	local phase, phaseStart, lastSend = "approach", os.clock(), 0
	local riseFrom = 0
	local done = false
	local conn: RBXScriptConnection
	conn = RunService.Heartbeat:Connect(function()
		if state.stop or not state.running then
			done = true
			return
		end
		local r, h = rootOf(player)
		local a = brick:FindFirstChild("DragAlignPosition") :: AlignPosition?
		if not (r and h and a and brick.Parent) then
			done = true
			return
		end
		local now = os.clock()
		local feet = footY(r, h)
		local target: Vector3
		if phase == "approach" then
			-- park flat under their feet, following them
			target = Vector3.new(r.Position.X, feet - half, r.Position.Z)
			local under = math.abs(brick.Position.X - r.Position.X) < 1.5 and math.abs(brick.Position.Z - r.Position.Z) < 1.5
			if (under and now - phaseStart >= CONST.APPROACH_TIME) or now - phaseStart >= CONST.APPROACH_MAX then
				phase, phaseStart, riseFrom = "rise", now, feet
			end
		else
			-- rise at Settings.Speed from where they stood (time-based, so it can't run away)
			local t = now - phaseStart
			target = Vector3.new(r.Position.X, riseFrom - half + Settings.Speed * t, r.Position.Z)
			if t >= Settings.Time then
				done = true
				return
			end
		end
		a.Position = target
		if orientation and orientation.Parent then
			orientation.CFrame = CFrame.identity
		end
		if now - lastSend >= CONST.GRAB_KEEPALIVE then
			lastSend = now
			BrickEvent:FireServer("GrabMove", target, 0, nil)
		end
		setStatus(if phase == "approach" then `Moving under {player.DisplayName}…` else `Launching {player.DisplayName}!`, Theme.Accent)
	end)
	while not done do
		task.wait()
	end
	conn:Disconnect()
	-- Yanking the piece away mid-climb is what launches them (they keep their upward speed), and
	-- dropping it straight into the void deletes it so it isn't left lying around.
	if brick.Parent and brick:FindFirstChild("DragAlignPosition") then
		sinkHeld(brick)
	else
		release()
	end
	state.pieces[kindName] = nil
end

local function startLaunch()
	if state.job then
		return
	end
	local player = state.target
	if not (player and player.Parent) then
		setStatus("Pick a player first.", Theme.Danger)
		return
	end
	state.stop = false
	state.job = task.spawn(function()
		local ok, err = pcall(launch, player)
		if state.running then
			if not ok then
				setStatus("Error: " .. tostring(err), Theme.Danger)
			elseif state.stop then
				setStatus("Stopped.")
			else
				setStatus(`Launched {player.DisplayName}.`, Theme.Good)
			end
		end
		state.job = nil
	end)
end

----------------------------------------------------------------------------------------------------
-- Delete my loose pieces. Each loose piece of ours (brick or item that isn't cemented / welded /
-- anchored) is grabbed, made non-colliding on our side (we simulate it while it's held) and driven
-- below workspace.FallenPartsDestroyHeight, where Roblox destroys it for everyone. Cemented pieces
-- refuse to be grabbed; only the game's paid hammer can break those.
----------------------------------------------------------------------------------------------------
local function looseOwnPieces(): ({ BasePart }, number)
	local loose, fixed = {}, 0
	for _, folder in { BricksFolder, PlacedItems } do
		if folder then
			for _, piece in folder:GetChildren() do
				if piece:IsA("BasePart") and piece:GetAttribute("Owner") == LocalPlayer.UserId then
					local held = piece:GetAttribute("GrabbedBy")
					if piece.Anchored or #piece:GetJoints() > 0 or (held and held ~= LocalPlayer.UserId) then
						fixed += 1
					else
						table.insert(loose, piece)
					end
				end
			end
		end
	end
	return loose, fixed
end

-- Grabs one piece (stepping next to it first if it's out of grab range) and sinks it.
local function voidPiece(piece: BasePart)
	local root = rootOf(LocalPlayer)
	if root and (piece.Position - root.Position).Magnitude > CONST.GRAB_RANGE then
		-- the server only grabs pieces near you: hop over (you're put back when the batch is done)
		root.CFrame = CFrame.new(piece.Position + CONST.HOP_OFFSET)
		root.AssemblyLinearVelocity = Vector3.zero
	end
	if grab(piece) then
		sinkHeld(piece)
	end
end

-- Visits pieces nearest-first from wherever we are, so the hops stay short.
local function nearestOrder(pieces: { BasePart }, from: Vector3): { BasePart }
	local left = table.clone(pieces)
	local ordered = table.create(#left)
	local at = from
	while #left > 0 do
		local bestIndex, bestDist = 1, math.huge
		for i, piece in left do
			local d = (piece.Position - at).Magnitude
			if d < bestDist then
				bestIndex, bestDist = i, d
			end
		end
		local piece = table.remove(left, bestIndex) :: BasePart
		table.insert(ordered, piece)
		at = piece.Position
	end
	return ordered
end

-- Pieces our client already simulates (spawned near us, orbiting, ...) need no grab: throw them all
-- through the floor at once and the server deletes them at FallenPartsDestroyHeight.
local function sinkOwned(pieces: { BasePart }, evenWhenClosing: boolean?)
	local mine = {}
	for _, piece in pieces do
		if piece.Parent and piece.ReceiveAge < CONST.OWNED_AGE then
			table.insert(mine, piece)
		end
	end
	if #mine == 0 then
		return
	end
	-- the whole assembly (a window is ~20 welded parts) must pass through the floor, not just its root
	for _, piece in mine do
		for _, part in piece:GetConnectedParts(true) do
			if part:IsA("BasePart") then
				part.CanCollide = false
			end
		end
	end
	local deadline = os.clock() + CONST.SINK_ALL_TIME
	while os.clock() < deadline and (state.running or evenWhenClosing) do
		local falling = 0
		for _, piece in mine do
			if piece.Parent then
				piece.AssemblyLinearVelocity = Vector3.new(0, -CONST.VOID_SPEED, 0)
				if piece.Position.Y > CONST.SINK_RELEASE_Y then
					falling += 1
				end
			end
		end
		if falling == 0 then
			break
		end
		RunService.Heartbeat:Wait()
	end
end

local function deleteLoosePieces()
	local loose, fixed = looseOwnPieces()
	if #loose == 0 then
		error(if fixed > 0 then `no loose pieces ({fixed} cemented ones need the game's hammer)` else "you have no pieces to delete", 0)
	end
	setStatus(`Deleting {#loose} pieces…`, Theme.Accent)
	sinkOwned(loose) -- everything we already simulate goes in one go; the rest is grabbed below
	local root = rootOf(LocalPlayer)
	local home = root and root.CFrame
	local total = #loose
	-- a released piece finishes falling on the server, so a second pass only catches stragglers
	for pass = 1, CONST.DELETE_PASSES do
		local todo = {}
		for _, piece in loose do
			if piece.Parent and piece.Position.Y > CONST.SINK_RELEASE_Y then
				table.insert(todo, piece)
			end
		end
		if #todo == 0 then
			break
		end
		if pass > 1 then
			task.wait(CONST.PASS_SETTLE)
		end
		for i, piece in nearestOrder(todo, if root then root.Position else Vector3.zero) do
			if state.stop or not state.running then
				break
			end
			setStatus(`Deleting {i}/{#todo}{if pass > 1 then " (retry)" else ""}…`, Theme.Accent)
			if piece.Parent then
				voidPiece(piece)
			end
		end
	end
	if root and home and root.Parent then
		root.CFrame = home
		root.AssemblyLinearVelocity = Vector3.zero
	end
	-- anything already under the floor is on its way out (the server deletes it when it hits -500)
	local left = 0
	for _, piece in loose do
		if piece.Parent and piece.Position.Y > CONST.SINK_RELEASE_Y then
			left += 1
		end
	end
	table.clear(state.pieces)
	local note = if fixed > 0 then ` {fixed} cemented piece(s) stay (only the hammer can break those).` else ""
	setStatus(`Deleted {total - left} of {total} loose pieces.{note}`, Theme.Good)
end


----------------------------------------------------------------------------------------------------
-- Orbit: from the moment it's on, everything circles you (centred on your character) and each new
-- piece joins the orbit as soon as it's spawned or picked up.
--   * Spawning cycles through EVERY item the game has (Brick + everything in ReplicatedStorage.Items:
--     plates, boards, planks, beams, glass, windows…) with no limit, until the server refuses.
--   * Bring nearby loose parts: anyone's non-cemented pieces lying near you are already simulated by
--     your client (a loose part belongs to the nearest player), so they just join in. No teleporting.
-- One Heartbeat loop steers every piece by velocity — no grabs. Pieces don't collide on your side
-- (so they never hit you), but on everyone else's screen they're solid, fast and spinning, so
-- whoever they touch gets flung. Turning it off throws your spawned pieces into the void and drops
-- other people's parts where they are.
----------------------------------------------------------------------------------------------------
local function orbitAlive(): { BasePart }
	local alive = {}
	for _, piece in state.orbit do
		if piece.Parent then
			table.insert(alive, piece)
		else
			state.orbitSet[piece] = nil
		end
	end
	state.orbit = alive
	return alive
end

local isOwner: (BasePart) -> boolean = if type(isnetworkowner) == "function"
	then function(part)
		local ok, owned = pcall(isnetworkowner, part)
		return ok and owned == true
	end
	else function(part)
		return part.ReceiveAge < CONST.OWNED_AGE
	end

-- Collision on our side for a whole assembly (off while we steer it, so it never hits us).
local function setAssemblyCollide(root: BasePart, on: boolean)
	local parts = state.assemblyParts[root] or root:GetConnectedParts(true)
	for _, part in parts do
		if part:IsA("BasePart") and part.Parent and part.CanCollide ~= on then
			part.CanCollide = on
		end
	end
end

local function addToOrbit(root: BasePart)
	if state.orbitSet[root] then
		return
	end
	table.insert(state.orbit, root)
	state.orbitSet[root] = true
	state.assemblyParts[root] = root:GetConnectedParts(true)
	setAssemblyCollide(root, false)
end

-- Lets a collected (not spawned) assembly go: solid again on our side so it doesn't sink.
local function dropAssembly(root: BasePart)
	if root.Parent then
		setAssemblyCollide(root, true)
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	end
	state.assemblyParts[root] = nil
end

-- Every spawnable thing: "Brick" (the Spawn action) plus each item in ReplicatedStorage.Items.
local function spawnableItems(): { string }
	local names = { "Brick" }
	local items = ReplicatedStorage:FindFirstChild("Items")
	if items then
		local found = {}
		for _, item in items:GetChildren() do
			table.insert(found, item.Name)
		end
		table.sort(found)
		table.move(found, 1, #found, 2, names)
	end
	return names
end

local function ownedByUs(instance: Instance): boolean
	return instance:GetAttribute("Owner") == LocalPlayer.UserId
end

-- Spawns one item next to us and returns its assembly root (windows are welded multi-part models).
-- Shares the spawn lock with the launcher; the server accepts about one spawn a second.
local function spawnOrbitItem(itemName: string, offset: Vector3): BasePart?
	while state.spawnBusy and state.running do
		task.wait()
	end
	local root = rootOf(LocalPlayer)
	if not root or not state.running then
		return nil
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { LocalPlayer.Character :: Instance }
	local hit = workspace:Raycast(root.Position + offset + Vector3.new(0, 4, 0), Vector3.new(0, -60, 0), params)
	if not hit then
		return nil
	end
	local isBrick = itemName == "Brick"
	local folder = if isBrick then BricksFolder else PlacedItems
	if not folder then
		return nil
	end
	state.spawnBusy = true
	local spawned: Instance? = nil
	local conn = folder.ChildAdded:Connect(function(child)
		if spawned == nil and ownedByUs(child) and (isBrick or child:GetAttribute("ItemId") == itemName) then
			spawned = child
		end
	end)
	if isBrick then
		BrickEvent:FireServer("Spawn", hit.Position, hit.Normal)
	else
		BrickEvent:FireServer("SpawnItem", itemName, hit.Position, hit.Normal)
	end
	local deadline = os.clock() + CONST.ORBIT_SPAWN_TIMEOUT
	while spawned == nil and os.clock() < deadline do
		task.wait()
	end
	conn:Disconnect()
	state.spawnBusy = false
	if not spawned then
		return nil
	end
	-- a model's parts can replicate a moment after the model itself
	local part: BasePart? = nil
	local partDeadline = os.clock() + 1
	repeat
		part = if (spawned :: Instance):IsA("BasePart") then spawned :: BasePart else (spawned :: Instance):FindFirstChildWhichIsA("BasePart", true)
		if not part then
			task.wait()
		end
	until part or os.clock() > partDeadline
	return if part then part.AssemblyRootPart or part else nil
end

local function orbitSpawner(generation: number)
	local items = spawnableItems()
	local nextItem = 1
	local fails = 0 -- refusals of the current type
	local streak = 0 -- refusals in a row across all types
	local spawned = 0
	-- No limit: keep spawning until the server stops accepting spawns. When every type keeps being
	-- refused we treat that as the server's limit, say so, and try again every SPAWN_RETRY_LATER s.
	while state.orbitOn and state.running and state.orbitGen == generation do
		local itemName = items[nextItem]
		local angle = math.random() * math.pi * 2
		local offset = Vector3.new(math.cos(angle), 0, math.sin(angle)) * 6
		local piece = spawnOrbitItem(itemName, offset)
		if piece and state.orbitOn and state.orbitGen == generation then
			state.spawnedSet[piece] = true
			addToOrbit(piece)
			spawned += 1
			nextItem = nextItem % #items + 1
			fails, streak = 0, 0
			setStatus(`Orbit: {#orbitAlive()} pieces ({spawned} spawned, last: {itemName})`, Theme.Accent)
			task.wait(CONST.ORBIT_SPAWN_GAP)
		elseif piece then
			sinkOwned({ piece }) -- turned off while it was spawning
		else
			-- usually just the ~1 s spawn cooldown: retry the same type, but don't get stuck on one
			-- the server keeps refusing
			fails += 1
			streak += 1
			if fails >= CONST.SPAWN_TYPE_TRIES then
				fails = 0
				nextItem = nextItem % #items + 1
			end
			if streak >= CONST.SPAWN_GIVE_UP then
				streak = 0
				setStatus(`Server won't spawn any more (limit reached). Orbiting {#orbitAlive()} pieces; retrying in {CONST.SPAWN_RETRY_LATER}s.`, Theme.Accent)
				task.wait(CONST.SPAWN_RETRY_LATER)
			else
				task.wait(CONST.ORBIT_SPAWN_GAP)
			end
		end
	end
end

-- Everything that isn't cemented: Roblox's IsGrounded() is true for any part connected (through
-- cement, welds, nails…) to something anchored. Non-grounded parts move as assemblies — a welded
-- window or a free-standing welded build is one assembly — so we bring each assembly by its root.
local function isBringableRoot(root: BasePart): boolean
	if state.orbitSet[root] or root:IsGrounded() then
		return false
	end
	local holder = root:GetAttribute("GrabbedBy")
	if holder and holder ~= LocalPlayer.UserId then
		return false -- someone is carrying it right now
	end
	if root.AssemblyLinearVelocity.Magnitude > CONST.BRING_MAX_SPEED then
		return false -- flying about (flung by someone): only pick up pieces that are settled
	end
	for _, piece in state.pieces do
		if piece.AssemblyRootPart == root then
			return false -- the launcher's piece
		end
	end
	return true
end

local function bringableParts(): { BasePart }
	local roots, seen = {}, {}
	local function consider(part: Instance)
		if not part:IsA("BasePart") or part.Anchored then
			return
		end
		local root = part.AssemblyRootPart
		if root and not seen[root] then
			seen[root] = true
			if isBringableRoot(root) then
				table.insert(roots, root)
			end
		end
	end
	for _, folder in { BricksFolder, PlacedItems, workspace:FindFirstChild("Nails"), workspace:FindFirstChild("Hinges") } do
		if folder then
			for _, part in folder:GetDescendants() do
				consider(part)
			end
		end
	end
	-- loose pieces sitting straight in workspace (dropped planks, plates…), never characters
	for _, child in workspace:GetChildren() do
		if child:IsA("BasePart") and child ~= workspace.Terrain then
			consider(child)
		end
	end
	return roots
end

-- when each collected part was first seen owned by someone else
local lostSince: { [BasePart]: number } = setmetatable({}, { __mode = "k" }) :: any

local function orbitCollector(generation: number)
	while state.orbitOn and state.running and state.orbitGen == generation do
		-- Collected parts that stay with another player stop obeying us: let them go (solid again).
		-- Brief ownership blips happen, so only drop after a grace period.
		local now = os.clock()
		for i = #state.orbit, 1, -1 do
			local piece = state.orbit[i]
			if piece.Parent and not state.spawnedSet[piece] then
				if isOwner(piece) then
					lostSince[piece] = nil
				elseif not lostSince[piece] then
					lostSince[piece] = now
				elseif now - (lostSince[piece] :: number) > CONST.LOST_GRACE then
					lostSince[piece] = nil
					table.remove(state.orbit, i)
					state.orbitSet[piece] = nil
					dropAssembly(piece)
				end
			end
		end
		-- only parts our client already simulates (yours, or anyone's lying near you)
		if Settings.BringAll then
			for _, part in bringableParts() do
				if isOwner(part) then
					addToOrbit(part)
				end
			end
		end
		task.wait(CONST.COLLECT_SCAN)
	end
end

give(RunService.Heartbeat:Connect(function(dt: number)
	if not state.orbitOn then
		return
	end
	local root = rootOf(LocalPlayer)
	local pieces = state.orbit
	local n = #pieces
	if not root or n == 0 then
		return
	end
	state.orbitAngle += Settings.OrbitSpeed * dt
	local centre = root.Position
	local spin = Vector3.new(Settings.OrbitSpin * 0.3, Settings.OrbitSpin, 0)
	for i, piece in pieces do
		if piece.Parent and not piece.Anchored and piece.ReceiveAge < CONST.OWNED_AGE * 5 then
			local ring = (i - 1) // CONST.ORBIT_PER_RING
			local inRing = math.min(CONST.ORBIT_PER_RING, n - ring * CONST.ORBIT_PER_RING)
			local slot = (i - 1) % CONST.ORBIT_PER_RING
			-- alternate rings turn the other way and sit a little higher
			local direction = if ring % 2 == 0 then 1 else -1
			local angle = state.orbitAngle * direction + slot / inRing * math.pi * 2
			local radius = Settings.OrbitRadius + ring * CONST.ORBIT_RING_GAP
			local want = centre + Vector3.new(math.cos(angle) * radius, ring * 2, math.sin(angle) * radius)
			local velocity = (want - piece.Position) * CONST.ORBIT_GAIN
			if velocity.Magnitude > CONST.ORBIT_MAX_SPEED then
				velocity = velocity.Unit * CONST.ORBIT_MAX_SPEED
			end
			piece.AssemblyLinearVelocity = velocity
			piece.AssemblyAngularVelocity = spin
		end
	end
end))

local function setOrbit(on: boolean)
	if state.orbitOn == on then
		return
	end
	state.orbitOn = on
	-- a new generation makes any older spawner loop exit by itself (cancelling it mid-spawn would
	-- leave its ChildAdded listener connected)
	state.orbitGen += 1
	if on then
		task.spawn(orbitSpawner, state.orbitGen)
		task.spawn(orbitCollector, state.orbitGen)
		setStatus("Orbit on: pieces join as they're spawned / picked up…", Theme.Accent)
		return
	end
	local ours, theirs = {}, {}
	for _, piece in orbitAlive() do
		table.insert(if state.spawnedSet[piece] then ours else theirs, piece)
	end
	table.clear(state.orbit)
	table.clear(state.orbitSet)
	table.clear(state.spawnedSet)
	-- other people's parts are just let go next to you, solid again (on our side they had no
	-- collision, so without this they'd sink through the floor)
	for _, piece in theirs do
		dropAssembly(piece)
	end
	table.clear(state.assemblyParts)
	task.spawn(function()
		sinkOwned(ours)
		if state.running then
			setStatus(`Orbit off: {#ours} of your pieces sent into the void, {#theirs} others' parts dropped.`, Theme.Good)
		end
	end)
end


local function startDelete()
	if state.job then
		return
	end
	setOrbit(false) -- otherwise the orbit keeps pulling its pieces back out of the void
	state.stop = false
	state.job = task.spawn(function()
		local ok, err = pcall(deleteLoosePieces)
		if state.running and not ok then
			setStatus("Error: " .. tostring(err), Theme.Danger)
		end
		state.job = nil
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
	Name = "BrickLauncher",
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
	Text = "Brick Launcher",
	TextColor3 = Theme.Text,
	FontFace = Theme.FontBold,
	TextSize = 15,
	TextXAlignment = Enum.TextXAlignment.Left,
	LayoutOrder = nextOrder(),
	Active = true,
	Parent = window,
})

local function hover(button: GuiObject, base: () -> Color3, over: Color3)
	local active: Tween? = nil
	local function to(color: Color3)
		if active then
			active:Cancel()
		end
		active = TweenService:Create(button, Theme.Tween, { BackgroundColor3 = color })
		active:Play()
	end
	give(button.MouseEnter:Connect(function()
		to(over)
	end))
	give(button.MouseLeave:Connect(function()
		to(base())
	end))
end

local function Button(text: string, base: Color3, over: Color3, height: number, parent: Instance?, width: UDim?): TextButton
	local button = create("TextButton", {
		Size = UDim2.new(width or UDim.new(1, 0), UDim.new(0, height)),
		BackgroundColor3 = base,
		AutoButtonColor = false,
		BorderSizePixel = 0,
		Text = text,
		TextColor3 = Theme.Text,
		FontFace = Theme.FontBold,
		TextSize = 13,
		LayoutOrder = nextOrder(),
		Parent = parent or window,
	}, {
		create("UICorner", { CornerRadius = Theme.Corner }),
	})
	hover(button, function()
		return base
	end, over)
	return button
end

local function Label(text: string)
	return create("TextLabel", {
		Size = UDim2.new(1, 0, 0, 14),
		BackgroundTransparency = 1,
		Text = text,
		TextColor3 = Theme.SubText,
		FontFace = Theme.Font,
		TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = nextOrder(),
		Parent = window,
	})
end

-- Player list (you first). Rows are rebuilt only when players join / leave.
Label("Target")
local list = create("ScrollingFrame", {
	Size = UDim2.new(1, 0, 0, CONST.LIST_HEIGHT),
	BackgroundColor3 = Theme.Panel,
	BorderSizePixel = 0,
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	ScrollBarThickness = 4,
	ScrollBarImageColor3 = Theme.Stroke,
	LayoutOrder = nextOrder(),
	Parent = window,
}, {
	create("UICorner", { CornerRadius = Theme.Corner }),
	create("UIPadding", { PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 8), PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4) }),
	create("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }),
})

local rows: { [Player]: TextButton } = {}
local function paintRows()
	for player, row in rows do
		row.BackgroundColor3 = if player == state.target then Theme.Selected else Theme.Field
	end
end

local function rebuildList()
	for _, row in rows do
		row:Destroy()
	end
	table.clear(rows)
	local players = Players:GetPlayers()
	table.sort(players, function(a, b)
		if a == LocalPlayer or b == LocalPlayer then
			return a == LocalPlayer
		end
		return a.DisplayName:lower() < b.DisplayName:lower()
	end)
	for i, player in players do
		local label = if player == LocalPlayer then `{player.DisplayName} (you)` else `{player.DisplayName}  @{player.Name}`
		local row = create("TextButton", {
			Size = UDim2.new(1, 0, 0, 26),
			BackgroundColor3 = Theme.Field,
			AutoButtonColor = false,
			BorderSizePixel = 0,
			Text = label,
			TextColor3 = Theme.Text,
			FontFace = Theme.Font,
			TextSize = 12,
			TextTruncate = Enum.TextTruncate.AtEnd,
			LayoutOrder = i,
			Parent = list,
		}, {
			create("UICorner", { CornerRadius = Theme.Corner }),
			create("UIPadding", { PaddingLeft = UDim.new(0, 8) }),
		})
		row.TextXAlignment = Enum.TextXAlignment.Left
		row.Activated:Connect(function()
			state.target = player
			paintRows()
		end)
		rows[player] = row
	end
	if not (state.target and state.target.Parent) then
		state.target = LocalPlayer
	end
	paintRows()
end
give(Players.PlayerAdded:Connect(rebuildList))
give(Players.PlayerRemoving:Connect(function(player)
	if state.target == player then
		state.target = LocalPlayer
	end
	task.defer(rebuildList)
end))
rebuildList()

-- Speed / time fields (validated when you click away)
local function NumberField(labelText: string, key: string, lo: number, hi: number, parent: Instance, width: UDim?)
	local holder = create("Frame", {
		Size = UDim2.new(width or UDim.new(0.5, -4), UDim.new(1, 0)),
		BackgroundTransparency = 1,
		Parent = parent,
	}, {
		create("TextLabel", {
			Size = UDim2.new(1, 0, 0, 14),
			BackgroundTransparency = 1,
			Text = labelText,
			TextColor3 = Theme.SubText,
			FontFace = Theme.Font,
			TextSize = 11,
			TextXAlignment = Enum.TextXAlignment.Left,
		}),
	})
	local box = create("TextBox", {
		Position = UDim2.fromOffset(0, 16),
		Size = UDim2.new(1, 0, 0, 26),
		BackgroundColor3 = Theme.Field,
		BorderSizePixel = 0,
		ClearTextOnFocus = false,
		Text = tostring(Settings[key]),
		TextColor3 = Theme.Text,
		FontFace = Theme.Font,
		TextSize = 13,
		Parent = holder,
	}, {
		create("UICorner", { CornerRadius = Theme.Corner }),
	})
	give(box.FocusLost:Connect(function()
		local n = tonumber(box.Text)
		if n then
			Settings[key] = math.clamp(n, lo, hi)
		end
		box.Text = tostring(Settings[key])
	end))
end
local fields = create("Frame", {
	Size = UDim2.new(1, 0, 0, 42),
	BackgroundTransparency = 1,
	LayoutOrder = nextOrder(),
	Parent = window,
}, {
	create("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8) }),
})
NumberField("Speed (studs/s)", "Speed", 10, 1000, fields)
NumberField("Rise time (s)", "Time", 0.2, 10, fields)

local actions = create("Frame", {
	Size = UDim2.new(1, 0, 0, 36),
	BackgroundTransparency = 1,
	LayoutOrder = nextOrder(),
	Parent = window,
}, {
	create("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8) }),
})
local launchBtn = Button("Launch  (L)", Theme.Accent, Theme.AccentHover, 36, actions, UDim.new(0.6, -4))
local stopBtn = Button("Stop", Theme.Danger, Theme.Danger:Lerp(Color3.new(1, 1, 1), 0.15), 36, actions, UDim.new(0.4, -4))

local status = create("TextLabel", {
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1,
	Text = "Pick a player and press Launch.",
	TextColor3 = Theme.SubText,
	FontFace = Theme.Font,
	TextSize = 12,
	TextWrapped = true,
	TextXAlignment = Enum.TextXAlignment.Left,
	LayoutOrder = nextOrder(),
	Parent = window,
})

-- Orbit
Label("Orbit (pieces circle you and fling whoever they hit)")
local orbitFields = create("Frame", {
	Size = UDim2.new(1, 0, 0, 42),
	BackgroundTransparency = 1,
	LayoutOrder = nextOrder(),
	Parent = window,
}, {
	create("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6) }),
})
local half = UDim.new(0.5, -3)
NumberField("Radius", "OrbitRadius", 3, 60, orbitFields, half)
NumberField("Speed", "OrbitSpeed", 0.5, 30, orbitFields, half)
local orbitBtn = Button("Orbit: Off  (O)", Theme.Field, Theme.FieldHover, 32)
local orbitStroke = create("UIStroke", { Color = Theme.Stroke, Thickness = 1, Parent = orbitBtn })
local bringBtn = Button(if Settings.BringAll then "Bring nearby loose parts: On" else "Bring nearby loose parts: Off", Theme.Field, Theme.FieldHover, 26)
bringBtn.TextSize = 12
give(bringBtn.Activated:Connect(function()
	Settings.BringAll = not Settings.BringAll
	bringBtn.Text = if Settings.BringAll then "Bring nearby loose parts: On" else "Bring nearby loose parts: Off"
end))

local deleteBtn = Button("Delete my loose pieces", Theme.Field, Theme.FieldHover, 28)

local closeBtn = Button("Close", Theme.Field, Theme.FieldHover, 24)
closeBtn.TextSize = 12

window.Parent = screen

-- Status writes come from the launch thread; apply them on Heartbeat (change-only).
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
end))

give(launchBtn.Activated:Connect(startLaunch))

local function toggleOrbit()
	setOrbit(not state.orbitOn)
	orbitBtn.Text = if state.orbitOn then "Orbit: On  (O)" else "Orbit: Off  (O)"
	orbitStroke.Color = if state.orbitOn then Theme.Accent else Theme.Stroke
end
give(orbitBtn.Activated:Connect(toggleOrbit))

-- Two clicks within CONFIRM_TIME seconds, so it can't be hit by accident.
local confirmUntil = 0
give(deleteBtn.Activated:Connect(function()
	if state.job then
		return
	end
	if os.clock() > confirmUntil then
		local loose, fixed = looseOwnPieces()
		confirmUntil = os.clock() + CONST.CONFIRM_TIME
		deleteBtn.Text = `Click again to delete {#loose}`
		setStatus(`{#loose} loose piece(s) will vanish for everyone; {fixed} cemented one(s) can't be removed.`, Theme.Accent)
		task.delay(CONST.CONFIRM_TIME, function()
			if os.clock() >= confirmUntil and deleteBtn.Parent then
				deleteBtn.Text = "Delete my loose pieces"
			end
		end)
		return
	end
	confirmUntil = 0
	deleteBtn.Text = "Delete my loose pieces"
	startDelete()
end))
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
end))

-- Keys (ignored while typing): L launches the selected player, O toggles the orbit, RightShift hides
-- the window.
give(UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end
	if input.KeyCode == CONST.LAUNCH_KEY then
		startLaunch()
	elseif input.KeyCode == CONST.ORBIT_KEY then
		toggleOrbit()
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
	-- our orbit pieces go into the void; other people's parts are dropped, solid again
	local orbiting = {}
	for _, piece in orbitAlive() do
		if state.spawnedSet[piece] then
			table.insert(orbiting, piece)
		else
			dropAssembly(piece)
		end
	end
	state.orbitOn = false
	state.orbitGen += 1
	table.clear(state.orbit)
	table.clear(state.orbitSet)
	table.clear(state.spawnedSet)
	state.running = false
	state.stop = true
	if state.job then
		release()
	end
	if #orbiting > 0 then
		task.spawn(sinkOwned, orbiting, true)
	end
	for i = #tasks, 1, -1 do
		local item = tasks[i]
		if typeof(item) == "RBXScriptConnection" then
			item:Disconnect()
		elseif typeof(item) == "Instance" then
			pcall(item.Destroy, item)
		end
	end
	table.clear(tasks)
	for _, row in rows do
		row:Destroy()
	end
	if genv.__BRICK_LAUNCHER == controller then
		genv.__BRICK_LAUNCHER = nil
	end
end
controller.Settings = Settings
function controller.Orbit(on: boolean)
	if state.orbitOn ~= on then
		toggleOrbit()
	end
end
function controller.OrbitPieces(): { BasePart }
	return state.orbit
end
function controller.Launch(player: Player?)
	if player then
		state.target = player
		paintRows()
	end
	startLaunch()
end
function controller.Status(): (string, boolean)
	return status.Text, state.job ~= nil
end
give(closeBtn.Activated:Connect(controller.Cleanup))
genv.__BRICK_LAUNCHER = controller
