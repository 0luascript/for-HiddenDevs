local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")

local player = Players.LocalPlayer

local TOGGLE_KEY = Enum.KeyCode.P

type ViewKey = "rear" | "side" | "top"

type ViewConfig = {
	subtitle: string,
	fullLabel: string,
	originOffset: Vector3,
	cameraOffset: Vector3,
	baseFov: number,
	wobbleAmp: number,
	wobbleSpeed: number,
	pulseAmp: number,
	pulseSpeed: number,
	pulsePhase: number,
}

local VIEW_CONFIGS: { [ViewKey]: ViewConfig } = {
	rear = {
		subtitle = "CAM 01 / REAR",
		fullLabel = "CAM 01 // REAR VIEW",
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
		subtitle = "CAM 02 / PROFILE",
		fullLabel = "CAM 02 // PROFILE VIEW",
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
		subtitle = "CAM 03 / OVERHEAD",
		fullLabel = "CAM 03 // OVERHEAD",
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

-- sets instance properties from a dictionary
local function setProps(inst: Instance, props: { [string]: any })
	for key, value in pairs(props) do
		(inst :: any)[key] = value
	end
end

-- creates an instance with optional props and parent
local function newInstance(className: string, props: { [string]: any }?, parent: Instance?): Instance
	local inst = Instance.new(className)
	if props then
		setProps(inst, props)
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

-- plays a tween and returns it
local function tween(inst: Instance, info: TweenInfo, props: { [string]: any })
	local t = TweenService:Create(inst, info, props)
	t:Play()
	return t
end

-- returns the current world camera
local function getWorldCamera(): Camera?
	return Workspace.CurrentCamera
end

type MaidTask = RBXScriptConnection | Instance | (() -> ()) | thread

local Maid = {}
Maid.__index = Maid

export type Maid = typeof(setmetatable({} :: { _tasks: { MaidTask } }, Maid))

-- creates a maid for cleanup
function Maid.new(): Maid
	return setmetatable({
		_tasks = {},
	}, Maid)
end

-- registers a cleanup task
function Maid.give(self: Maid, taskItem: MaidTask): MaidTask
	table.insert(self._tasks, taskItem)
	return taskItem
end

-- cleans up all registered tasks
function Maid.cleanup(self: Maid)
	for i = #self._tasks, 1, -1 do
		local taskItem = self._tasks[i]
		self._tasks[i] = nil

		local t = typeof(taskItem)
		if t == "RBXScriptConnection" then
			(taskItem :: RBXScriptConnection):Disconnect()
		elseif t == "Instance" then
			local inst = taskItem :: Instance
			if inst.Parent then
				inst:Destroy()
			end
		elseif t == "function" then
			(taskItem :: (() -> ()))()
		elseif t == "thread" then
			task.cancel(taskItem :: thread)
		end
	end
end

type RigPosePair = {
	original: BasePart,
	clone: BasePart,
}

type Rig = {
	key: ViewKey,
	world: WorldModel,
	model: Model,
	camera: Camera,
	rootClone: BasePart,
	posePairs: { RigPosePair },
}

local CctvController = {}
CctvController.__index = CctvController

export type CctvController = typeof(setmetatable({} :: {
	maid: Maid,
	sessionMaid: Maid?,

	uiEnabled: boolean,
	focusedViewKey: ViewKey?,

	character: Model?,
	humanoid: Humanoid?,
	rootPart: BasePart?,

	screenGui: ScreenGui?,
	holderFrame: Frame?,
	viewports: { [ViewKey]: ViewportFrame },

	fullFrame: Frame?,
	fullViewport: ViewportFrame?,

	rigs: { Rig },

	baseWorldFov: number?,
	cctvEffect: ColorCorrectionEffect?,

	uiAliveToken: number,
}, CctvController))

-- constructs the controller and binds events
function CctvController.new(): CctvController
	local self = setmetatable({
		maid = Maid.new(),
		sessionMaid = nil,

		uiEnabled = false,
		focusedViewKey = nil,

		character = nil,
		humanoid = nil,
		rootPart = nil,

		screenGui = nil,
		holderFrame = nil,
		viewports = {},

		fullFrame = nil,
		fullViewport = nil,

		rigs = {},

		baseWorldFov = nil,
		cctvEffect = nil,

		uiAliveToken = 0,
	}, CctvController)

	self:bindCharacter()
	self:bindInput()
	self:bindCameraWatcher()

	return self
end

-- refreshes cached character references
function CctvController.refreshCharacter(self: CctvController)
	self.character = player.Character
	if not self.character then
		self.humanoid = nil
		self.rootPart = nil
		return
	end

	self.humanoid = self.character:FindFirstChildOfClass("Humanoid")

	local hrp = self.character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		self.rootPart = hrp
	else
		self.rootPart = self.character.PrimaryPart
	end
end

-- binds character added/removing to rebuild rigs safely
function CctvController.bindCharacter(self: CctvController)
	local function onCharacterAdded(char: Model)
		self.character = char
		self.humanoid = char:FindFirstChildOfClass("Humanoid")

		local hrp = char:FindFirstChild("HumanoidRootPart")
		if hrp and hrp:IsA("BasePart") then
			self.rootPart = hrp
		else
			self.rootPart = char.PrimaryPart
		end

		if self.uiEnabled then
			self:clearFullscreen()
			self:buildAllRigs()
		end
	end

	local function onCharacterRemoving()
		self.character = nil
		self.humanoid = nil
		self.rootPart = nil

		self:clearFullscreen()
		self:destroyRigs()
	end

	if player.Character then
		onCharacterAdded(player.Character)
	end

	self.maid:give(player.CharacterAdded:Connect(onCharacterAdded))
	self.maid:give(player.CharacterRemoving:Connect(onCharacterRemoving))
end

-- tracks camera swaps to keep base fov accurate
function CctvController.bindCameraWatcher(self: CctvController)
	self.maid:give(Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		local cam = Workspace.CurrentCamera
		if cam then
			self.baseWorldFov = cam.FieldOfView
		end
	end))
end

-- ensures the lighting effect exists while the hud is enabled
function CctvController.ensureCctvEffect(self: CctvController)
	if self.cctvEffect and self.cctvEffect.Parent then
		return
	end

	local effect = newInstance("ColorCorrectionEffect", {
		Name = "CCTVColor",
		Brightness = -0.03,
		Contrast = 0.25,
		Saturation = -0.2,
		TintColor = Color3.fromRGB(230, 235, 255),
	}, Lighting) :: ColorCorrectionEffect

	self.cctvEffect = effect

	if self.sessionMaid then
		self.sessionMaid:give(effect)
	end
end

-- builds the subtitle string for the header
local function buildSubtitle(): string
	return string.format(
		"%s   •   %s   •   %s",
		VIEW_CONFIGS.rear.subtitle,
		VIEW_CONFIGS.side.subtitle,
		VIEW_CONFIGS.top.subtitle
	)
end

-- builds the hud gui and viewports
function CctvController.buildUi(self: CctvController)
	if self.screenGui and self.screenGui.Parent then
		return
	end

	local playerGui = player:WaitForChild("PlayerGui")

	local screenGui = newInstance("ScreenGui", {
		Name = "CCTVHud",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
	}, playerGui) :: ScreenGui
	self.screenGui = screenGui

	local holderFrame = newInstance("Frame", {
		Name = "Holder",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -24, 1, -24),
		Size = UDim2.new(0, 540, 0, 220),
		BackgroundColor3 = Color3.fromRGB(4, 4, 8),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
	}, screenGui) :: Frame
	self.holderFrame = holderFrame

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
		Size = UDim2.new(0.65, 0, 0, 20),
		Position = UDim2.new(0, 0, 0, 0),
		Font = Enum.Font.GothamMedium,
		Text = "CCTV // MULTI-FEED",
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Color3.fromRGB(235, 235, 245),
		TextSize = 14,
		TextTransparency = 1,
	}, holderFrame) :: TextLabel

	local subtitle = newInstance("TextLabel", {
		Name = "Subtitle",
		BackgroundTransparency = 1,
		Size = UDim2.new(0.8, 0, 0, 16),
		Position = UDim2.new(0, 0, 0, 18),
		Font = Enum.Font.Gotham,
		Text = buildSubtitle(),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Color3.fromRGB(170, 170, 190),
		TextSize = 11,
		TextTransparency = 1,
	}, holderFrame) :: TextLabel

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
	}, holderFrame) :: TextLabel

	local recDot = newInstance("Frame", {
		Name = "RecDot",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -36, 0.5, 0),
		Size = UDim2.new(0, 8, 0, 8),
		BackgroundColor3 = Color3.fromRGB(255, 70, 70),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
	}, holderFrame) :: Frame

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
	}, holderFrame) :: TextLabel

	local vpHolder = newInstance("Frame", {
		Name = "ViewportHolder",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.new(0, 0, 0, 40),
		Size = UDim2.new(1, 0, 1, -48),
	}, holderFrame) :: Frame

	newInstance("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 6),
	}, vpHolder)

	local function makeViewport(parentInst: Instance): ViewportFrame
		local vp = newInstance("ViewportFrame", {
			Name = "View",
			BackgroundColor3 = Color3.fromRGB(10, 10, 16),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = UDim2.new(0.33, -4, 1, 0),
			LightColor = Color3.fromRGB(255, 255, 255),
			LightDirection = Vector3.new(-0.6, -1, -0.4),
			Ambient = Color3.fromRGB(70, 70, 90),
		}, parentInst) :: ViewportFrame

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

	self.viewports = {
		rear = makeViewport(vpHolder),
		side = makeViewport(vpHolder),
		top = makeViewport(vpHolder),
	}

	local fadeInInfo = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	tween(holderFrame, fadeInInfo, { BackgroundTransparency = 0.08 })
	tween(title, fadeInInfo, { TextTransparency = 0 })
	tween(subtitle, fadeInInfo, { TextTransparency = 0.1 })
	tween(recLabel, fadeInInfo, { TextTransparency = 0 })
	tween(recDot, fadeInInfo, { BackgroundTransparency = 0 })
	tween(timeLabel, fadeInInfo, { TextTransparency = 0 })

	for _, vp in pairs(self.viewports) do
		tween(vp, fadeInInfo, { BackgroundTransparency = 0 })
	end

	self.uiAliveToken += 1
	local myToken = self.uiAliveToken

	local blinkThread = task.spawn(function()
		while self.uiEnabled and self.screenGui and myToken == self.uiAliveToken do
			recDot.BackgroundTransparency = 0
			task.wait(0.6)
			recDot.BackgroundTransparency = 0.5
			task.wait(0.4)
		end
	end)

	local clockStart = os.clock()
	local clockThread = task.spawn(function()
		while self.uiEnabled and self.screenGui and myToken == self.uiAliveToken do
			local elapsed = math.max(0, math.floor(os.clock() - clockStart))
			local s = elapsed % 60
			local m = math.floor(elapsed / 60) % 60
			local h = math.floor(elapsed / 3600)
			timeLabel.Text = string.format("%02d:%02d:%02d", h, m, s)
			task.wait(0.25)
		end
	end)

	if self.sessionMaid then
		self.sessionMaid:give(screenGui)
		self.sessionMaid:give(blinkThread)
		self.sessionMaid:give(clockThread)
	end
end

-- fades out and destroys the gui
function CctvController.fadeUiOut(self: CctvController)
	if not self.screenGui or not self.holderFrame then
		return
	end

	local holderFrame = self.holderFrame
	local info = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

	tween(holderFrame, info, { BackgroundTransparency = 1 })
	for _, vp in pairs(self.viewports) do
		tween(vp, info, { BackgroundTransparency = 1 })
	end

	local gui = self.screenGui
	task.delay(0.22, function()
		if gui and gui.Parent then
			gui:Destroy()
		end
	end)

	self.screenGui = nil
	self.holderFrame = nil
	self.viewports = {}
end

-- builds a cloned rig and camera for a given view
function CctvController.buildRig(self: CctvController, viewKey: ViewKey): Rig?
	self:refreshCharacter()
	if not self.character or not self.rootPart then
		return nil
	end

	local viewport = self.viewports[viewKey]
	if not viewport then
		return nil
	end

	local world = newInstance("WorldModel", {
		Name = "CctvWorld_" .. viewKey,
	}, viewport) :: WorldModel

	local rigModel = newInstance("Model", {
		Name = "CctvRig_" .. viewKey,
	}, world) :: Model

	local posePairs: { RigPosePair } = {}
	local rootClone: BasePart? = nil

	for _, inst in ipairs(self.character:GetDescendants()) do
		if inst:IsA("BasePart") then
			local original = inst :: BasePart

			local clone = newInstance("Part", {
				Name = original.Name,
				Size = original.Size,
				Anchored = true,
				CanCollide = false,
				Material = Enum.Material.SmoothPlastic,
				Color = Color3.fromRGB(235, 235, 235),
				Transparency = 0.18,
				CastShadow = false,
				CFrame = original.CFrame,
			}, rigModel) :: Part

			table.insert(posePairs, {
				original = original,
				clone = clone,
			})

			if original == self.rootPart then
				rootClone = clone
			end
		end
	end

	if not rootClone then
		rootClone = newInstance("Part", {
			Name = "RootClone",
			Size = Vector3.new(2, 2, 1),
			Anchored = true,
			CanCollide = false,
			Material = Enum.Material.SmoothPlastic,
			Color = Color3.fromRGB(235, 235, 235),
			Transparency = 0.18,
			CastShadow = false,
			CFrame = self.rootPart.CFrame,
		}, rigModel) :: Part
	end

	local cam = newInstance("Camera", {
		Name = "CctvCam_" .. viewKey,
		FieldOfView = 45,
	}, world) :: Camera

	viewport.CurrentCamera = cam

	return {
		key = viewKey,
		world = world,
		model = rigModel,
		camera = cam,
		rootClone = rootClone,
		posePairs = posePairs,
	}
end

-- destroys all rigs and clears the array
function CctvController.destroyRigs(self: CctvController)
	for _, rig in ipairs(self.rigs) do
		if rig.world and rig.world.Parent then
			rig.world:Destroy()
		end
	end
	self.rigs = {}
end

-- builds rear/side/top rigs
function CctvController.buildAllRigs(self: CctvController)
	self:destroyRigs()

	local ordered: { ViewKey } = { "rear", "side", "top" }
	for _, key in ipairs(ordered) do
		local rig = self:buildRig(key)
		if rig then
			table.insert(self.rigs, rig)
		end
	end
end

-- updates cloned poses and camera transforms each frame
function CctvController.updateRigs(self: CctvController, dt: number)
	if not self.uiEnabled then
		return
	end
	if #self.rigs == 0 then
		return
	end
	if not self.character or not self.character.Parent then
		return
	end
	if not self.rootPart or not self.rootPart.Parent then
		return
	end

	for _, rig in ipairs(self.rigs) do
		for i = 1, #rig.posePairs do
			local pair = rig.posePairs[i]
			if pair.original.Parent and pair.clone.Parent then
				pair.clone.CFrame = pair.original.CFrame
			end
		end
	end

	local now = os.clock()

	for _, rig in ipairs(self.rigs) do
		local cfg = VIEW_CONFIGS[rig.key]
		local rootPos = rig.rootClone.Position
		local origin = rootPos + cfg.originOffset

		local wobble = cfg.wobbleAmp * math.sin(now * cfg.wobbleSpeed + cfg.pulsePhase)
		local camPos = origin + cfg.cameraOffset + Vector3.new(0, wobble, 0)

		rig.camera.CFrame = rig.camera.CFrame:Lerp(
			CFrame.new(camPos, origin),
			math.clamp(dt * 10, 0, 1)
		)

		local pulse = cfg.pulseAmp * math.sin(now * cfg.pulseSpeed + cfg.pulsePhase)
		rig.camera.FieldOfView = cfg.baseFov + pulse
	end
end

-- starts the per-frame update connection
function CctvController.startRenderLoop(self: CctvController)
	if not self.sessionMaid then
		return
	end

	local preRender = (RunService :: any).PreRender
	local steppedEvent: RBXScriptSignal = if preRender then preRender else RunService.RenderStepped

	local conn = steppedEvent:Connect(function(dt: number)
		self:updateRigs(dt)
	end)

	self.sessionMaid:give(conn)
end

-- pulses the world camera fov when enabling the hud
function CctvController.pulseWorldCamera(self: CctvController)
	local cam = getWorldCamera()
	if not cam then
		return
	end

	self.baseWorldFov = self.baseWorldFov or cam.FieldOfView

	local upInfo = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local downInfo = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

	local up = TweenService:Create(cam, upInfo, { FieldOfView = (self.baseWorldFov :: number) + 6 })
	local down = TweenService:Create(cam, downInfo, { FieldOfView = self.baseWorldFov :: number })

	up.Completed:Connect(function()
		down:Play()
	end)

	up:Play()
end

-- restores the world camera fov
function CctvController.resetWorldFov(self: CctvController)
	local cam = getWorldCamera()
	if not cam or not self.baseWorldFov then
		return
	end

	local info = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	tween(cam, info, { FieldOfView = self.baseWorldFov })
end

-- exits fullscreen mode and restores the small viewport
function CctvController.clearFullscreen(self: CctvController)
	local focused = self.focusedViewKey
	if not focused then
		return
	end

	if self.fullViewport then
		self.fullViewport.CurrentCamera = nil
	end

	for _, rig in ipairs(self.rigs) do
		if rig.key == focused then
			local smallViewport = self.viewports[focused]
			if smallViewport then
				rig.world.Parent = smallViewport
				smallViewport.CurrentCamera = rig.camera
			end
			break
		end
	end

	if self.fullFrame and self.fullFrame.Parent then
		self.fullFrame:Destroy()
	end

	self.fullFrame = nil
	self.fullViewport = nil
	self.focusedViewKey = nil
end

-- enters fullscreen mode for a view or toggles it off
function CctvController.enterFocus(self: CctvController, viewKey: ViewKey)
	if not self.uiEnabled or not self.screenGui then
		return
	end

	if self.focusedViewKey == viewKey then
		self:clearFullscreen()
		return
	end

	self:clearFullscreen()

	local fullFrame = newInstance("Frame", {
		Name = "FullCCTV",
		Size = UDim2.new(1, 0, 1, 0),
		Position = UDim2.new(0, 0, 0, 0),
		BackgroundColor3 = Color3.fromRGB(0, 0, 0),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ZIndex = 5,
	}, self.screenGui) :: Frame

	local fullViewport = newInstance("ViewportFrame", {
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
	}, fullFrame) :: ViewportFrame

	newInstance("UICorner", {
		CornerRadius = UDim.new(0, 10),
	}, fullViewport)

	newInstance("UIStroke", {
		Thickness = 2,
		Color = Color3.fromRGB(230, 230, 240),
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Transparency = 0.15,
	}, fullViewport)

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
		Text = VIEW_CONFIGS[viewKey].fullLabel,
	}, fullFrame)

	local exitKeyText = if viewKey == "rear" then "1"
		elseif viewKey == "side" then "2"
		else "3"

	newInstance("TextLabel", {
		Name = "Hint",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -24, 1, -18),
		Size = UDim2.new(0, 220, 0, 18),
		Font = Enum.Font.Gotham,
		Text = "PRESS " .. exitKeyText .. " TO EXIT",
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = Color3.fromRGB(200, 200, 220),
		TextSize = 11,
		TextTransparency = 0.1,
		ZIndex = 7,
	}, fullFrame)

	self.fullFrame = fullFrame
	self.fullViewport = fullViewport

	for _, rig in ipairs(self.rigs) do
		if rig.key == viewKey then
			rig.world.Parent = fullViewport
			fullViewport.CurrentCamera = rig.camera
			break
		end
	end

	local info = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	tween(fullFrame, info, { BackgroundTransparency = 0.3 })

	self.focusedViewKey = viewKey
end

-- enables the hud, builds ui/rigs, and starts updates
function CctvController.enable(self: CctvController)
	if self.uiEnabled then
		return
	end

	self:refreshCharacter()
	if not self.character or not self.rootPart then
		return
	end

	self.uiEnabled = true
	self.sessionMaid = Maid.new()

	self:ensureCctvEffect()
	self:buildUi()
	self:buildAllRigs()
	self:pulseWorldCamera()
	self:startRenderLoop()
end

-- disables the hud and cleans everything created during the session
function CctvController.disable(self: CctvController)
	if not self.uiEnabled then
		return
	end

	self.uiEnabled = false
	self.uiAliveToken += 1

	self:clearFullscreen()
	self:resetWorldFov()
	self:destroyRigs()
	self:fadeUiOut()

	if self.sessionMaid then
		self.sessionMaid:cleanup()
		self.sessionMaid = nil
	end

	self.cctvEffect = nil
end

-- toggles the hud on/off
function CctvController.toggle(self: CctvController)
	if self.uiEnabled then
		self:disable()
	else
		self:enable()
	end
end

-- binds key input for toggle and focus
function CctvController.bindInput(self: CctvController)
	self.maid:give(UserInputService.InputBegan:Connect(function(input: InputObject, gpe: boolean)
		if gpe then
			return
		end
		if input.UserInputType ~= Enum.UserInputType.Keyboard then
			return
		end

		if input.KeyCode == TOGGLE_KEY then
			self:toggle()
			return
		end

		if not self.uiEnabled then
			return
		end

		if input.KeyCode == Enum.KeyCode.One then
			self:enterFocus("rear")
		elseif input.KeyCode == Enum.KeyCode.Two then
			self:enterFocus("side")
		elseif input.KeyCode == Enum.KeyCode.Three then
			self:enterFocus("top")
		end
	end))
end

local controller = CctvController.new()
