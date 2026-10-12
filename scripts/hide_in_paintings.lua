-- Hide In Paintings — Instant Blend
-- One button (or the B key) repaints your whole figure with exactly the painting behind it, using the
-- game's own BlendCore + painting sampler (the same code the paid "Blend In" power-up runs, minus the
-- slow band-by-band animation). Then press the game's Submit as usual.
--
-- Verified in-game (PlaceId 71274660353135, 2026-10-12):
--   * Client state lives in ChameleonClient's module table (fields rig / painting / activeCanvas / phase /
--     submitted). Found through the ProductResult listener's upvalues (applyBlendIn closes over it).
--   * BlendCore.fillSkinsFromWorld(rig, colourAt(worldPos)) writes every opaque pixel of the figure skin.
--     colourAt = painting:sampleUVSmooth(BlendCore.worldToUV(activeCanvas, worldPos)), exactly what
--     applyBlendIn uses. Submit then sends BlendCore.skinBuffers(rig), so the server gets the blended skin.

if not game:IsLoaded() then
	game.Loaded:Wait()
end

----------------------------------------------------------------------------------------------------
-- Re-execution guard
----------------------------------------------------------------------------------------------------
local genv: any = if type(getgenv) == "function" then getgenv() else _G
if genv.__HIP_BLEND and type(genv.__HIP_BLEND.Cleanup) == "function" then
	pcall(genv.__HIP_BLEND.Cleanup)
end

----------------------------------------------------------------------------------------------------
-- Services & executor features
----------------------------------------------------------------------------------------------------
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CoreGui = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer

if type(getconnections) ~= "function" or type(debug.getupvalues) ~= "function" then
	error("[HideBlend] executor needs getconnections + debug.getupvalues")
end

local Blend = ReplicatedStorage:WaitForChild("ChameleonBlend", 30)
if not Blend then
	error("[HideBlend] this isn't Hide In Paintings (no ChameleonBlend)")
end
local BlendCore = require(Blend:WaitForChild("BlendCore"))
local ProductResult = Blend:WaitForChild("Remotes"):WaitForChild("ProductResult")

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
	Width = 240,
	Tween = TweenInfo.new(0.14, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
})

local CONST = table.freeze({
	BLEND_KEY = Enum.KeyCode.B,
	SHOW_KEY = Enum.KeyCode.V,
	TOGGLE_KEY = Enum.KeyCode.RightShift,
	REVEAL_COLOR = Color3.fromRGB(255, 60, 200), -- outline on the opponent's hidden figure
	REVEAL_CHECK = 0.25, -- seconds between checks for a new seek round / figure
	REVEAL_PULSE = TweenInfo.new(0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
})

----------------------------------------------------------------------------------------------------
-- Maid
----------------------------------------------------------------------------------------------------
local tasks: { any } = {}
local function give(item: any): any
	table.insert(tasks, item)
	return item
end

local state = {
	running = true,
	game = nil :: any, -- ChameleonClient's state table (cached once found)
	undo = nil :: any, -- { rig, snapshot } of the figure before our last blend
	pendingStatus = nil :: any,
	showOpponent = false,
	reveal = nil :: any, -- { parts = theirParts it was made for, marks = { ImageLabel }, tweens = { Tween } }
}

----------------------------------------------------------------------------------------------------
-- Finding the game's client state
----------------------------------------------------------------------------------------------------
local function findGameState(): any
	local cached = state.game
	if cached and rawget(cached, "toolUse") ~= nil then
		return cached
	end
	for _, conn in getconnections(ProductResult.OnClientEvent) do
		local fn = conn.Function
		if type(fn) == "function" then
			local okUps, ups = pcall(debug.getupvalues, fn)
			if okUps then
				for _, up in ups do
					if type(up) == "function" then
						local okInner, inner = pcall(debug.getupvalues, up)
						if okInner then
							for _, candidate in inner do
								if type(candidate) == "table" and rawget(candidate, "toolUse") ~= nil and rawget(candidate, "phase") ~= nil then
									state.game = candidate
									return candidate
								end
							end
						end
					end
				end
			end
		end
	end
	return nil
end

----------------------------------------------------------------------------------------------------
-- Blending
----------------------------------------------------------------------------------------------------
-- Returns ok, message.
local function blendIn(): (boolean, string)
	local S = findGameState()
	if not S then
		return false, "Couldn't find the game's painter (rejoin or wait for the game to load)."
	end
	if S.phase ~= "hide" then
		return false, "Wait for the hiding phase."
	end
	if S.submitted then
		return false, "Already submitted. Press the game's Unsubmit first."
	end
	local rig, painting, canvas = S.rig, S.painting, S.activeCanvas
	if not (rig and painting and canvas) then
		return false, "No figure or painting yet: move into the painting first."
	end

	local snapshot = BlendCore.snapshotSkins(rig)
	local ok, err = pcall(BlendCore.fillSkinsFromWorld, rig, function(worldPos: Vector3)
		local u, v = BlendCore.worldToUV(canvas, worldPos)
		return painting:sampleUVSmooth(u, v)
	end)
	if not ok then
		return false, "Blend failed: " .. tostring(err)
	end
	state.undo = { rig = rig, snapshot = snapshot }
	-- the game unlocks its "checking your blend" status once you've painted something
	S.everPainted = true
	if type(S.refreshSubmit) == "function" then
		pcall(S.refreshSubmit)
	end
	return true, "Blended! Press the game's Submit."
end

local function undoBlend(): (boolean, string)
	local undo = state.undo
	local S = state.game
	if not (undo and undo.snapshot and S and S.rig == undo.rig) then
		return false, "Nothing to undo."
	end
	if S.submitted then
		return false, "Already submitted."
	end
	BlendCore.restoreSkins(undo.rig, undo.snapshot)
	state.undo = nil
	return true, "Restored your previous paint."
end

----------------------------------------------------------------------------------------------------
-- Show opponent: while you seek, the game draws the opponent's hidden figure onto their painting
-- (state.theirParts) and its paid "Reveal" outlines it with BlendCore.markSilhouette. We keep that
-- outline on for the whole seek phase, re-applying it when a new round brings a new figure.
----------------------------------------------------------------------------------------------------
local function clearReveal()
	local reveal = state.reveal
	if not reveal then
		return
	end
	state.reveal = nil
	for _, tween in reveal.tweens do
		tween:Cancel()
	end
	for _, mark in reveal.marks do
		if mark.Parent then
			mark:Destroy()
		end
	end
end

local function revealIntact(reveal: any, parts: any): boolean
	if reveal.parts ~= parts or #reveal.marks == 0 then
		return false
	end
	for _, mark in reveal.marks do
		if not mark.Parent then
			return false -- the game cleared it (e.g. its own reveal ended)
		end
	end
	return true
end

local function updateReveal()
	local S = state.game or findGameState()
	local parts = S and S.phase == "seek" and S.theirParts
	if not (state.showOpponent and parts) then
		clearReveal()
		return
	end
	local current = state.reveal
	if current and revealIntact(current, parts) then
		return
	end
	clearReveal()
	local ok, marks = pcall(BlendCore.markSilhouette, parts, CONST.REVEAL_COLOR, S.theirPose)
	if not ok or type(marks) ~= "table" or #marks == 0 then
		return
	end
	local tweens = {}
	for _, mark in marks do
		mark.ImageTransparency = 0.1
		local tween = TweenService:Create(mark, CONST.REVEAL_PULSE, { ImageTransparency = 0.6 })
		tween:Play()
		table.insert(tweens, tween)
	end
	state.reveal = { parts = parts, marks = marks, tweens = tweens }
end

-- Own connection (not the UI one): calling the game's code can leave a thread unable to touch our UI.
local revealClock = 0
give(RunService.Heartbeat:Connect(function(dt: number)
	revealClock += dt
	if revealClock < CONST.REVEAL_CHECK then
		return
	end
	revealClock = 0
	if state.showOpponent or state.reveal then
		updateReveal()
	end
end))

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
	Name = "HideBlend",
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

local title = create("TextLabel", {
	Size = UDim2.new(1, 0, 0, 20),
	BackgroundTransparency = 1,
	Text = "Instant Blend",
	TextColor3 = Theme.Text,
	FontFace = Theme.FontBold,
	TextSize = 15,
	TextXAlignment = Enum.TextXAlignment.Left,
	LayoutOrder = 1,
	Active = true,
	Parent = window,
})

local function Button(text: string, base: Color3, hover: Color3, order: number, height: number): TextButton
	local button = create("TextButton", {
		Size = UDim2.new(1, 0, 0, height),
		BackgroundColor3 = base,
		AutoButtonColor = false,
		BorderSizePixel = 0,
		Text = text,
		TextColor3 = Theme.Text,
		FontFace = Theme.FontBold,
		TextSize = 14,
		LayoutOrder = order,
		Parent = window,
	}, {
		create("UICorner", { CornerRadius = Theme.Corner }),
	})
	local active: Tween? = nil
	local function to(color: Color3)
		if active then
			active:Cancel()
		end
		active = TweenService:Create(button, Theme.Tween, { BackgroundColor3 = color })
		active:Play()
	end
	give(button.MouseEnter:Connect(function()
		to(hover)
	end))
	give(button.MouseLeave:Connect(function()
		to(base)
	end))
	return button
end

local blendBtn = Button("Blend In  (B)", Theme.Accent, Theme.AccentHover, 2, 40)
local undoBtn = Button("Undo blend", Theme.Field, Theme.FieldHover, 3, 28)
local showBtn = Button("Show opponent: Off  (V)", Theme.Field, Theme.FieldHover, 4, 32)
local showStroke = create("UIStroke", { Color = Theme.Stroke, Thickness = 1, Parent = showBtn })

local status = create("TextLabel", {
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1,
	Text = "Move into the painting, then press Blend In.",
	TextColor3 = Theme.SubText,
	FontFace = Theme.Font,
	TextSize = 12,
	TextWrapped = true,
	TextXAlignment = Enum.TextXAlignment.Left,
	LayoutOrder = 5,
	Parent = window,
})

local closeBtn = Button("Close", Theme.Field, Theme.FieldHover, 6, 24)
closeBtn.TextSize = 12

window.Parent = screen

-- Calling the game's code can leave this thread unable to touch our UI until it yields, so status
-- changes are applied from Heartbeat.
local function setStatus(text: string, good: boolean)
	state.pendingStatus = { text = text, color = if good then Theme.Accent else Theme.Danger }
end
give(RunService.Heartbeat:Connect(function()
	local pending = state.pendingStatus
	if pending then
		state.pendingStatus = nil
		status.Text = pending.text
		status.TextColor3 = pending.color
	end
end))

local function runBlend()
	local ok, message = blendIn()
	setStatus(message, ok)
end

local function toggleShow()
	state.showOpponent = not state.showOpponent
	showBtn.Text = if state.showOpponent then "Show opponent: On  (V)" else "Show opponent: Off  (V)"
	showStroke.Color = if state.showOpponent then CONST.REVEAL_COLOR else Theme.Stroke
	setStatus(if state.showOpponent then "Their figure lights up while you seek." else "Opponent hidden again.", true)
	revealClock = CONST.REVEAL_CHECK -- apply on the next frame
end

give(blendBtn.Activated:Connect(runBlend))
give(showBtn.Activated:Connect(toggleShow))
give(undoBtn.Activated:Connect(function()
	local ok, message = undoBlend()
	setStatus(message, ok)
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

-- One key listener: B blends, RightShift hides the window. Ignored while typing.
give(UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end
	if input.KeyCode == CONST.BLEND_KEY then
		runBlend()
	elseif input.KeyCode == CONST.SHOW_KEY then
		toggleShow()
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
	clearReveal()
	for i = #tasks, 1, -1 do
		local item = tasks[i]
		if typeof(item) == "RBXScriptConnection" then
			item:Disconnect()
		elseif typeof(item) == "Instance" then
			pcall(item.Destroy, item)
		end
	end
	table.clear(tasks)
	if genv.__HIP_BLEND == controller then
		genv.__HIP_BLEND = nil
	end
end
controller.Blend = blendIn
controller.Undo = undoBlend
give(closeBtn.Activated:Connect(controller.Cleanup))
genv.__HIP_BLEND = controller
