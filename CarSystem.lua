-- Discord: avcd | Roblox: 9494swd

local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local CarProgressService = require(script.Parent.CarProgressService)
local CarRuntimeService = require(script.Parent.CarRuntimeService)
local CorruptionSchedule = require(script.Parent.CorruptionSchedule)
local GateService = require(script.Parent.GateService)
local ShutterService = require(script.Parent.ShutterService)
local NPCAppearance = require(ReplicatedStorage.Shared.NPCAppearance)
local PhotoService = require(ServerScriptService.Services.PhotoService)
local AnomalyService = require(ServerScriptService.Services.AnomalyService)
local CaseResolutionService = require(script.Parent.CaseResolutionService)
local ObjectiveService = require(ServerScriptService.Services.ObjectiveService)
local InterrogationService = require(ServerScriptService.Services.InterrogationService)
local WantedPersonService = require(ServerScriptService.Services.WantedPersonService)
local KarenService = require(ServerScriptService.Services.KarenService)
local DialogueService = require(ServerScriptService.Services.DialogueService)

-- Shared data used when generating a driver's documents.
local lastnamePool = NPCAppearance.Male.Lastnames
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
local returningDriverChance = 0.25

-- These references expose the car currently being processed to other services.
local activeMoverPart = nil
local activeCar = nil
local activeCarAppearance = nil
local activeDriverId = nil

-- Driver data is retained by ID so other systems can retrieve the generated case.
local nextDriverId = 0
local appearanceById = {}
local recordsById = {}
local truthById = {}
local profileById = {}

-- Only one returning driver is queued, and only one can be used during this loop.
local pendingReturningDriver = nil
local returningDriverUsed = false

local function driveTo(moverPart, waypoint, duration)
    local tweenInfo = TweenInfo.new(
        duration or 6,
        Enum.EasingStyle.Sine,
        Enum.EasingDirection.InOut
    )
    local tween = TweenService:Create(moverPart, tweenInfo, {
        CFrame = waypoint.CFrame,
    })

    tween:Play()
    return tween
end

local function clearToolsFromContainer(container)
    if not container then
        return
    end

    for _, item in ipairs(container:GetChildren()) do
        if not item:IsA("Tool") then
            continue
        end

        -- These tools belong to the current checkpoint case and should not carry over.
        if item.Name ~= "ID" and item.Name ~= "CorruptedFile" then
            continue
        end

        item:Destroy()
    end
end

local function clearToolsFromEveryone()
    for _, player in ipairs(Players:GetPlayers()) do
        clearToolsFromContainer(player:FindFirstChildOfClass("Backpack"))
        clearToolsFromContainer(player.Character)
    end
end

local function clearCheckpointItems()
    local idCard = workspace:FindFirstChild("ID CARD")
    local fileObject = workspace:FindFirstChild("DriverFile")

    if idCard then
        idCard:Destroy()
    end

    if fileObject then
        fileObject:Destroy()
    end

    local mainBuild = workspace:FindFirstChild("MainBuild")
    local screen = mainBuild and mainBuild:FindFirstChild("Screen2")
    local highlight = screen and screen:FindFirstChild("CorruptedFileHighlight")

    if highlight then
        highlight.Enabled = false
    end

    ReplicatedStorage.RemoteEvents:WaitForChild("PrinterHintDone"):FireAllClients()
    clearToolsFromEveryone()
end

local function getReturningDriver()
    local returningDriver = pendingReturningDriver
    pendingReturningDriver = nil

    if returningDriver then
        returningDriverUsed = true
    end

    return returningDriver
end

local function createDriverProfile(driverId, returningDriver)
    if returningDriver then
        return {
            isanomaly = true,
            difficulty = "hard",
            flaws = {
                id = false,
                file = false,
                photo = false,
            },
        }
    end

    return AnomalyService.roll(driverId)
end

local function createDriverDocuments(driverId, appearance, profile, returningDriver)
    local trueYear = 1960 + ((driverId * 7) % 31)
    local trueMonth = 1 + ((driverId * 5) % 12)
    local trueDay = 1 + ((driverId * 11) % 28)
    local firstName = NPCAppearance.GetName(appearance)
    local lastName = NPCAppearance.GetLastname(appearance)

    local displayDay = trueDay
    local displayMonth = trueMonth
    local displayYear = trueYear
    local displayLastName = lastName

    -- A flawed file changes either the displayed surname or birth date, not both.
    if profile.flaws.file then
        if math.random(1, 2) == 1 then
            displayLastName = AnomalyService.mutatelastname(
                lastName,
                profile.difficulty,
                lastnamePool
            )
        else
            displayDay, displayMonth, displayYear = AnomalyService.mutatebirthdate(
                trueDay,
                trueMonth,
                trueYear,
                profile.difficulty
            )
        end
    end

    local truth = {
        FullName = firstName .. " " .. lastName,
        BirthDate = string.format("%02d/%02d/%04d", trueDay, trueMonth, trueYear),
    }

    local recordId = string.format("#%05d", 31000 + driverId)
    local vehicle = vehicles[(driverId - 1) % #vehicles + 1]
    local employer = employers[(driverId - 1) % #employers + 1]
    local validUntil = validUntilDates[(driverId - 1) % #validUntilDates + 1]

    truth.RecordId = recordId
    truth.Vehicle = vehicle
    truth.Employment = employer
    truth.ValidUntil = validUntil

    local record = {
        FullName = firstName .. " " .. displayLastName,
        BirthDate = string.format("%02d/%02d/%04d", displayDay, displayMonth, displayYear),
        RecordId = recordId,
        ValidUntil = validUntil,
        Vehicle = vehicle,
        Employment = employer,
        Note = "Cleared for overnight transit under " .. employer .. ".",
    }

    -- Returning drivers reuse their original identity and documents.
    if returningDriver then
        truth = table.clone(returningDriver.Truth)
        record = table.clone(returningDriver.Record)
    end

    return truth, record
end

local function configureCar(car, driverId, profile, returningDriver, isKaren)
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
    car:SetAttribute("DriverId", driverId)
    -- Returning drivers should not receive a corrupted file.
    car:SetAttribute("CorruptedFile", not returningDriver and CorruptionSchedule.Roll() or false)

    CollectionService:AddTag(car, "CheckpointCar")
end

local function createCarMover(car)
    local moverPart = Instance.new("Part")
    moverPart.Name = "CarMover"
    moverPart.Anchored = true
    moverPart.CanCollide = false
    moverPart.Transparency = 1
    moverPart.Size = Vector3.new(1, 1, 1)
    moverPart.CFrame = car.PrimaryPart.CFrame
    moverPart.Parent = workspace

    return moverPart
end

local function setActiveCar(car, moverPart, appearance, driverId)
    activeMoverPart = moverPart
    activeCar = car
    activeCarAppearance = appearance
    activeDriverId = driverId
end

local function clearActiveCar(car, moverPart)
    if activeMoverPart == moverPart then
        activeMoverPart = nil
    end

    if activeCar == car then
        activeCar = nil
        activeCarAppearance = nil
        activeDriverId = nil
    end
end

local function waitForCheckpointDecision(car, isKaren)
    while true do
        -- A timed-out Karen event forces a rejection, even if the gate is raised.
        if isKaren and KarenService.HasExpired(car) then
            return false, true
        end

        if GateService.IsRaised() then
            return true, false
        end

        if not ShutterService.IsOpen() then
            local deadline = os.clock() + denyAfterShutterClosedSeconds
            local reopenedOrGateRaised = false

            -- Give the gate or shutter a short grace period before rejecting the driver.
            while os.clock() < deadline do
                if GateService.IsRaised() or ShutterService.IsOpen() then
                    reopenedOrGateRaised = true
                    break
                end

                task.wait(0.1)
            end

            if not reopenedOrGateRaised then
                return false, false
            end
        else
            task.wait(0.1)
        end
    end
end

local function resolveCheckpointCase(car, wasApproved, karenExpired)
    local remotes = ReplicatedStorage.RemoteEvents
    car:SetAttribute("AtCheckpoint", false)
    ObjectiveService.CompleteAll("CheckpointLoop")

    if karenExpired then
        CaseResolutionService.Resolve(car, false)
        remotes:WaitForChild("DialogueCancelled"):FireAllClients()
        task.wait(0.3)
        DialogueService.SayAll(KarenService.GetWalkoutLine(), 2.5)
    else
        CaseResolutionService.Resolve(car, wasApproved)
    end

    WantedPersonService.ResolveDriver(car, wasApproved)
end

local function queueReturningDriver(wasApproved, profile, returningDriver, appearance, driverId)
    if not wasApproved then
        return
    end

    if profile.isanomaly or returningDriver or pendingReturningDriver or returningDriverUsed then
        return
    end

    if math.random() > returningDriverChance then
        return
    end

    -- Preserve the same identity and documents for the next appearance.
    pendingReturningDriver = {
        Appearance = table.clone(appearance),
        Truth = table.clone(truthById[driverId]),
        Record = table.clone(recordsById[driverId]),
    }
end

local function fireDecisionEvent(wasApproved, karenExpired)
    local remotes = ReplicatedStorage.RemoteEvents
    remotes:WaitForChild("DialogueCancelled"):FireAllClients()

    if karenExpired then
        return
    end

    local eventName = wasApproved and "ApprovedEvent" or "RejectedEvent"
    remotes:WaitForChild(eventName):FireAllClients()
end

local function moveCarOut(moverPart, wasApproved)
    if wasApproved then
        driveTo(moverPart, throughGateWaypoint, 6).Completed:Wait()
        return
    end

    driveTo(moverPart, turnAwayWaypoint, 6).Completed:Wait()
    driveTo(moverPart, exitAfterTurnAwayWaypoint, 6).Completed:Wait()
end

local function runCar()
    local car = carTemplate:Clone()
    car:PivotTo(spawnWaypoint.CFrame)
    car.Parent = workspace

    local returningDriver = getReturningDriver()
    local appearance = returningDriver and returningDriver.Appearance or NPCAppearance.Roll()
    local driverRig = car:FindFirstChild("NPC")

    if driverRig then
        NPCAppearance.Apply(driverRig, appearance)
    end

    nextDriverId += 1
    local driverId = nextDriverId
    local profile = createDriverProfile(driverId, returningDriver)
    local isKaren = KarenService.Roll()
    local truth, record = createDriverDocuments(driverId, appearance, profile, returningDriver)

    appearanceById[driverId] = appearance
    truthById[driverId] = truth
    recordsById[driverId] = record
    profileById[driverId] = profile

    configureCar(car, driverId, profile, returningDriver, isKaren)
    WantedPersonService.RegisterNextDriver(car, appearance)

    local moverPart = createCarMover(car)
    setActiveCar(car, moverPart, appearance, driverId)

    -- The invisible mover follows the route; Heartbeat keeps the model aligned with it.
    local heartbeatConnection = RunService.Heartbeat:Connect(function()
        if car.Parent then
            car:PivotTo(moverPart.CFrame)
        end
    end)

    driveTo(moverPart, checkpointWaypoint, 6).Completed:Wait()

    car:SetAttribute("AtCheckpoint", true)
    ObjectiveService.AddAll("CheckpointLoop", "- Ask for the driver's ID and file.")
    PhotoService.DriverArrived(car)
    CaseResolutionService.BeginCase(car)
    InterrogationService.BeginCase(car, truth, record, profile)

    local wasApproved, karenExpired = waitForCheckpointDecision(car, isKaren)

    resolveCheckpointCase(car, wasApproved, karenExpired)
    queueReturningDriver(wasApproved, profile, returningDriver, appearance, driverId)

    InterrogationService.EndCase(car)
    PhotoService.DriverDeparted(car)
    KarenService.Stop(car)
    fireDecisionEvent(wasApproved, karenExpired)
    clearCheckpointItems()
    moveCarOut(moverPart, wasApproved)

    GateService.Lower()
    ShutterService.Open()

    clearActiveCar(car, moverPart)
    heartbeatConnection:Disconnect()
    moverPart:Destroy()
    CarProgressService.ReportFinished(car)

    -- Defer destruction so any listeners handling completion can finish first.
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
                -- Pausing the runtime should stop new cars from spawning.
                while CarRuntimeService.IsPaused() do
                    task.wait(0.25)
                end

                if CarRuntimeService.IsStoryControlled()
                    and not CarRuntimeService.TryConsumeSpawn() then
                    CarRuntimeService.WaitForSpawnBudget()
                    continue
                end

                runCar()
            end
        end)
    end)
end

return CarSystem
