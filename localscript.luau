local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

-- playerRefs
local player = Players.LocalPlayer
local gui = player:WaitForChild("PlayerGui"):WaitForChild("BuildingUI")
local mouse = player:GetMouse()

-- storageRefs
-- BuildingSystem contains modules and remotes; Mereology is the template library used for inventory + placement
local system = ReplicatedStorage:WaitForChild("BuildingSystem")
local modules = system:WaitForChild("Modules")
local mereology = ReplicatedStorage:WaitForChild("Mereology")

-- moduleImports
-- this script intentionally does not implement placement/deletion logic; it delegates behavior to focused modules
local Placement = require(modules:WaitForChild("PlacementModule"))
local Deletion = require(modules:WaitForChild("DeletionModule"))
local UI = require(modules:WaitForChild("UIModule"))
local Viewport = require(modules:WaitForChild("ViewportHandler"))
local Grid = require(modules:WaitForChild("GridModule"))
local History = require(modules:WaitForChild("HistoryModule"))

-- moduleInstances
-- these are stateful objects that manage their own connections/preview state internally
local placement = Placement.new(player, mouse)
local deletion = Deletion.new(player, mouse)
local ui = UI.new(gui)
local grid = Grid.new(2)
local history = History.new()

-- gridWiring
-- placement uses grid snapping; the grid module is passed in so snapping rules can be toggled without changing placement code
placement:SetGrid(grid)

-- controllerState
-- mode is the controller truth; placing is a tighter flag used to know if placement preview is actively running
local mode = "none"
local placing = false
local placedObjects = {} -- kept for compatibility; history is the actual undo/redo source in this controller

-- undoLogic
-- undo reads the last action from history and reverses it by calling the same server remotes used for normal actions
-- this means undo stays compatible with server validation rules and avoids client-only deletes/creates
local function performUndo()
	if not history:CanUndo() then
		-- early exit avoids calling Undo() when the stack is empty, which keeps HistoryModule simpler
		print("Nothing to undo")
		return
	end

	local action = history:Undo()
	if action then
		if action.type == "place" then
			-- undoing a placement is equivalent to deleting that placed instance
			-- we only attempt the delete if the object reference still exists and is parented
			if action.object and action.object.Parent then
				-- remotes are fetched at call-time to reduce coupling if the folder is reloaded or replaced during play
				local remotes = ReplicatedStorage.BuildingSystem.RemoteEvents
				local success = remotes.DeleteObject:InvokeServer(action.object)
				if success then
					-- destroying locally removes the instance immediately for the player; server should have already removed it too
					action.object:Destroy()
					print("Undid placement of", action.data.name)
				end
			else
				-- object references can become invalid if the server already deleted it or it was cleaned up externally
				print("Object no longer exists")
			end

		elseif action.type == "delete" and action.data then
			-- undoing a deletion is equivalent to re-placing the same template at the previous CFrame
			local remotes = ReplicatedStorage.BuildingSystem.RemoteEvents
			local success, obj = remotes.PlaceObject:InvokeServer(action.data.name, action.data.cf)
			if success then
				-- updating the action object reference makes redo work later (redo needs a live instance to delete again)
				print("Undid deletion of", action.data.name)
				action.object = obj
			end
		end
	end
end

-- redoLogic
-- redo replays a previously undone action by re-invoking the server remotes with stored action data
-- this is why each history record stores both template name and CFrame for placements/deletions
local function performRedo()
	if not history:CanRedo() then
		print("Nothing to redo")
		return
	end

	local action = history:Redo()
	if action then
		if action.type == "place" and action.data then
			-- redo placement uses the stored templateName + CFrame so the result matches the original action
			local remotes = ReplicatedStorage.BuildingSystem.RemoteEvents
			local success, obj = remotes.PlaceObject:InvokeServer(action.data.name, action.data.cf)
			if success and obj then
				-- keeping the returned object reference ensures future undo can delete the correct instance
				action.object = obj
				print("Redid placement of", action.data.name)
			end

		elseif action.type == "delete" then
			-- redo delete requires the object instance reference that was restored by undo
			if action.object and action.object.Parent then
				local remotes = ReplicatedStorage.BuildingSystem.RemoteEvents
				local success = remotes.DeleteObject:InvokeServer(action.object)
				if success then
					action.object:Destroy()
					print("Redid deletion of", action.data.name)
				end
			else
				-- if the instance was removed or replaced, redo cannot safely identify the correct target
				print("Object no longer exists")
			end
		end
	end
end

-- placementEntryPoint
-- startPlacingObject transitions the controller into place mode and delegates preview to PlacementModule
-- this function also ensures delete mode is stopped so the two modes do not compete for mouse targeting
local function startPlacingObject(objectName)
	print("Attempting to place:", objectName)

	-- verifying the template before entering placement mode prevents starting a preview that cannot be constructed
	local template = mereology:FindFirstChild(objectName)
	if not template then
		warn("Template not found in Mereology:", objectName)
		return false
	end

	-- stop deletion when entering placement to avoid overlapping highlighters / selection logic
	if mode == "delete" then
		deletion:Stop()
	end

	-- if a placement preview is already active, cancel it so only one ghost/preview exists at a time
	if placing then
		placement:Cancel()
		placing = false
	end

	mode = "place"
	ui:SetMode("place")

	-- PlacementModule:Start typically spawns a ghost and begins updating it from mouse/raycast state
	local success = placement:Start(objectName)
	if success then
		placing = true
		-- info text is kept here (controller level) because it depends on mode and input bindings
		ui:UpdateInfo("Q/E - Rotate | R - Axis [Yaw]\nLMB - Place | C - Cancel")
		print("Successfully started placement for:", objectName)
	else
		print("Failed to start placement for:", objectName)
	end

	return success
end

-- inventoryBuild
-- setupInventory rebuilds the scrolling list from Mereology templates and binds each entry to placement start
-- it also builds a numeric hotkey index (1..9) so users can quickly select items without clicking
local function setupInventory()
	local container = ui.items

	-- clearing old frames avoids duplicated buttons and duplicated event connections on rebuild
	for _, child in ipairs(container:GetChildren()) do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	local itemIndex = {}
	local index = 1

	for _, obj in ipairs(mereology:GetChildren()) do
		-- each template gets a frame containing a 3D viewport preview + label + transparent button overlay
		local frame = Instance.new("Frame")
		frame.Name = obj.Name
		frame.BackgroundColor3 = Color3.fromRGB(35, 35, 40)
		frame.BorderSizePixel = 0
		frame.Parent = container

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 8)
		corner.Parent = frame

		-- viewport preview is created from the template; this keeps inventory responsive without spawning into Workspace
		Viewport.create(obj, frame)

		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(1, -4, 0, 20)
		label.Position = UDim2.new(0, 2, 1, -22)
		label.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
		label.BorderSizePixel = 0
		label.Text = obj.Name
		label.TextColor3 = Color3.fromRGB(220, 220, 220)
		label.TextSize = 11
		label.Font = Enum.Font.Gotham
		label.Parent = frame

		local labelCorner = Instance.new("UICorner")
		labelCorner.CornerRadius = UDim.new(0, 4)
		labelCorner.Parent = label

		-- only the first 9 items get number labels + hotkeys to keep the binding simple and predictable
		if index <= 9 then
			local numLabel = Instance.new("TextLabel")
			numLabel.Size = UDim2.new(0, 20, 0, 20)
			numLabel.Position = UDim2.new(0, 4, 0, 4)
			numLabel.BackgroundColor3 = Color3.fromRGB(50, 50, 55)
			numLabel.BorderSizePixel = 0
			numLabel.Text = tostring(index)
			numLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
			numLabel.TextSize = 12
			numLabel.Font = Enum.Font.GothamBold
			numLabel.ZIndex = 3
			numLabel.Parent = frame

			local numCorner = Instance.new("UICorner")
			numCorner.CornerRadius = UDim.new(0, 4)
			numCorner.Parent = numLabel

			itemIndex[index] = obj.Name
		end

		-- full-frame button overlay means the user can click anywhere on the tile to select the item
		local btn = Instance.new("TextButton")
		btn.Size = UDim2.new(1, 0, 1, 0)
		btn.BackgroundTransparency = 1
		btn.Text = ""
		btn.ZIndex = 2
		btn.Parent = frame

		-- hover tween is UI-only feedback; it does not affect placement logic or state
		btn.MouseEnter:Connect(function()
			TweenService:Create(frame, TweenInfo.new(0.15), {
				BackgroundColor3 = Color3.fromRGB(45, 45, 50),
			}):Play()
		end)

		btn.MouseLeave:Connect(function()
			TweenService:Create(frame, TweenInfo.new(0.15), {
				BackgroundColor3 = Color3.fromRGB(35, 35, 40),
			}):Play()
		end)

		btn.MouseButton1Click:Connect(function()
			-- inventory click begins placement, then optionally closes inventory so the user can see the world clearly
			if startPlacingObject(obj.Name) then
				if ui.state.inv then
					ui:ToggleInv()
				end
			end
		end)

		index = index + 1
	end

	-- canvas size is recalculated from the grid layout so scrolling remains correct as items change
	local layout = container:FindFirstChild("UIGridLayout")
	if layout then
		container.CanvasSize = UDim2.new(0, 0, 0, layout.AbsoluteContentSize.Y + 20)
	end

	return itemIndex
end

-- hotkeyIndex
-- initialized empty; populated after setupInventory so numeric hotkeys can resolve to template names
local itemIndex = {}

-- uiGridBinding
-- UI module emits a "grid enabled" signal; controller forwards that to GridModule
ui:OnGrid(function(enabled)
	grid:SetEnabled(enabled)
end)

-- uiModeBinding
-- UI emits mode changes; controller ensures only one mode tool is running at a time
-- this is the critical point that prevents both placement and deletion from owning input/preview simultaneously
ui:OnMode(function(newMode)
	if newMode ~= mode then
		-- leaving a mode should clean up its state so it does not continue running hidden
		if mode == "place" and placing then
			placement:Cancel()
			placing = false
		elseif mode == "delete" then
			deletion:Stop()
		end

		mode = newMode

		if mode == "delete" then
			-- deletion mode typically starts a targeting/highlight loop managed by DeletionModule
			deletion:Start()
			ui:UpdateInfo("LMB - Delete\nX - Exit\nZ/Y - Undo/Redo")
		elseif mode == "none" then
			-- none mode acts as a safe baseline: cancel any preview and remove any delete targeting visuals
			if placing then
				placement:Cancel()
				placing = false
			end
			deletion:Stop()
		end
	end
end)

-- keyboardAndMouseInputs
-- controller centralizes user input mapping so modules stay focused on their respective behaviors
UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end

	-- inventory toggle is global, regardless of mode, because it only affects UI
	if input.KeyCode == Enum.KeyCode.B then
		ui:ToggleInv()
		return
	end

	-- grid toggle is global; it modifies snapping but does not switch placement/delete modes
	if input.KeyCode == Enum.KeyCode.G then
		ui:ToggleGrid()
		return
	end

	-- delete mode toggle is global; it switches the tool that "owns" the mouse interaction
	if input.KeyCode == Enum.KeyCode.V then
		if mode == "delete" then
			ui:SetMode("none")
		else
			ui:SetMode("delete")
		end
		return
	end

	-- undo/redo are blocked while placing so history cannot reference a preview that was never committed to server
	if input.KeyCode == Enum.KeyCode.Z then
		if not placing then
			performUndo()
		else
			print("Can't undo while placing")
		end
		return
	end

	if input.KeyCode == Enum.KeyCode.Y then
		if not placing then
			performRedo()
		else
			print("Can't redo while placing")
		end
		return
	end

	-- numericHotkeys
	-- numbers select items only when inventory is open, to avoid conflicting with other gameplay binds
	local numberKeys = {
		[Enum.KeyCode.One] = 1,
		[Enum.KeyCode.Two] = 2,
		[Enum.KeyCode.Three] = 3,
		[Enum.KeyCode.Four] = 4,
		[Enum.KeyCode.Five] = 5,
		[Enum.KeyCode.Six] = 6,
		[Enum.KeyCode.Seven] = 7,
		[Enum.KeyCode.Eight] = 8,
		[Enum.KeyCode.Nine] = 9,
		[Enum.KeyCode.KeypadOne] = 1,
		[Enum.KeyCode.KeypadTwo] = 2,
		[Enum.KeyCode.KeypadThree] = 3,
		[Enum.KeyCode.KeypadFour] = 4,
		[Enum.KeyCode.KeypadFive] = 5,
		[Enum.KeyCode.KeypadSix] = 6,
		[Enum.KeyCode.KeypadSeven] = 7,
		[Enum.KeyCode.KeypadEight] = 8,
		[Enum.KeyCode.KeypadNine] = 9,
	}

	local num = numberKeys[input.KeyCode]
	if num and itemIndex[num] and ui.state.inv then
		-- if a hotkey selection succeeds, closing inventory improves visibility for placement
		if startPlacingObject(itemIndex[num]) then
			ui:ToggleInv()
		end
		return
	end

	-- modeSpecificInputs
	if mode == "place" then
		if placing then
			-- rotation controls are delegated to PlacementModule; controller only chooses when to call them
			if input.KeyCode == Enum.KeyCode.Q then
				placement:Rotate(-1)
			elseif input.KeyCode == Enum.KeyCode.E then
				placement:Rotate(1)
			elseif input.KeyCode == Enum.KeyCode.R then
				-- axis switching updates UI so the player knows which axis future Q/E rotates around
				local axis = placement:SwitchRotationAxis()
				local axisName = axis == "Y" and "Yaw" or axis == "X" and "Pitch" or "Roll"
				ui:UpdateInfo("Q/E - Rotate | R - Axis [" .. axisName .. "]\nLMB - Place | C - Cancel")
			elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
				-- placement commit calls into PlacementModule, which should invoke server placement
				-- history stores enough data to replay the action later (template name + CFrame)
				local objName = placement.object
				local success, obj = placement:Place()
				if success and obj then
					history:Add({
						type = "place",
						object = obj,
						data = { name = objName, cf = obj.CFrame },
					})
					print("Placed and tracked:", objName)
				end
			elseif input.KeyCode == Enum.KeyCode.C then
				-- cancel only stops preview; it does not change mode so the user can pick another item quickly
				placement:Cancel()
				placing = false
				ui:UpdateInfo("Select item from inventory")
			end
		end

		-- exit key is available even if not actively placing, because mode "place" may still be selected
		if input.KeyCode == Enum.KeyCode.X then
			if placing then
				placement:Cancel()
				placing = false
			end
			ui:SetMode("none")
			mode = "none"
		end

	elseif mode == "delete" then
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			-- deletion target is owned by DeletionModule; controller reads it to build history data
			local target = deletion.target
			if target then
				local targetName = target.Name
				local targetCF = target.CFrame
				local success = deletion:Delete()
				if success then
					history:Add({
						type = "delete",
						object = nil,
						data = { name = targetName, cf = targetCF },
					})
					print("Deleted and tracked:", targetName)
				end
			end
		elseif input.KeyCode == Enum.KeyCode.X then
			-- exit delete mode stops targeting/highlight loop immediately to prevent lingering visuals
			deletion:Stop()
			ui:SetMode("none")
			mode = "none"
		end
	end
end)

-- touchPlacementAndDeletion
-- touch input mirrors mouse input so mobile users can still place and delete without keyboard
UserInputService.TouchTap:Connect(function(positions, processed)
	if processed then return end

	if mode == "place" and placing then
		-- tap to place uses the same PlacementModule:Place call so server authority remains consistent across platforms
		local objName = placement.object
		local success, obj = placement:Place()
		if success and obj then
			history:Add({
				type = "place",
				object = obj,
				data = { name = objName, cf = obj.CFrame },
			})
			print("Placed and tracked:", objName)
		end
	elseif mode == "delete" then
		-- tap to delete relies on DeletionModule selecting a target based on touch position / current target logic
		local target = deletion.target
		if target then
			local targetName = target.Name
			local targetCF = target.CFrame
			local success = deletion:Delete()
			if success then
				history:Add({
					type = "delete",
					object = nil,
					data = { name = targetName, cf = targetCF },
				})
				print("Deleted and tracked:", targetName)
			end
		end
	end
end)

-- touchRotation
-- long press maps to rotate so mobile users can still adjust orientation without extra UI buttons
UserInputService.TouchLongPress:Connect(function(positions, state, processed)
	if processed or mode ~= "place" or not placing then return end

	if state == Enum.UserInputState.Begin then
		placement:Rotate(1)
	end
end)

-- startupInventoryBuild
-- small delay gives UI time to finish loading and ensures mereology children are replicated before building tiles
task.wait(0.1)
itemIndex = setupInventory()
