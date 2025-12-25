--// services (cached once so we don't keep calling GetService)
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

--// modules
-- Config = keybinds + per-view labels/hints
-- Utils = tweens/helpers + disconnect safety
-- Effects = postfx + fov pulse
-- CameraRig = builds the viewport "world" + keeps it in sync
local Config = require(script.Parent.Config)
local Utils = require(script.Parent.Utils)
local Effects = require(script.Parent.Effects)
local CameraRig = require(script.Parent.CameraRig)

local Controller = {}

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- core state
-- enabled is the big kill-switch (render loop + input logic checks it)
-- sessionId is basically my "cancel token" for task.spawn loops so they don't keep running after disable
-- focusedView tells me which rig is currently living in the fullscreen viewport
local enabled = false
local character = nil
local rootPart = nil
local rigs = {}
local renderConn = nil
local sessionId = 0
local focusedView = nil

-- ui refs (filled in init; I don't wanna be doing WaitForChild/FindFirstChild in RenderStepped)
local screenGui
local holder
local header
local vpContainer
local fullOverlay
local viewports = {}
local fullViewport
local fullCamLabel
local fullHint

-- fadeIn resets transparency first
-- this matters because you can toggle on while the old fadeOut is mid-tween (otherwise it looks half-broken)
local function fadeIn()
	local ti = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	holder.BackgroundTransparency = 1
	for _, child in holder:GetDescendants() do
		if child:IsA("TextLabel") then
			child.TextTransparency = 1
		elseif child:IsA("Frame") and child.Name ~= "Header" and child.Name ~= "ViewportContainer" then
			-- leave layout containers alone; only fade the real visible frames (dots, pills, etc)
			child.BackgroundTransparency = 1
		end
	end

	Utils.tween(holder, ti, { BackgroundTransparency = 0.04 })

	-- viewport tiles are their own frames, so fade those too
	for _, vp in vpContainer:GetChildren() do
		if vp:IsA("Frame") then
			vp.BackgroundTransparency = 1
			Utils.tween(vp, ti, { BackgroundTransparency = 0 })
		end
	end

	-- header has a mix of labels + frames
	for _, child in header:GetDescendants() do
		if child:IsA("TextLabel") then
			Utils.tween(child, ti, { TextTransparency = 0 })
		elseif child:IsA("Frame") then
			Utils.tween(child, ti, { BackgroundTransparency = 0 })
		end
	end
end

-- fadeOut doesn't reset anything; I want it to fade from whatever state it's currently at
-- the real "turn off" happens later in disable() after the tween finishes
local function fadeOut()
	local ti = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

	Utils.tween(holder, ti, { BackgroundTransparency = 1 })

	for _, vp in vpContainer:GetChildren() do
		if vp:IsA("Frame") then
			Utils.tween(vp, ti, { BackgroundTransparency = 1 })
		end
	end

	for _, child in header:GetDescendants() do
		if child:IsA("TextLabel") then
			Utils.tween(child, ti, { TextTransparency = 1 })
		elseif child:IsA("Frame") then
			Utils.tween(child, ti, { BackgroundTransparency = 1 })
		end
	end
end

-- pull fresh character refs
-- I keep rootPart cached because everything (rig follow / offsets) is based on that
local function refreshCharacter()
	character = player.Character
	if not character then
		rootPart = nil
		return
	end

	local hrp = character:FindFirstChild("HumanoidRootPart")
	-- HRP is the normal case; PrimaryPart is the backup for weird rigs
	rootPart = if hrp and hrp:IsA("BasePart") then hrp else character.PrimaryPart
end

-- clean rigs properly (each rig owns a WorldModel + camera setup)
local function destroyRigs()
	for _, rig in rigs do
		CameraRig.destroy(rig)
	end
	table.clear(rigs)
end

-- rebuild all rigs (used on enable + respawn)
-- destroy first so I never end up with duplicate WorldModels sitting in viewports
local function buildRigs()
	destroyRigs()
	refreshCharacter()

	-- if you're between spawns, just don't build yet
	if not character or not rootPart then return end

	-- one rig per viewport (rear/side/top)
	for viewKey, viewport in viewports do
		local rig = CameraRig.create(viewKey, character, rootPart, viewport)
		if rig then
			table.insert(rigs, rig)
		end
	end
end

-- rigs is tiny (3), so linear search is totally fine and keeps the rest simple
local function findRig(viewKey)
	for _, rig in rigs do
		if rig.viewKey == viewKey then return rig end
	end
	return nil
end

-- RenderStepped update
-- main idea: rigs mirror the real character pose into clones, then update their cameras smoothly
local function onRender(dt)
	-- cheap guards first (RenderStepped is hot)
	if not enabled or #rigs == 0 then return end
	if not character or not character.Parent then return end
	if not rootPart or not rootPart.Parent then return end

	local t = os.clock()

	for _, rig in rigs do
		-- copy live character pose into the rig's clone world
		CameraRig.syncPose(rig)

		-- update the rig camera (lerp + wobble uses time)
		CameraRig.updateCamera(rig, dt, t)
	end
end

-- fullscreen works by moving the *same* WorldModel between viewports
-- no rebuild = no GC spikes + you keep camera smoothing state
local function exitFullscreen()
	if not focusedView then return end

	local rig = findRig(focusedView)
	local smallVp = viewports[focusedView]

	-- put the world back + make sure the small viewport points at the right camera again
	if rig and smallVp then
		rig.world.Parent = smallVp
		smallVp.CurrentCamera = rig.camera
	end

	-- fade overlay out, then hide it
	Utils.tween(fullOverlay, TweenInfo.new(0.18, Enum.EasingStyle.Quad), { BackgroundTransparency = 1 })
	task.delay(0.2, function()
		fullOverlay.Visible = false
	end)

	focusedView = nil
end

-- enter fullscreen for a view key
-- pressing the same key again = toggle off
-- switching views = exit first so the world isn't "owned" by two viewports at once
local function enterFullscreen(viewKey)
	if focusedView == viewKey then
		exitFullscreen()
		return
	end

	if focusedView then
		exitFullscreen()
		task.wait(0.1)
	end

	local rig = findRig(viewKey)
	if not rig then return end

	local cfg = Config.views[viewKey]

	-- keep UI text driven by config so bind + label never drift
	fullCamLabel.Text = cfg.label
	fullHint.Text = "PRESS " .. cfg.hint .. " TO EXIT"

	-- the actual swap: reparent world into fullscreen viewport and point it at the rig camera
	rig.world.Parent = fullViewport
	fullViewport.CurrentCamera = rig.camera

	fullOverlay.BackgroundTransparency = 1
	fullOverlay.Visible = true
	Utils.tween(fullOverlay, TweenInfo.new(0.22, Enum.EasingStyle.Quad), { BackgroundTransparency = 0.2 })

	focusedView = viewKey
end

-- UI loops (clock + rec blink)
-- sessionId check is what stops these from lingering after disable without having to store extra flags
local function startUiLoops(mySession)
	local startTime = os.clock()
	local clock = header:FindFirstChild("Clock")
	local recDot = header:FindFirstChild("RecHolder") and header.RecHolder:FindFirstChild("RecDot")

	-- elapsed timer (uses os.clock so it won't jump around)
	task.spawn(function()
		while enabled and sessionId == mySession do
			if clock then
				local elapsed = math.max(0, math.floor(os.clock() - startTime))
				clock.Text = Utils.formatTime(elapsed)
			end
			task.wait(0.25)
		end
	end)

	-- blinking REC dot (slightly uneven timing feels nicer than perfect 50/50)
	task.spawn(function()
		while enabled and sessionId == mySession do
			if recDot then
				recDot.BackgroundTransparency = 0
				task.wait(0.55)
				recDot.BackgroundTransparency = 0.5
				task.wait(0.45)
			else
				task.wait(0.5)
			end
		end
	end)
end

-- enable order matters:
-- show UI first (instant feedback) -> postfx -> build rigs -> connect render loop -> start UI loops
local function enable()
	if enabled then return end

	refreshCharacter()
	if not character or not rootPart then
		warn("[CCTV] No character")
		return
	end

	enabled = true
	sessionId += 1
	local mySession = sessionId

	screenGui.Enabled = true
	fadeIn()

	Effects.enableCC()
	Effects.pulseCamera()

	buildRigs()

	-- disconnect first so double-enables don't stack RenderStepped connections
	Utils.disconnect(renderConn)
	renderConn = RunService.RenderStepped:Connect(onRender)

	startUiLoops(mySession)
end

-- disable is basically the reverse:
-- stop per-frame work immediately -> exit fullscreen while rigs still exist -> fade -> cleanup after fade
local function disable()
	if not enabled then return end

	enabled = false
	sessionId += 1

	Utils.disconnect(renderConn)
	renderConn = nil

	exitFullscreen()

	Effects.resetCamera()
	fadeOut()

	-- let the fade finish before nuking rigs/UI
	task.delay(0.22, function()
		destroyRigs()
		screenGui.Enabled = false
	end)

	Effects.disableCC()
end

local function toggle()
	if enabled then disable() else enable() end
end

-- respawn hook
-- if the system is on, rebuild rigs so the clone worlds match the new character model
local function onCharacterAdded(char)
	character = char
	local hrp = char:FindFirstChild("HumanoidRootPart")
	rootPart = if hrp and hrp:IsA("BasePart") then hrp else char.PrimaryPart

	if enabled then
		buildRigs()
	end
end

-- character is about to be destroyed, so drop refs and clean rigs before they point at dead instances
local function onCharacterRemoving()
	character = nil
	rootPart = nil
	exitFullscreen()
	destroyRigs()
end

-- init runs once from the LocalScript
-- grabs UI refs, wires input, and hooks character/camera changes
function Controller.init()
	-- timeout so I don't yield forever if the UI isn't in PlayerGui
	screenGui = playerGui:WaitForChild("CCTVInterface", 10)
	if not screenGui then
		warn("[CCTV] UI not found")
		return
	end

	holder = screenGui:WaitForChild("Holder")
	header = holder:WaitForChild("Header")
	vpContainer = holder:WaitForChild("ViewportContainer")
	fullOverlay = screenGui:WaitForChild("FullscreenOverlay")

	-- cache viewport frames once; CameraRig just needs a parent, not the whole UI path
	viewports = {
		rear = vpContainer:WaitForChild("VP_rear"):WaitForChild("Viewport"),
		side = vpContainer:WaitForChild("VP_side"):WaitForChild("Viewport"),
		top = vpContainer:WaitForChild("VP_top"):WaitForChild("Viewport"),
	}

	fullViewport = fullOverlay:WaitForChild("FullViewportFrame"):WaitForChild("Viewport")
	fullCamLabel = fullOverlay:WaitForChild("CamLabel")
	fullHint = fullOverlay:WaitForChild("ExitHint")

	-- input:
	-- gpe check stops toggling while typing in a textbox etc
	-- toggle key works always; view keys only do something when enabled
	UserInputService.InputBegan:Connect(function(input, gpe)
		if gpe then return end
		if input.UserInputType ~= Enum.UserInputType.Keyboard then return end

		if input.KeyCode == Config.toggleKey then
			toggle()
			return
		end

		if not enabled then return end

		for viewKey, keyCode in Config.viewKeys do
			if input.KeyCode == keyCode then
				enterFullscreen(viewKey)
				return
			end
		end
	end)

	-- if something swaps Workspace.CurrentCamera (cutscenes), Effects needs to recache baseline fov
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		Effects.updateStoredFov()
	end)

	-- late join: if the character already exists, run the same setup path
	if player.Character then
		onCharacterAdded(player.Character)
	end
	player.CharacterAdded:Connect(onCharacterAdded)
	player.CharacterRemoving:Connect(onCharacterRemoving)
end

return Controller
