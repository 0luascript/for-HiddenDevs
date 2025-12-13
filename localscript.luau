-- Astral projection for HD APPROVE ME PLEASE
-- Press R to leave your body and fly a ghost out of body camera

local players = game:GetService("Players")
local runService = game:GetService("RunService")
local userInputService = game:GetService("UserInputService")
local tweenService = game:GetService("TweenService")
local debris = game:GetService("Debris")

local player = players.LocalPlayer
local camera = workspace.CurrentCamera

local astralKey = Enum.KeyCode.R

-- basic astral state
local astralActive = false
local astralPos
local astralStartTime = 0
local maxAstralTime = 12

-- ghost rig + tether
local ghostModel
local ghostRootPart
local ghostParts = {}
local bodyAttachment
local ghostAttachment
local tetherBeam

-- character state backup
local humanoid
local rootPart
local savedWalkSpeed
local savedJumpPower
local savedAutoRotate
local savedPlatformStand
local savedRootAnchored
local animateScript
local savedAnimateDisabled

-- camera state backup
local originalCameraType
local originalCameraSubject
local originalMouseBehavior
local originalMouseIcon
local originalFov

-- keyboard input for ghost movement
local keyDown = {
	w = false,
	a = false,
	s = false,
	d = false,
	space = false,
	shift = false
}

-- ghost look direction
local yaw = 0
local pitch = 0

-- connections to cleanly disconnect on exit
local renderConn
local mouseConn
local charRemovingConn

-- small glass burst when you leave the body
local function spawnShards(position)
	for i = 1, 18 do
		local p = Instance.new("Part")
		p.Size = Vector3.new(0.16, 0.16, math.random(12, 24) / 10)
		p.Anchored = true
		p.CanCollide = false
		p.Material = Enum.Material.Glass
		p.Color = Color3.fromRGB(210, 230, 255)
		p.Transparency = 0.25
		p.CastShadow = false
		p.CFrame = CFrame.new(position)
		p.Parent = workspace

		local dir = Vector3.new(
			math.random() - 0.5,
			math.random() - 0.2,
			math.random() - 0.5
		).Unit

		local dist = math.random(8, 16) / 2
		local targetPos = position + dir * dist

		local tween = tweenService:Create(
			p,
			TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{
				CFrame = CFrame.new(targetPos) * CFrame.Angles(math.random(), math.random(), math.random()),
				Transparency = 1
			}
		)
		tween:Play()
		debris:AddItem(p, 0.45)
	end
end


local function destroyGhost()
	if ghostModel then
		for _, info in ipairs(ghostParts) do
			if info.ghost and info.ghost.Parent then
				tweenService:Create(
					info.ghost,
					TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{Transparency = 1}
				):Play()
			end
		end
		debris:AddItem(ghostModel, 0.25)
	end

	if tetherBeam then
		tweenService:Create(
			tetherBeam,
			TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{Width0 = 0, Width1 = 0}
		):Play()
		debris:AddItem(tetherBeam, 0.22)
	end

	if bodyAttachment then bodyAttachment:Destroy() end
	if ghostAttachment then ghostAttachment:Destroy() end

	ghostModel = nil
	ghostRootPart = nil
	ghostParts = {}
	bodyAttachment = nil
	ghostAttachment = nil
	tetherBeam = nil
end

-- clone the character into a static "ghost" rig
local function buildGhost()
	local character = player.Character
	if not character then return end
	rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return end

	ghostModel = Instance.new("Model")
	ghostModel.Name = "AstralGhost"
	ghostModel.Parent = workspace

	ghostParts = {}
	ghostRootPart = nil

	for _, part in ipairs(character:GetDescendants()) do
		if part:IsA("BasePart") then
			local ghostPart = Instance.new("Part")
			ghostPart.Size = part.Size
			ghostPart.Anchored = true
			ghostPart.CanCollide = false
			ghostPart.Material = Enum.Material.ForceField
			ghostPart.Color = Color3.fromRGB(190, 215, 255)
			ghostPart.CastShadow = false
			ghostPart.Transparency = 0.25
			ghostPart.Name = "Ghost_" .. part.Name
			ghostPart.CFrame = part.CFrame
			ghostPart.Parent = ghostModel

			local relative = rootPart.CFrame:ToObjectSpace(part.CFrame)
			table.insert(ghostParts, {
				ghost = ghostPart,
				relative = relative
			})

			if part == rootPart then
				ghostRootPart = ghostPart
			end
		end
	end

	-- fallback ghost root if it goes left
	if not ghostRootPart then
		ghostRootPart = Instance.new("Part")
		ghostRootPart.Size = Vector3.new(2, 2, 2)
		ghostRootPart.Anchored = true
		ghostRootPart.CanCollide = false
		ghostRootPart.Material = Enum.Material.ForceField
		ghostRootPart.Color = Color3.fromRGB(190, 215, 255)
		ghostRootPart.CastShadow = false
		ghostRootPart.Transparency = 0.25
		ghostRootPart.CFrame = rootPart.CFrame
		ghostRootPart.Name = "GhostRoot"
		ghostRootPart.Parent = ghostModel
		table.insert(ghostParts, {
			ghost = ghostRootPart,
			relative = CFrame.new()
		})
	end

	-- tether between body and ghost
	bodyAttachment = Instance.new("Attachment")
	bodyAttachment.Name = "AstralBodyAttachment"
	bodyAttachment.Parent = rootPart

	ghostAttachment = Instance.new("Attachment")
	ghostAttachment.Name = "AstralGhostAttachment"
	ghostAttachment.Parent = ghostRootPart

	tetherBeam = Instance.new("Beam")
	tetherBeam.Attachment0 = bodyAttachment
	tetherBeam.Attachment1 = ghostAttachment
	tetherBeam.FaceCamera = true
	tetherBeam.LightEmission = 1
	tetherBeam.LightInfluence = 0
	tetherBeam.Width0 = 0.2
	tetherBeam.Width1 = 0.2
	tetherBeam.Segments = 32
	tetherBeam.Color = ColorSequence.new(Color3.fromRGB(170, 210, 255), Color3.fromRGB(230, 150, 255))
	tetherBeam.Transparency = NumberSequence.new(0.2, 0.4)
	tetherBeam.CurveSize0 = 3
	tetherBeam.CurveSize1 = -3
	tetherBeam.Parent = ghostModel

	-- start ghost  above the body
	astralPos = rootPart.Position + rootPart.CFrame.LookVector * 7 + Vector3.new(0, 3, 0)

	local _, ry = rootPart.CFrame:ToEulerAnglesYXZ()
	yaw = ry
	pitch = 0
end

-- keep ghost rig posed relative to its own root
local function updateGhostCFrames(baseCFrame)
	for _, info in ipairs(ghostParts) do
		if info.ghost and info.ghost.Parent then
			info.ghost.CFrame = baseCFrame * info.relative
		end
	end
end

-- freeze or unfreeze the real character while in ghost mode
local function setCharacterFrozen(state)
	local character = player.Character
	if not character then return end
	humanoid = character:FindFirstChildOfClass("Humanoid")
	rootPart = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not rootPart then return end

	if state then
		-- save original movement values
		savedWalkSpeed = humanoid.WalkSpeed
		savedJumpPower = humanoid.JumpPower
		savedAutoRotate = humanoid.AutoRotate
		savedPlatformStand = humanoid.PlatformStand

		-- lock body in place
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
		humanoid.AutoRotate = false
		humanoid.PlatformStand = true
		humanoid:Move(Vector3.new(), false)

		for _, track in ipairs(humanoid:GetPlayingAnimationTracks()) do
			track:Stop(0.1)
		end

		savedRootAnchored = rootPart.Anchored
		rootPart.Anchored = true

		animateScript = character:FindFirstChild("Animate")
		if animateScript then
			savedAnimateDisabled = animateScript.Disabled
			animateScript.Disabled = true
		end
	else
		-- restore character movement
		if humanoid and humanoid.Parent then
			if savedWalkSpeed then humanoid.WalkSpeed = savedWalkSpeed end
			if savedJumpPower then humanoid.JumpPower = savedJumpPower end
			if savedAutoRotate ~= nil then humanoid.AutoRotate = savedAutoRotate end
			if savedPlatformStand ~= nil then
				humanoid.PlatformStand = savedPlatformStand
			else
				humanoid.PlatformStand = false
			end
			humanoid:Move(Vector3.new(), false)
		end

		if rootPart and rootPart.Parent then
			if savedRootAnchored ~= nil then
				rootPart.Anchored = savedRootAnchored
			else
				rootPart.Anchored = false
			end
		end

		if animateScript and animateScript.Parent then
			if savedAnimateDisabled ~= nil then
				animateScript.Disabled = savedAnimateDisabled
			else
				animateScript.Disabled = false
			end
		end

		-- clear cached values
		savedWalkSpeed = nil
		savedJumpPower = nil
		savedAutoRotate = nil
		savedPlatformStand = nil
		savedRootAnchored = nil
		animateScript = nil
		savedAnimateDisabled = nil
	end
end

-- fully exit astral mode and restore everything back to normal
local function stopAstral()
	if not astralActive then return end
	astralActive = false

	if renderConn then
		renderConn:Disconnect()
		renderConn = nil
	end
	if mouseConn then
		mouseConn:Disconnect()
		mouseConn = nil
	end
	if charRemovingConn then
		charRemovingConn:Disconnect()
		charRemovingConn = nil
	end

	setCharacterFrozen(false)

	if camera then
		if originalCameraType then camera.CameraType = originalCameraType end
		if originalCameraSubject then camera.CameraSubject = originalCameraSubject end
		if originalFov then camera.FieldOfView = originalFov end
	end

	if userInputService then
		userInputService.MouseBehavior = originalMouseBehavior or Enum.MouseBehavior.Default
		if originalMouseIcon ~= nil then
			userInputService.MouseIconEnabled = originalMouseIcon
		else
			userInputService.MouseIconEnabled = true
		end
	end

	destroyGhost()

	keyDown.w = false
	keyDown.a = false
	keyDown.s = false
	keyDown.d = false
	keyDown.space = false
	keyDown.shift = false
end

-- toggle astral mode on to off
local function startAstral()
	if astralActive then
		stopAstral()
		return
	end

	local character = player.Character
	if not character then return end
	rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return end

	camera = workspace.CurrentCamera
	if not camera then return end

	astralActive = true
	astralStartTime = tick()

	-- store camera and mouse settings
	originalCameraType = camera.CameraType
	originalCameraSubject = camera.CameraSubject
	originalMouseBehavior = userInputService.MouseBehavior
	originalMouseIcon = userInputService.MouseIconEnabled
	originalFov = camera.FieldOfView

	-- switch to scriptable camera for free flight
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CameraSubject = nil
	userInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	userInputService.MouseIconEnabled = false

	setCharacterFrozen(true)
	buildGhost()
	spawnShards(rootPart.Position)

	-- mouse look for ghost
	mouseConn = userInputService.InputChanged:Connect(function(input, gpe)
		if not astralActive then return end
		if input.UserInputType == Enum.UserInputType.MouseMovement then
			local sensitivity = 0.0025
			yaw = yaw - input.Delta.X * sensitivity
			pitch = math.clamp(pitch - input.Delta.Y * sensitivity, -1.35, 1.35)
		end
	end)

	-- per frame update while in astral mode
	renderConn = runService.RenderStepped:Connect(function(dt)
		if not astralActive then return end
		if not ghostRootPart or not ghostRootPart.Parent then
			stopAstral()
			return
		end

		-- simple duration limit so it doesn't run forever
		if tick() - astralStartTime > maxAstralTime then
			stopAstral()
			return
		end

		local moveVec = Vector3.new(0, 0, 0)
		if keyDown.w then moveVec += Vector3.new(0, 0, -1) end
		if keyDown.s then moveVec += Vector3.new(0, 0, 1) end
		if keyDown.a then moveVec += Vector3.new(-1, 0, 0) end
		if keyDown.d then moveVec += Vector3.new(1, 0, 0) end
		if keyDown.space then moveVec += Vector3.new(0, 1, 0) end
		if keyDown.shift then moveVec += Vector3.new(0, -1, 0) end

		local speed = 38
		if moveVec.Magnitude > 0 then
			moveVec = moveVec.Unit
			local flat = Vector3.new(moveVec.X, 0, moveVec.Z)
			local rot = CFrame.Angles(0, yaw, 0)
			local worldFlat = rot:VectorToWorldSpace(flat)
			local yMove = moveVec.Y
			local finalMove = worldFlat + Vector3.new(0, yMove, 0)
			astralPos += finalMove * speed * dt
		end

		-- ghost orientation and camera orbit
		local baseCf = CFrame.new(astralPos) * CFrame.Angles(0, yaw, 0)
		local camOffset = CFrame.Angles(pitch, 0, 0) * CFrame.new(0, 2.5, 9)
		local targetCamCf = baseCf * camOffset

		camera.CFrame = camera.CFrame:Lerp(targetCamCf, math.clamp(dt * 10, 0, 1))
		if originalFov then
			camera.FieldOfView = originalFov
		end

		ghostRootPart.CFrame = baseCf
		updateGhostCFrames(baseCf)
	end)

	-- for safety: so if the character respawns mid-astral, shut it off
	charRemovingConn = player.CharacterRemoving:Connect(function()
		stopAstral()
	end)
end

-- keyboard input for toggling  and movement flags
userInputService.InputBegan:Connect(function(input, gpe)
	if gpe then return end
	if input.UserInputType == Enum.UserInputType.Keyboard then
		if input.KeyCode == astralKey then
			if astralActive then
				stopAstral()
			else
				startAstral()
			end
		elseif input.KeyCode == Enum.KeyCode.W then
			keyDown.w = true
		elseif input.KeyCode == Enum.KeyCode.A then
			keyDown.a = true
		elseif input.KeyCode == Enum.KeyCode.S then
			keyDown.s = true
		elseif input.KeyCode == Enum.KeyCode.D then
			keyDown.d = true
		elseif input.KeyCode == Enum.KeyCode.Space then
			keyDown.space = true
		elseif input.KeyCode == Enum.KeyCode.LeftShift then
			keyDown.shift = true
		end
	end
end)

userInputService.InputEnded:Connect(function(input, gpe)
	if input.UserInputType == Enum.UserInputType.Keyboard then
		if input.KeyCode == Enum.KeyCode.W then
			keyDown.w = false
		elseif input.KeyCode == Enum.KeyCode.A then
			keyDown.a = false
		elseif input.KeyCode == Enum.KeyCode.S then
			keyDown.s = false
		elseif input.KeyCode == Enum.KeyCode.D then
			keyDown.d = false
		elseif input.KeyCode == Enum.KeyCode.Space then
			keyDown.space = false
		elseif input.KeyCode == Enum.KeyCode.LeftShift then
			keyDown.shift = false
		end
	end
end)

workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	camera = workspace.CurrentCamera
end)
