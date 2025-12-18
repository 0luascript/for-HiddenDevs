local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")

local player = Players.LocalPlayer
local toggleKey = Enum.KeyCode.P

type ViewKey = "rear" | "side" | "top"

type ViewConfig = {
	fullLabel: string,
	hintKey: string,
	originOffset: Vector3,
	cameraOffset: Vector3,
	baseFov: number,
	wobbleAmp: number,
	wobbleSpeed: number,
	pulseAmp: number,
	pulseSpeed: number,
	pulsePhase: number,
}

local viewConfigs: { [ViewKey]: ViewConfig } = {
	rear = {
		fullLabel = "CAM 01 // REAR VIEW",
		hintKey = "1",
		originOffset = Vector3.new(0, 2, 0),
		cameraOffset = Vector3.new(0, 2.3, 4.6),
		baseFov = 47,
		wobbleAmp = 0.05,
		wobbleSpeed = 1.8,
		pulseAmp = 1.0,
		pulseSpeed = 2.8,
		pulsePhase = 0.0,
	},
	side = {
		fullLabel = "CAM 02 // PROFILE VIEW",
		hintKey = "2",
		originOffset = Vector3.new(0, 1.6, 0),
		cameraOffset = Vector3.new(5.2, 1.8, 0),
		baseFov = 52,
		wobbleAmp = 0.04,
		wobbleSpeed = 1.8,
		pulseAmp = 1.0,
		pulseSpeed = 2.8,
		pulsePhase = 1.0,
	},
	top = {
		fullLabel = "CAM 03 // OVERHEAD",
		hintKey = "3",
		originOffset = Vector3.new(0, 2.2, 0),
		cameraOffset = Vector3.new(0, 6, 0.001),
		baseFov = 40,
		wobbleAmp = 0.12,
		wobbleSpeed = 1.8,
		pulseAmp = 1.0,
		pulseSpeed = 2.8,
		pulsePhase = 2.0,
	},
}

local function getWorldCamera(): Camera?
	return Workspace.CurrentCamera
end

local function newInstance<T>(className: string, props: { [string]: any }?, parent: Instance?): T
	local inst = Instance.new(className)
	if props then
		for k, v in pairs(props) do
			(inst :: any)[k] = v
		end
	end
	if parent then
		inst.Parent = parent
	end
	return inst :: any
end

local function playTween(inst: Instance, info: TweenInfo, props: { [string]: any })
	local t = TweenService:Create(inst, info, props)
	t:Play()
	return t
end

local function clamp01(x: number): number
	return math.clamp(x, 0, 1)
end

local currentChar: Model?
local humanoid: Humanoid?
local rootPart: BasePart?

local uiEnabled = false

local screenGui: ScreenGui?
local holderFrame: Frame?
local viewports: { [ViewKey]: ViewportFrame } = {}

local rigs: {
	{
		key: ViewKey,
		world: WorldModel,
		model: Model,
		partMap: { [BasePart]: BasePart },
		rootClone: BasePart,
		camera: Camera,
	}
} = {}

local renderConn: RBXScriptConnection?
local baseWorldFov: number?
local cctvEffect: ColorCorrectionEffect?

local focusedViewKey: ViewKey?
local fullFrame: Frame?
local fullViewport: ViewportFrame?

local uiSessionId = 0

-- refreshCharacter exists so the update loop can assume cached references instead of searching every frame
local function refreshCharacter()
	currentChar = player.Character
	if not currentChar then
		humanoid = nil
		rootPart = nil
		return
	end

	humanoid = currentChar:FindFirstChildOfClass("Humanoid")

	local hrp = currentChar:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		rootPart = hrp
	else
		rootPart = currentChar.PrimaryPart
	end
end

-- ensureCctvEffect exists so the “cctv look” is applied consistently and removed cleanly on disable
local function ensureCctvEffect()
	if cctvEffect and cctvEffect.Parent then
		return
	end

	cctvEffect = newInstance("ColorCorrectionEffect", {
		Name = "CCTVColor",
		Brightness = -0.03,
		Contrast = 0.25,
		Saturation = -0.2,
		TintColor = Color3.fromRGB(230, 235, 255),
	}, Lighting)
end

-- destroyRigs exists so toggling never leaves hidden geometry in memory
local function destroyRigs()
	for _, rig in ipairs(rigs) do
		if rig.world and rig.world.Parent then
			rig.world:Destroy()
		end
	end
	table.clear(rigs)
end

-- destroyUi exists so disabling returns PlayerGui to its original state
local function destroyUi()
	if screenGui and screenGui.Parent then
		screenGui:Destroy()
	end
	screenGui = nil
	holderFrame = nil
	table.clear(viewports)
	fullFrame = nil
	fullViewport = nil
end

-- clearFullscreen exists so we always reparent the active world back before destroying the overlay
local function clearFullscreen()
	if not focusedViewKey then
		return
	end

	if fullViewport then
		fullViewport.CurrentCamera = nil
	end

	for _, rig in ipairs(rigs) do
		if rig.key == focusedViewKey then
			local smallViewport = viewports[focusedViewKey]
			if smallViewport then
				rig.world.Parent = smallViewport
				smallViewport.CurrentCamera = rig.camera
			end
			break
		end
	end

	if fullFrame then
		fullFrame:Destroy()
	end

	fullFrame = nil
	fullViewport = nil
	focusedViewKey = nil
end

-- buildUi exists so runtime logic can assume viewports are present and named consistently
local function buildUi()
	if screenGui and screenGui.Parent then
		return
	end

	local playerGui = player:WaitForChild("PlayerGui")

	screenGui = newInstance("ScreenGui", {
		Name = "CCTVHud",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
	}, playerGui)

	holderFrame = newInstance("Frame", {
		Name = "Holder",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -24, 1, -24),
		Size = UDim2.new(0, 540, 0, 220),
		BackgroundColor3 = Color3.fromRGB(4, 4, 8),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
	}, screenGui)

	newInstance("UIStroke", {
		Thickness = 2,
		Color = Color3.fromRGB(235, 235, 245),
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, holderFrame)

	newInstance("UICorner", {
		CornerRadius = UDim.new(0, 10),
	}, holderFrame)

	newInstance("UIPadding", {
		PaddingTop = UDim.new(0, 8),
		PaddingBottom = UDim.new(0, 8),
		PaddingLeft = UDim.new(0, 10),
		PaddingRight = UDim.new(0, 10),
	}, holderFrame)

	local title = newInstance("TextLabel", {
		Name = "Title",
		BackgroundTransparency = 1,
		Size = UDim2.new(0.6, 0, 0, 20),
		Position = UDim2.new(0, 0, 0, 0),
		Font = Enum.Font.GothamMedium,
		Text = "CCTV // MULTI-FEED",
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Color3.fromRGB(235, 235, 245),
		TextSize = 14,
		TextTransparency = 1,
	}, holderFrame)

	local subtitle = newInstance("TextLabel", {
		Name = "Subtitle",
		BackgroundTransparency = 1,
		Size = UDim2.new(0.9, 0, 0, 16),
		Position = UDim2.new(0, 0, 0, 18),
		Font = Enum.Font.Gotham,
		Text = "CAM 01 / REAR   •   CAM 02 / PROFILE   •   CAM 03 / OVERHEAD",
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Color3.fromRGB(170, 170, 190),
		TextSize = 11,
		TextTransparency = 1,
	}, holderFrame)

	local recLabel = newInstance("TextLabel", {
		Name = "RecLabel",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 0),
		Size = UDim2.new(0, 60, 0, 20),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		Text = "REC",
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = Color3.fromRGB(255, 255, 255),
		TextSize = 11,
		TextTransparency = 1,
	}, holderFrame)

	local recDot = newInstance("Frame", {
		Name = "RecDot",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -36, 0.5, 0),
		Size = UDim2.new(0, 8, 0, 8),
		BackgroundColor3 = Color3.fromRGB(255, 70, 70),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
	}, holderFrame)

	newInstance("UICorner", {
		CornerRadius = UDim.new(1, 0),
	}, recDot)

	local timeLabel = newInstance("TextLabel", {
		Name = "Clock",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 18),
		Size = UDim2.new(0, 90, 0, 16),
		BackgroundTransparency = 1,
		Font = Enum.Font.Code,
		Text = "00:00:00",
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = Color3.fromRGB(200, 200, 220),
		TextSize = 11,
		TextTransparency = 1,
	}, holderFrame)

	local vpHolder = newInstance("Frame", {
		Name = "ViewportHolder",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.new(0, 0, 0, 40),
		Size = UDim2.new(1, 0, 1, -48),
	}, holderFrame)

	newInstance("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 6),
	}, vpHolder)

	local function makeViewport(): ViewportFrame
		local vp = newInstance("ViewportFrame", {
			Name = "View",
			BackgroundColor3 = Color3.fromRGB(10, 10, 16),
			BorderSizePixel = 0,
			Size = UDim2.new(0.33, -4, 1, 0),
			BackgroundTransparency = 1,

			-- setting these avoids “everything is black” when a feed has geometry but no usable light
			LightColor = Color3.fromRGB(255, 255, 255),
			LightDirection = Vector3.new(-0.6, -1, -0.4),
			Ambient = Color3.fromRGB(70, 70, 90),
		}, vpHolder)

		newInstance("UICorner", {
			CornerRadius = UDim.new(0, 8),
		}, vp)

		newInstance("UIStroke", {
			Thickness = 1,
			Color = Color3.fromRGB(200, 200, 220),
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Transparency = 0.2,
		}, vp)

		return vp
	end

	viewports = {
		rear = makeViewport(),
		side = makeViewport(),
		top = makeViewport(),
	}

	local ti = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	playTween(holderFrame, ti, { BackgroundTransparency = 0.08 })
	for _, vp in pairs(viewports) do
		playTween(vp, ti, { BackgroundTransparency = 0 })
	end
	playTween(title, ti, { TextTransparency = 0 })
	playTween(subtitle, ti, { TextTransparency = 0.1 })
	playTween(recLabel, ti, { TextTransparency = 0 })
	playTween(recDot, ti, { BackgroundTransparency = 0 })
	playTween(timeLabel, ti, { TextTransparency = 0 })

	uiSessionId += 1
	local mySession = uiSessionId

	-- running ui loops behind a session token avoids leftover threads after fast toggles
	task.spawn(function()
		while uiEnabled and screenGui and mySession == uiSessionId do
			recDot.BackgroundTransparency = 0
			task.wait(0.6)
			recDot.BackgroundTransparency = 0.5
			task.wait(0.4)
		end
	end)

	local startClock = os.clock()
	task.spawn(function()
		while uiEnabled and screenGui and mySession == uiSessionId do
			local t = math.max(0, math.floor(os.clock() - startClock))
			local s = t % 60
			local m = math.floor(t / 60) % 60
			local h = math.floor(t / 3600)
			timeLabel.Text = string.format("%02d:%02d:%02d", h, m, s)
			task.wait(0.25)
		end
	end)
end

-- fadeUiOut exists so disabling feels intentional and does not pop ui instantly
local function fadeUiOut()
	if not screenGui or not holderFrame then
		destroyUi()
		return
	end

	local ti = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	playTween(holderFrame, ti, { BackgroundTransparency = 1 })
	for _, vp in pairs(viewports) do
		playTween(vp, ti, { BackgroundTransparency = 1 })
	end

	task.delay(0.22, function()
		destroyUi()
	end)
end

-- createClonePart exists to avoid cloning live parts (which can inherit invisibility modifiers)
local function createClonePart(original: BasePart, parentModel: Model): BasePart
	local clone = newInstance("Part", {
		Name = original.Name,
		Size = original.Size,
		Anchored = true,
		CanCollide = false,
		CanTouch = false,
		CanQuery = false,
		Massless = true,
		Material = Enum.Material.SmoothPlastic,
		Color = Color3.fromRGB(235, 235, 235),
		Transparency = 0.18,
		CastShadow = false,
		CFrame = original.CFrame,
	}, parentModel)

	return clone
end

-- buildRig exists to keep each viewport isolated with its own world and camera
local function buildRig(viewKey: ViewKey)
	refreshCharacter()
	if not currentChar or not rootPart then
		return nil
	end

	local viewport = viewports[viewKey]
	if not viewport then
		return nil
	end

	local world = newInstance("WorldModel", {
		Name = "CCTVWorld_" .. viewKey,
	}, viewport)

	local rigModel = newInstance("Model", {
		Name = "CCTVRig_" .. viewKey,
	}, world)

	local partMap: { [BasePart]: BasePart } = {}
	local rootClone: BasePart? = nil

	for _, inst in ipairs(currentChar:GetDescendants()) do
		if inst:IsA("BasePart") then
			local original = inst :: BasePart
			local clone = createClonePart(original, rigModel)
			partMap[original] = clone

			if original == rootPart then
				rootClone = clone
			end
		end
	end

	-- rootClone is required for camera math, so we guarantee it even if the rig scan missed it
	if not rootClone then
		rootClone = createClonePart(rootPart, rigModel)
		rootClone.Name = "RootClone"
	end

	local cam = newInstance("Camera", {
		Name = "CCTVCam_" .. viewKey,
		FieldOfView = 45,
	}, world)

	viewport.CurrentCamera = cam

	return {
		key = viewKey,
		world = world,
		model = rigModel,
		partMap = partMap,
		rootClone = rootClone,
		camera = cam,
	}
end

-- buildAllRigs exists to ensure the 3 feeds are created together so the ui always matches state
local function buildAllRigs()
	destroyRigs()
	if not (viewports.rear and viewports.side and viewports.top) then
		return
	end

	local rearRig = buildRig("rear")
	local sideRig = buildRig("side")
	local topRig = buildRig("top")

	if rearRig then
		table.insert(rigs, rearRig)
	end
	if sideRig then
		table.insert(rigs, sideRig)
	end
	if topRig then
		table.insert(rigs, topRig)
	end
end

-- updateRigs exists to sync the visual copies to the live character without touching real gameplay parts
local function updateRigs(dt: number)
	if not uiEnabled then
		return
	end
	if #rigs == 0 then
		return
	end
	if not currentChar or not currentChar.Parent then
		return
	end
	if not rootPart or not rootPart.Parent then
		return
	end

	for _, rig in ipairs(rigs) do
		for original, clone in pairs(rig.partMap) do
			if original.Parent and clone.Parent then
				clone.CFrame = original.CFrame
			end
		end
	end

	local now = os.clock()

	for _, rig in ipairs(rigs) do
		local cfg = viewConfigs[rig.key]
		local rootPos = rig.rootClone.Position
		local origin = rootPos + cfg.originOffset

		local wobble = cfg.wobbleAmp * math.sin(now * cfg.wobbleSpeed + cfg.pulsePhase)
		local camPos = origin + cfg.cameraOffset + Vector3.new(0, wobble, 0)

		-- lerp keeps feeds stable across variable fps while still tracking movement quickly
		rig.camera.CFrame = rig.camera.CFrame:Lerp(
			CFrame.new(camPos, origin),
			clamp01(dt * 10)
		)

		local pulse = cfg.pulseAmp * math.sin(now * cfg.pulseSpeed + cfg.pulsePhase)
		rig.camera.FieldOfView = cfg.baseFov + pulse
	end
end

-- pulseWorldCamera exists to signal mode entry without permanently changing player camera settings
local function pulseWorldCamera()
	local cam = getWorldCamera()
	if not cam then
		return
	end

	baseWorldFov = baseWorldFov or cam.FieldOfView

	local upInfo = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local downInfo = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

	local up = TweenService:Create(cam, upInfo, { FieldOfView = (baseWorldFov :: number) + 6 })
	local down = TweenService:Create(cam, downInfo, { FieldOfView = baseWorldFov :: number })

	up.Completed:Connect(function()
		down:Play()
	end)

	up:Play()
end

-- resetWorldFov exists to guarantee the script never leaves the main camera modified on exit
local function resetWorldFov()
	local cam = getWorldCamera()
	if not cam or not baseWorldFov then
		return
	end

	local ti = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	playTween(cam, ti, { FieldOfView = baseWorldFov })
end

-- enterFocus exists so fullscreen reuses the same world, preventing mismatched feed state
local function enterFocus(viewKey: ViewKey)
	if not uiEnabled or not screenGui or not holderFrame then
		return
	end

	if focusedViewKey == viewKey then
		clearFullscreen()
		return
	end

	clearFullscreen()

	fullFrame = newInstance("Frame", {
		Name = "FullCCTV",
		Size = UDim2.new(1, 0, 1, 0),
		Position = UDim2.new(0, 0, 0, 0),
		BackgroundColor3 = Color3.fromRGB(0, 0, 0),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ZIndex = 5,
	}, screenGui)

	fullViewport = newInstance("ViewportFrame", {
		Name = "FullViewport",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 0),
		Size = UDim2.new(0.7, 0, 0.7, 0),
		BackgroundColor3 = Color3.fromRGB(5, 5, 10),
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
		LightColor = Color3.fromRGB(255, 255, 255),
		LightDirection = Vector3.new(-0.6, -1, -0.4),
		Ambient = Color3.fromRGB(70, 70, 90),
		ZIndex = 6,
	}, fullFrame)

	newInstance("UICorner", { CornerRadius = UDim.new(0, 10) }, fullViewport)
	newInstance("UIStroke", {
		Thickness = 2,
		Color = Color3.fromRGB(230, 230, 240),
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Transparency = 0.15,
	}, fullViewport)

	local cfg = viewConfigs[viewKey]

	newInstance("TextLabel", {
		Name = "OverlayLabel",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -30, 0, 24),
		Position = UDim2.new(0, 20, 0, 14),
		Font = Enum.Font.GothamMedium,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Color3.fromRGB(230, 230, 240),
		TextSize = 16,
		ZIndex = 7,
		Text = cfg.fullLabel,
	}, fullFrame)

	newInstance("TextLabel", {
		Name = "Hint",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -24, 1, -18),
		Size = UDim2.new(0, 220, 0, 18),
		Font = Enum.Font.Gotham,
		Text = "PRESS " .. cfg.hintKey .. " TO EXIT",
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = Color3.fromRGB(200, 200, 220),
		TextSize = 11,
		TextTransparency = 0.1,
		ZIndex = 7,
	}, fullFrame)

	-- reparenting the active world avoids duplicating geometry for fullscreen and keeps fps stable
	for _, rig in ipairs(rigs) do
		if rig.key == viewKey then
			rig.world.Parent = fullViewport
			fullViewport.CurrentCamera = rig.camera
			break
		end
	end

	playTween(fullFrame, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		BackgroundTransparency = 0.3,
	})

	focusedViewKey = viewKey
end

-- enableHud exists to build all state in one place so toggling is predictable
local function enableHud()
	if uiEnabled then
		return
	end

	refreshCharacter()
	if not currentChar or not rootPart then
		return
	end

	uiEnabled = true
	ensureCctvEffect()
	buildUi()
	buildAllRigs()
	pulseWorldCamera()

	if renderConn then
		renderConn:Disconnect()
	end
	renderConn = RunService.RenderStepped:Connect(updateRigs)
end

-- disableHud exists to tear down in a safe order so nothing references destroyed instances
local function disableHud()
	if not uiEnabled then
		return
	end

	uiEnabled = false
	uiSessionId += 1

	if renderConn then
		renderConn:Disconnect()
		renderConn = nil
	end

	clearFullscreen()
	resetWorldFov()
	fadeUiOut()
	destroyRigs()

	if cctvEffect and cctvEffect.Parent then
		cctvEffect:Destroy()
	end
	cctvEffect = nil
end

local function toggleHud()
	if uiEnabled then
		disableHud()
	else
		enableHud()
	end
end

-- character hooks exist so the hud stays correct after respawn without requiring a script restart
local function onCharacterAdded(char: Model)
	currentChar = char
	humanoid = char:FindFirstChildOfClass("Humanoid")

	local hrp = char:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		rootPart = hrp
	else
		rootPart = char.PrimaryPart
	end

	if uiEnabled then
		buildAllRigs()
	end
end

local function onCharacterRemoving()
	currentChar = nil
	humanoid = nil
	rootPart = nil

	clearFullscreen()
	destroyRigs()
end

if player.Character then
	onCharacterAdded(player.Character)
end

player.CharacterAdded:Connect(onCharacterAdded)
player.CharacterRemoving:Connect(onCharacterRemoving)

-- input handler is kept small so it’s obvious which keys can affect state
UserInputService.InputBegan:Connect(function(input: InputObject, gpe: boolean)
	if gpe then
		return
	end
	if input.UserInputType ~= Enum.UserInputType.Keyboard then
		return
	end

	if input.KeyCode == toggleKey then
		toggleHud()
		return
	end

	if not uiEnabled then
		return
	end

	if input.KeyCode == Enum.KeyCode.One then
		enterFocus("rear")
	elseif input.KeyCode == Enum.KeyCode.Two then
		enterFocus("side")
	elseif input.KeyCode == Enum.KeyCode.Three then
		enterFocus("top")
	end
end)

-- camera watcher exists so fov reset targets the correct camera even if Roblox swaps CurrentCamera
Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	local cam = Workspace.CurrentCamera
	if cam then
		baseWorldFov = cam.FieldOfView
	end
end)
