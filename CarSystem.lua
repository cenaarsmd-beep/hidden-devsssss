local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local CarProgressService = require(script.Parent.CarProgressService)
local CarRuntimeService = require(script.Parent.CarRuntimeService)
local CorruptionSchedule = require(script.Parent.CorruptionSchedule)
local GateService = require(script.Parent.GateService)
local ShutterService = require(script.Parent.ShutterService)
local NPCAppearance = require(ReplicatedStorage.Shared.NPCAppearance)
local PhotoService = require(game:GetService("ServerScriptService").Services.PhotoService)
local AnomalyService = require(game:GetService("ServerScriptService").Services.AnomalyService)
local CaseResolutionService = require(script.Parent.CaseResolutionService)
local ObjectiveService = require(game.ServerScriptService.Services.ObjectiveService)
local InterrogationService = require(game:GetService("ServerScriptService").Services.InterrogationService)
local WantedPersonService = require(game:GetService("ServerScriptService").Services.WantedPersonService)
local KarenService = require(game:GetService("ServerScriptService").Services.KarenService)
local DialogueService = require(game:GetService("ServerScriptService").Services.DialogueService)

local lastnamepool = NPCAppearance.Male.Lastnames

local vehicles = {
	"1981 Vectra",
	"1978 Monarch",
	"1983 Orion",
	"1980 Lancer",
}

local employers = {
	"Northline Freight",
	"Vanguard Transit",
	"Redwood Logistics",
	"Halcyon Couriers",
}

local validUntilDates = {
	"31/12/2032",
	"30/06/2033",
	"31/03/2034",
	"30/09/2035",
}

local carTemplate = ReplicatedStorage:WaitForChild("Car")
local waypointsFolder = workspace:WaitForChild("Waypoints")

local spawnWaypoint = waypointsFolder:WaitForChild("Spawn")
local checkpointWaypoint = waypointsFolder:WaitForChild("WP1")
local throughGateWaypoint = waypointsFolder:WaitForChild("WP2")
local turnAwayWaypoint = waypointsFolder:WaitForChild("WP3")
local exitAfterTurnAwayWaypoint = waypointsFolder:WaitForChild("WP4")

local denyAfterShutterClosedSeconds = 2

local function driveTo(moverPart, waypoint, seconds)
	local tweenInfo = TweenInfo.new(seconds or 6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
	local tween = TweenService:Create(moverPart, tweenInfo, {CFrame = waypoint.CFrame})
	tween:Play()
	return tween
end

local function clearToolsFromEveryone()
	for _, player in ipairs(Players:GetPlayers()) do
		for _, container in ipairs({player:FindFirstChild("Backpack"), player.Character}) do
			if container then
				for _, name in ipairs({"ID", "CorruptedFile"}) do
					for _, item in ipairs(container:GetChildren()) do
						if item.Name == name and item:IsA("Tool") then
							item:Destroy()
						end
					end
				end
			end
		end
	end
end

local function clearCheckpointItems()
	local idCard = workspace:FindFirstChild("ID CARD")
	local fileObject = workspace:FindFirstChild("DriverFile")

	if idCard then idCard:Destroy() end
	if fileObject then fileObject:Destroy() end

	local screen = workspace:FindFirstChild("MainBuild") and workspace.MainBuild:FindFirstChild("Screen2")
	local highlight = screen and screen:FindFirstChild("CorruptedFileHighlight")
	if highlight then highlight.Enabled = false end

	ReplicatedStorage.RemoteEvents:WaitForChild("PrinterHintDone"):FireAllClients()
	clearToolsFromEveryone()
end

local activeMoverPart = nil
local activeCar = nil
local activeCarAppearance = nil
local activeDriverId = nil

local nextDriverId = 0
local appearanceById = {}
local recordsById = {}
local truthById = {}
local profileById = {}


local RETURNING_DRIVER_CHANCE = 0.25
local pendingReturningDriver = nil
local returningDriverUsed = false

local function runCar()
	local car = carTemplate:Clone()
	car:PivotTo(spawnWaypoint.CFrame)
	car.Parent = workspace

	local returningDriver = pendingReturningDriver
	pendingReturningDriver = nil
	if returningDriver then
		returningDriverUsed = true
	end

	local appearance = returningDriver and returningDriver.Appearance or NPCAppearance.Roll()
	local driverRig = car:FindFirstChild("NPC")
	if driverRig then
		NPCAppearance.Apply(driverRig, appearance)
	end

	nextDriverId += 1
	local driverId = nextDriverId
	car:SetAttribute("DriverId", driverId)
	car:SetAttribute("CorruptedFile", returningDriver and false or CorruptionSchedule.Roll())
	appearanceById[driverId] = appearance

	local trueyear = 1960 + ((driverId * 7) % 31)
	local truemonth = 1 + ((driverId * 5) % 12)
	local trueday = 1 + ((driverId * 11) % 28)
	local truefirstname = NPCAppearance.GetName(appearance)
	local truelastname = NPCAppearance.GetLastname(appearance)

	local profile = returningDriver and {
		isanomaly = true,
		difficulty = "hard",
		flaws = { id = false, file = false, photo = false },
	} or AnomalyService.roll(driverId)
	profileById[driverId] = profile
	local isKaren = KarenService.Roll() 

	local displayday, displaymonth, displayyear = trueday, truemonth, trueyear
	local displaylastname = truelastname

	if profile.flaws.file then
		if math.random(1, 2) == 1 then
			displaylastname = AnomalyService.mutatelastname(truelastname, profile.difficulty, lastnamepool)
		else
			displayday, displaymonth, displayyear = AnomalyService.mutatebirthdate(trueday, truemonth, trueyear, profile.difficulty)
		end
	end

	truthById[driverId] = {
		FullName = truefirstname .. " " .. truelastname,
		BirthDate = string.format("%02d/%02d/%04d", trueday, truemonth, trueyear),
	}

	local recordId = string.format("#%05d", 31000 + driverId)
	local vehicle = vehicles[(driverId - 1) % #vehicles + 1]
	local employer = employers[(driverId - 1) % #employers + 1]
	local validUntil = validUntilDates[(driverId - 1) % #validUntilDates + 1]

	truthById[driverId].RecordId = recordId
	truthById[driverId].Vehicle = vehicle
	truthById[driverId].Employment = employer
	truthById[driverId].ValidUntil = validUntil

	recordsById[driverId] = {
		FullName = truefirstname .. " " .. displaylastname,
		BirthDate = string.format("%02d/%02d/%04d", displayday, displaymonth, displayyear),
		RecordId = recordId,
		ValidUntil = validUntil,
		Vehicle = vehicle,
		Employment = employer,
		Note = "Cleared for overnight transit under " .. employer .. ".",
	}

	if returningDriver then
		truthById[driverId] = table.clone(returningDriver.Truth)
		recordsById[driverId] = table.clone(returningDriver.Record)
	end

	car:SetAttribute("PrinterResult", nil)
	car:SetAttribute("IdVerified", false)
	car:SetAttribute("IsAnomalyFinal", profile.isanomaly)
	car:SetAttribute("AnomalyDifficulty", profile.difficulty)
	car:SetAttribute("IdFlawed", profile.flaws.id)
	car:SetAttribute("FileFlawed", profile.flaws.file)
	car:SetAttribute("FileRecovered", false)
	car:SetAttribute("PhotoFlawed", profile.flaws.photo)
	car:SetAttribute("ReturningDriver", returningDriver ~= nil)
	car:SetAttribute("IsKaren", isKaren)

	CollectionService:AddTag(car, "CheckpointCar")
	WantedPersonService.RegisterNextDriver(car, appearance)

	

	local moverPart = Instance.new("Part")
	moverPart.Anchored = true
	moverPart.CanCollide = false
	moverPart.Transparency = 1
	moverPart.Size = Vector3.new(1, 1, 1)
	moverPart.CFrame = car.PrimaryPart.CFrame
	moverPart.Parent = workspace

	activeMoverPart = moverPart
	activeCar = car
	activeCarAppearance = appearance
	activeDriverId = driverId

	local heartbeatConnection
	heartbeatConnection = RunService.Heartbeat:Connect(function()
		car:PivotTo(moverPart.CFrame)
	end)

	driveTo(moverPart, checkpointWaypoint, 6).Completed:Wait()

	car:SetAttribute("AtCheckpoint", true)
	ObjectiveService.AddAll("CheckpointLoop", "- Ask for the driver's ID and file.")
	PhotoService.DriverArrived(car)
	CaseResolutionService.BeginCase(car)
	InterrogationService.BeginCase(car, truthById[driverId], recordsById[driverId], profile)
	

	local decisionMade = false
	local wasApproved = false
	local karenExpired = false

	while not decisionMade do
		if isKaren and KarenService.HasExpired(car) then
			decisionMade = true
			karenExpired = true
			wasApproved = false
		elseif GateService.IsRaised() then
			decisionMade = true
			wasApproved = true
		elseif not ShutterService.IsOpen() then
			local closedForSeconds = 0
			local shutterReopenedOrGateRaised = false

			while closedForSeconds < denyAfterShutterClosedSeconds do
				if GateService.IsRaised() or ShutterService.IsOpen() then
					shutterReopenedOrGateRaised = true
					break
				end
				task.wait(0.1)
				closedForSeconds += 0.1
			end

			if not shutterReopenedOrGateRaised then
				decisionMade = true
				wasApproved = false
			end
		else
			task.wait(0.1)
		end
	end

	car:SetAttribute("AtCheckpoint", false)
	ObjectiveService.CompleteAll("CheckpointLoop")

	local remotes = ReplicatedStorage.RemoteEvents
	if karenExpired then
		
		CaseResolutionService.Resolve(car, false)
		remotes:WaitForChild("DialogueCancelled"):FireAllClients()
		
		task.wait(0.3)
		DialogueService.SayAll(KarenService.GetWalkoutLine(), 2.5)
	else
		CaseResolutionService.Resolve(car, wasApproved)
	end

	WantedPersonService.ResolveDriver(car, wasApproved)

	if wasApproved and not profile.isanomaly and not returningDriver and not pendingReturningDriver and not returningDriverUsed
		and math.random() <= RETURNING_DRIVER_CHANCE then
		pendingReturningDriver = {
			Appearance = table.clone(appearance),
			Truth = table.clone(truthById[driverId]),
			Record = table.clone(recordsById[driverId]),
		}
	end
	InterrogationService.EndCase(car)
	PhotoService.DriverDeparted(car)
	KarenService.Stop(car)

	remotes:WaitForChild("DialogueCancelled"):FireAllClients()

	if not karenExpired and wasApproved then
		local approvedEvent = remotes:WaitForChild("ApprovedEvent")
		if approvedEvent then
			approvedEvent:FireAllClients()
		end
	elseif not karenExpired then
		local rejectedEvent = remotes:WaitForChild("RejectedEvent")
		if rejectedEvent then
			rejectedEvent:FireAllClients()
		end
	end

	clearCheckpointItems()

	if wasApproved then
		driveTo(moverPart, throughGateWaypoint, 6).Completed:Wait()
	else
		driveTo(moverPart, turnAwayWaypoint, 6).Completed:Wait()
		driveTo(moverPart, exitAfterTurnAwayWaypoint, 6).Completed:Wait()
	end

	GateService.Lower()
	ShutterService.Open()

	if activeMoverPart == moverPart then
		activeMoverPart = nil
	end
	if activeCar == car then
		activeCar = nil
		activeCarAppearance = nil
		activeDriverId = nil
	end
	heartbeatConnection:Disconnect()
	moverPart:Destroy()
	CarProgressService.ReportFinished(car)
	task.defer(function()
		car:Destroy()
	end)
end

local CarSystem = {}

function CarSystem.GetActiveCar()
	return activeCar
end

function CarSystem.GetActiveCarAppearance()
	return activeCarAppearance
end

function CarSystem.GetActiveCarDriverId()
	return activeDriverId
end

function CarSystem.GetAppearanceById(driverId)
	if driverId == nil then
		return nil
	end
	return appearanceById[driverId]
end

function CarSystem.GetRecordById(driverId)
	if driverId == nil then
		return nil
	end
	return recordsById[driverId]
end

function CarSystem.GetTruthById(driverId)
	if driverId == nil then
		return nil
	end
	return truthById[driverId]
end

function CarSystem.GetProfileById(driverId)
	if driverId == nil then
		return nil
	end
	return profileById[driverId]
end

function CarSystem.Init()
	local trafficLoopRunning = false
	CarRuntimeService.OnStarted(function()
		if trafficLoopRunning then
			return
		end

		trafficLoopRunning = true
		task.spawn(function()
			while true do
				while CarRuntimeService.IsPaused() do
					task.wait(0.25)
				end

				if CarRuntimeService.IsStoryControlled() then
					if not CarRuntimeService.TryConsumeSpawn() then
						CarRuntimeService.WaitForSpawnBudget()
						continue
					end
				end

				runCar()
			end
		end)
	end)
end

return CarSystem