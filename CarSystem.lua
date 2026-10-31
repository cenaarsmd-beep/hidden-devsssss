--!strict
-- Discord: avcd | Roblox: 9494swd

-- Strict mode makes the Luau analyzer flag nil mistakes and wrong types while I write, which matters in a file this size where many tables travel between functions.

local TweenService = game:GetService("TweenService")
-- TweenService animates the invisible mover part smoothly between waypoints, so I do not have to write per-frame interpolation myself.
local RunService = game:GetService("RunService")
-- RunService gives me Heartbeat, which fires every frame and keeps the visible car glued to the mover part.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
-- ReplicatedStorage holds the car template, shared appearance data and the remote events, because both server and clients need to see those.
local ServerScriptService = game:GetService("ServerScriptService")
-- ServerScriptService is where my server-only services live, so clients can never read or tamper with them.
local CollectionService = game:GetService("CollectionService")
-- CollectionService lets me tag each car so other scripts can find every checkpoint car without knowing about this module.
local Players = game:GetService("Players")
-- Players is needed to walk every connected player when I clean up leftover tools.

local servicesFolder = ServerScriptService:WaitForChild("Services")
-- I resolve the services folder once and require everything from it, so all requires use the same consistent path instead of mixing script.Parent with absolute paths. This assumes this module lives in that folder.

local CarProgressService = require(servicesFolder:WaitForChild("CarProgressService"))
-- Reports to the rest of the game that a car has completely finished its trip.
local CarRuntimeService = require(servicesFolder:WaitForChild("CarRuntimeService"))
-- Controls pausing, story control and the spawn budget, so story scenes can decide when traffic runs.
local CorruptionSchedule = require(servicesFolder:WaitForChild("CorruptionSchedule"))
-- Decides whether this driver's file arrives corrupted, keeping that pacing logic out of this script.
local GateService = require(servicesFolder:WaitForChild("GateService"))
-- Owns the gate the player raises, which is the player's way of approving a driver.
local ShutterService = require(servicesFolder:WaitForChild("ShutterService"))
-- Owns the window shutter, because closing it on a waiting driver counts as a rejection.
local NPCAppearance = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("NPCAppearance"))
-- Shared with clients so the same appearance data can be rolled, named and applied to rigs.
local PhotoService = require(servicesFolder:WaitForChild("PhotoService"))
-- Handles the photo document, which this script only needs to tell about arrivals and departures.
local AnomalyService = require(servicesFolder:WaitForChild("AnomalyService"))
-- Rolls whether a driver is suspicious and how their documents get mutated.
local CaseResolutionService = require(servicesFolder:WaitForChild("CaseResolutionService"))
-- Scores the player's decision against the truth about the driver.
local ObjectiveService = require(servicesFolder:WaitForChild("ObjectiveService"))
-- Shows and completes the on-screen objectives for the current task.
local InterrogationService = require(servicesFolder:WaitForChild("InterrogationService"))
-- Runs the question and answer conversation, which needs the true data and the shown data to detect lies.
local WantedPersonService = require(servicesFolder:WaitForChild("WantedPersonService"))
-- Tracks whether a driver is a wanted person, and needs to see every driver's appearance.
local KarenService = require(servicesFolder:WaitForChild("KarenService"))
-- Handles the impatient Karen event, including its timer and its walkout line.
local DialogueService = require(servicesFolder:WaitForChild("DialogueService"))
-- Sends spoken lines to every client's dialogue box.

type DriverFlaws = {
    id: boolean,
    file: boolean,
    photo: boolean,
}
-- Describes which documents carry a flaw. I keep the lowercase field names because AnomalyService already produces them in this shape.

type DriverProfile = {
    isanomaly: boolean,
    difficulty: string,
    flaws: DriverFlaws,
}
-- The full suspicion profile of one driver. Naming the type lets the analyzer catch me if I misspell a field later.

type DriverTruth = {
    FullName: string,
    BirthDate: string,
    RecordId: string,
    Vehicle: string,
    Employment: string,
    ValidUntil: string,
}
-- What is actually true about the driver. The interrogation compares the driver's answers against this.

type DriverRecord = {
    FullName: string,
    BirthDate: string,
    RecordId: string,
    ValidUntil: string,
    Vehicle: string,
    Employment: string,
    Note: string,
}
-- What the printed file says. It starts identical to the truth and only differs when the file is flawed.

type ReturningDriver = {
    Appearance: any,
    Truth: DriverTruth,
    Record: DriverRecord,
}
-- A snapshot of an approved driver, stored so the exact same person and paperwork can come back later.

type CheckpointDecision = "approved" | "rejected" | "karenexpired"
-- One string with three allowed values replaces the old pair of booleans, which could technically hold impossible combinations.

type CarSession = {
    car: Model,
    invisibleMover: BasePart,
    followConnection: RBXScriptConnection,
    driverId: number,
}
-- Everything that must be destroyed or disconnected when a car finishes, bundled together so cleanup can never forget one piece.

local lastnamePool = NPCAppearance.Male.Lastnames
-- Mutated surnames are picked from this pool so a fake name still looks like a real one.

local vehicles = { "1981 Vectra", "1978 Monarch", "1983 Orion", "1980 Lancer" }
local employers = { "Northline Freight", "Vanguard Transit", "Redwood Logistics", "Halcyon Couriers" }
local validUntilDates = { "31/12/2032", "30/06/2033", "31/03/2034", "30/09/2035" }
-- Small fixed lists that drivers cycle through by id. The data does not need randomness because players only compare it against itself.

local tweenDurationSeconds = 6
-- How long every leg of the drive takes. One shared value keeps all legs consistent and easy to retune.
local pollIntervalSeconds = 0.1
-- How often I check the gate and shutter. Ten checks per second is fast enough to feel instant without wasting server time.
local shutterGraceSeconds = 2
-- How long a closed shutter is tolerated before the driver is rejected, so a quick accidental close is forgiven.
local returningDriverChance = 0.25
-- Chance that an eligible approved driver is queued to come back.
local pausedPollSeconds = 0.25
-- Slower polling while paused, because nothing urgent happens then.
local karenWalkoutDelaySeconds = 0.3
-- A short beat between cancelling dialogue and the walkout line so the two do not overlap.
local karenWalkoutLineSeconds = 2.5
-- How long the walkout line stays on screen.
local retainedDriverCount = 5
-- How many recent drivers keep their stored data, so late listeners still find it but memory stays bounded.
local firstRecordNumber = 31000
-- The record numbers start here so they look like believable paperwork ids.
local earliestBirthYear = 1960
local latestBirthYear = 1990
-- Birth years are picked in this range.
local latestSafeBirthDay = 28
-- Capping the day at 28 means every month is valid without needing leap year logic.
local cleanupToolNames = { ID = true, CorruptedFile = true }
-- A set of the tool names that belong only to the current case, so lookups are one table read.

local idCardName = "ID CARD"
local driverFileName = "DriverFile"
local mainBuildName = "MainBuild"
local screenName = "Screen2"
local highlightName = "CorruptedFileHighlight"
-- Every world object name lives here, so a rename in Studio means changing one line instead of hunting through functions.

local carTemplate = ReplicatedStorage:WaitForChild("Car") :: Model
-- The model every spawned car is cloned from.
local waypointsFolder = workspace:WaitForChild("Waypoints")

local function findWaypoint(waypointName: string): BasePart
    return waypointsFolder:WaitForChild(waypointName) :: BasePart
end
-- Waits for the waypoint and tells the analyzer it is a part, since only parts have a CFrame to drive toward.

local spawnWaypoint = findWaypoint("Spawn")
local checkpointWaypoint = findWaypoint("WP1")
local throughGateWaypoint = findWaypoint("WP2")
local turnAwayWaypoint = findWaypoint("WP3")
local exitAfterTurnAwayWaypoint = findWaypoint("WP4")
-- The route: spawn, stop at the checkpoint, then either go through the gate (approved) or turn away and leave (rejected).

local remoteEventsFolder = ReplicatedStorage:WaitForChild("RemoteEvents")
local printerHintDoneEvent = remoteEventsFolder:WaitForChild("PrinterHintDone") :: RemoteEvent
local dialogueCancelledEvent = remoteEventsFolder:WaitForChild("DialogueCancelled") :: RemoteEvent
local approvedEvent = remoteEventsFolder:WaitForChild("ApprovedEvent") :: RemoteEvent
local rejectedEvent = remoteEventsFolder:WaitForChild("RejectedEvent") :: RemoteEvent
-- Resolving the remotes once at startup means no WaitForChild can hang in the middle of gameplay.

local randomGenerator = Random.new()
-- A Random object gives me better quality random numbers than math.random and does not depend on global seeding.

local activeCar: Model? = nil
local activeCarAppearance: any = nil
local activeDriverId: number? = nil
-- These expose the car being processed right now to other services through the getters at the bottom.

local nextDriverId = 0
-- Counts up forever so every driver gets a unique id.
local appearanceById: { [number]: any } = {}
local recordsById: { [number]: DriverRecord } = {}
local truthById: { [number]: DriverTruth } = {}
local profileById: { [number]: DriverProfile } = {}
-- Per driver data so other systems can ask for a case by id. Old entries are removed by forgetOldDrivers.

local pendingReturningDriver: ReturningDriver? = nil
local returningDriverUsed = false
-- Only one returning driver can be queued, and only one is ever used, so the event stays special.

local function driveMoverToWaypoint(invisibleMover: BasePart, waypoint: BasePart): Tween
    local tweenSettings = TweenInfo.new(tweenDurationSeconds, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
    -- Sine with InOut eases at both ends, which reads as a car pulling away and braking instead of moving at constant speed.
    local tween = TweenService:Create(invisibleMover, tweenSettings, { CFrame = waypoint.CFrame })
    -- The tween moves the part instead of the model, because a Model has no CFrame property to animate.
    tween:Play()
    return tween
    -- Returning the tween lets callers yield on Completed, so the route is sequenced without polling.
end

local function clearToolsFromContainer(container: Instance?)
    if not container then
        return
    end
    -- Characters and backpacks can be missing while a player is respawning, so I tolerate nil here.

    for _, item in ipairs(container:GetChildren()) do
        if item:IsA("Tool") and cleanupToolNames[item.Name] then
            item:Destroy()
        end
    end
    -- Only tools that belong to the finished case are removed, so unrelated tools the player owns survive.
end

local function clearToolsFromEveryone()
    for _, player in ipairs(Players:GetPlayers()) do
        clearToolsFromContainer(player:FindFirstChildOfClass("Backpack"))
        clearToolsFromContainer(player.Character)
    end
    -- A tool can sit in the backpack or be held in the character, so both places are checked.
end

local function destroyCheckpointObjects()
    local idCard = workspace:FindFirstChild(idCardName)
    local fileObject = workspace:FindFirstChild(driverFileName)
    if idCard then
        idCard:Destroy()
    end
    if fileObject then
        fileObject:Destroy()
    end
    -- FindFirstChild instead of indexing, because the objects may already be gone if the player handed them in.
end

local function hideCorruptedFileHighlight()
    local mainBuild = workspace:FindFirstChild(mainBuildName)
    local screen = mainBuild and mainBuild:FindFirstChild(screenName)
    local highlight = screen and screen:FindFirstChild(highlightName)
    if highlight and highlight:IsA("Highlight") then
        highlight.Enabled = false
    end
    -- The and chain stops safely at the first missing link, and the IsA check lets the analyzer allow the Enabled property.
end

local function resetCheckpointDesk()
    destroyCheckpointObjects()
    hideCorruptedFileHighlight()
    printerHintDoneEvent:FireAllClients()
    -- Tells every client to hide the printer hint, since the next case has not started.
    clearToolsFromEveryone()
end
-- This was one function doing four unrelated jobs, so I split it into small pieces and made the name honest about what it resets.

local function takeReturningDriver(): ReturningDriver?
    local returningDriver = pendingReturningDriver
    pendingReturningDriver = nil
    -- Clearing it right away guarantees one queued driver can only be taken once.
    if returningDriver then
        returningDriverUsed = true
    end
    return returningDriver
end

local function createDriverProfile(driverId: number, returningDriver: ReturningDriver?): DriverProfile
    if returningDriver then
        return {
            isanomaly = true,
            difficulty = "hard",
            flaws = { id = false, file = false, photo = false },
        }
        -- A returning driver is flagged as an anomaly with no flawed documents, so the paperwork is clean and the trick is the repeat visit.
    end
    return AnomalyService.roll(driverId)
end

local function pickFromList(list: { string }, driverId: number): string
    return list[(driverId - 1) % #list + 1]
end
-- Cycles through a list by id. Subtracting one before the modulo and adding one after keeps it correct for Luau's one-based arrays.

local function formatBirthDate(day: number, month: number, year: number): string
    return string.format("%02d/%02d/%04d", day, month, year)
end

local function createDriverDocuments(
    driverId: number,
    appearance: any,
    profile: DriverProfile,
    returningDriver: ReturningDriver?
): (DriverTruth, DriverRecord)
    if returningDriver then
        return table.clone(returningDriver.Truth), table.clone(returningDriver.Record)
    end
    -- Returning early avoids generating a whole new set of documents just to throw it away. Clones keep the stored snapshot untouched.

    local trueYear = randomGenerator:NextInteger(earliestBirthYear, latestBirthYear)
    local trueMonth = randomGenerator:NextInteger(1, 12)
    local trueDay = randomGenerator:NextInteger(1, latestSafeBirthDay)
    -- Random birth dates replace the old id-based math, which repeated in patterns a sharp player could learn.

    local firstName = NPCAppearance.GetName(appearance)
    local lastName = NPCAppearance.GetLastname(appearance)
    local displayLastName = lastName
    local displayDay, displayMonth, displayYear = trueDay, trueMonth, trueYear
    -- The display values start equal to the truth and only change when the file is flawed.

    if profile.flaws.file then
        if randomGenerator:NextInteger(1, 2) == 1 then
            displayLastName = AnomalyService.mutatelastname(lastName, profile.difficulty, lastnamePool)
        else
            displayDay, displayMonth, displayYear = AnomalyService.mutatebirthdate(trueDay, trueMonth, trueYear, profile.difficulty)
        end
    end
    -- A flawed file damages exactly one field, either the surname or the birth date, so each case has a single clear thing to catch.

    local recordId = string.format("#%05d", firstRecordNumber + driverId)
    local vehicle = pickFromList(vehicles, driverId)
    local employer = pickFromList(employers, driverId)
    local validUntil = pickFromList(validUntilDates, driverId)

    local truth: DriverTruth = {
        FullName = firstName .. " " .. lastName,
        BirthDate = formatBirthDate(trueDay, trueMonth, trueYear),
        RecordId = recordId,
        Vehicle = vehicle,
        Employment = employer,
        ValidUntil = validUntil,
    }
    local record: DriverRecord = {
        FullName = firstName .. " " .. displayLastName,
        BirthDate = formatBirthDate(displayDay, displayMonth, displayYear),
        RecordId = recordId,
        ValidUntil = validUntil,
        Vehicle = vehicle,
        Employment = employer,
        Note = "Cleared for overnight transit under " .. employer .. ".",
    }
    return truth, record
end

local function configureCar(car: Model, driverId: number, profile: DriverProfile, returningDriver: ReturningDriver?, isKaren: boolean)
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
    -- Attributes put the case state on the car itself, so any script or client can read it without a direct reference to this module.

    local fileIsCorrupted = false
    if not returningDriver then
        fileIsCorrupted = CorruptionSchedule.Roll()
    end
    car:SetAttribute("CorruptedFile", fileIsCorrupted)
    -- Returning drivers never get a corrupted file, since their paperwork has to match the first visit exactly.

    CollectionService:AddTag(car, "CheckpointCar")
end

local function createCarSession(): CarSession
    local car = carTemplate:Clone()
    car:PivotTo(spawnWaypoint.CFrame)
    car.Parent = workspace
    -- The car is positioned before parenting so it never flashes at the template's origin.

    local primaryPart = car.PrimaryPart
    assert(primaryPart, "The Car template needs a PrimaryPart so it can be moved")
    -- Failing loudly here is better than a vague nil error later.

    local invisibleMover = Instance.new("Part")
    invisibleMover.Name = "CarMover"
    invisibleMover.Anchored = true
    invisibleMover.CanCollide = false
    invisibleMover.Transparency = 1
    invisibleMover.Size = Vector3.new(1, 1, 1)
    invisibleMover.CFrame = primaryPart.CFrame
    invisibleMover.Parent = workspace
    -- Anchored so physics never pushes it, non-colliding and invisible so players never notice it. Its only job is to be tweened.

    local followConnection = RunService.Heartbeat:Connect(function()
        if car.Parent then
            car:PivotTo(invisibleMover.CFrame)
        end
    end)
    -- Every frame the car copies the mover's position. Tweening a part and pivoting a model is simpler and smoother than tweening each car piece.

    nextDriverId += 1
    return {
        car = car,
        invisibleMover = invisibleMover,
        followConnection = followConnection,
        driverId = nextDriverId,
    }
end

local function forgetOldDrivers(newestDriverId: number)
    local expiredDriverId = newestDriverId - retainedDriverCount
    appearanceById[expiredDriverId] = nil
    recordsById[expiredDriverId] = nil
    truthById[expiredDriverId] = nil
    profileById[expiredDriverId] = nil
end
-- Ids go up by exactly one per car, so removing one old entry per car keeps the tables at a fixed size. This fixes the memory growth.

local function waitForCheckpointDecision(car: Model, isKaren: boolean): CheckpointDecision
    while true do
        if isKaren and KarenService.HasExpired(car) then
            return "karenexpired"
        end
        -- Karen is checked first and on every loop, so an expired timer wins even if the gate happens to be raised.

        if GateService.IsRaised() then
            return "approved"
        end

        if ShutterService.IsOpen() then
            task.wait(pollIntervalSeconds)
        else
            local graceDeadline = os.clock() + shutterGraceSeconds
            local recovered = false
            while os.clock() < graceDeadline do
                if isKaren and KarenService.HasExpired(car) then
                    return "karenexpired"
                end
                -- The old version skipped this check during the grace period, so a Karen timeout could be missed. Now it is checked here too.
                if GateService.IsRaised() or ShutterService.IsOpen() then
                    recovered = true
                    break
                end
                task.wait(pollIntervalSeconds)
            end
            if not recovered then
                return "rejected"
            end
            -- If the shutter stayed closed the whole grace time, the driver is turned away.
        end
    end
end

local function resolveCheckpointCase(car: Model, decision: CheckpointDecision)
    local wasApproved = decision == "approved"
    car:SetAttribute("AtCheckpoint", false)
    ObjectiveService.CompleteAll("CheckpointLoop")

    if decision == "karenexpired" then
        CaseResolutionService.Resolve(car, false)
        dialogueCancelledEvent:FireAllClients()
        task.wait(karenWalkoutDelaySeconds)
        DialogueService.SayAll(KarenService.GetWalkoutLine(), karenWalkoutLineSeconds)
    else
        CaseResolutionService.Resolve(car, wasApproved)
    end
    -- A Karen timeout is always scored as a rejection and gets the walkout line instead of the normal approve or reject reaction.

    WantedPersonService.ResolveDriver(car, wasApproved)
end

local function queueReturningDriver(decision: CheckpointDecision, profile: DriverProfile, returningDriver: ReturningDriver?, appearance: any, driverId: number)
    if decision ~= "approved" then
        return
    end
    if profile.isanomaly or returningDriver or pendingReturningDriver or returningDriverUsed then
        return
    end
    -- Only a normal, approved driver can return, and only if nobody is already queued or has already come back.
    if randomGenerator:NextNumber() > returningDriverChance then
        return
    end

    pendingReturningDriver = {
        Appearance = table.clone(appearance),
        Truth = table.clone(truthById[driverId]),
        Record = table.clone(recordsById[driverId]),
    }
    -- Cloning means the queued snapshot cannot change when the stored tables are pruned later.
end

local function fireDecisionEvent(decision: CheckpointDecision)
    dialogueCancelledEvent:FireAllClients()
    if decision == "karenexpired" then
        return
    end
    -- Karen already had her own reaction, so the generic event is skipped.
    if decision == "approved" then
        approvedEvent:FireAllClients()
    else
        rejectedEvent:FireAllClients()
    end
end

local function moveCarOut(invisibleMover: BasePart, decision: CheckpointDecision)
    if decision == "approved" then
        driveMoverToWaypoint(invisibleMover, throughGateWaypoint).Completed:Wait()
        return
    end
    driveMoverToWaypoint(invisibleMover, turnAwayWaypoint).Completed:Wait()
    driveMoverToWaypoint(invisibleMover, exitAfterTurnAwayWaypoint).Completed:Wait()
    -- Rejected cars take two legs, turning away first and then leaving. Yielding on Completed keeps each leg in order.
end

local function runCheckpointCase(session: CarSession)
    local car = session.car
    local driverId = session.driverId

    local returningDriver = takeReturningDriver()
    local appearance = if returningDriver then returningDriver.Appearance else NPCAppearance.Roll()
    local driverRig = car:FindFirstChild("NPC")
    if driverRig then
        NPCAppearance.Apply(driverRig, appearance)
    end
    -- Returning drivers reuse their old look so the player can recognize them.

    local profile = createDriverProfile(driverId, returningDriver)
    local isKaren = KarenService.Roll()
    local truth, record = createDriverDocuments(driverId, appearance, profile, returningDriver)

    appearanceById[driverId] = appearance
    truthById[driverId] = truth
    recordsById[driverId] = record
    profileById[driverId] = profile

    configureCar(car, driverId, profile, returningDriver, isKaren)
    WantedPersonService.RegisterNextDriver(car, appearance)

    activeCar = car
    activeCarAppearance = appearance
    activeDriverId = driverId
    -- Publishing the active car only after it is fully configured, so other services never see a half built case.

    driveMoverToWaypoint(session.invisibleMover, checkpointWaypoint).Completed:Wait()

    car:SetAttribute("AtCheckpoint", true)
    ObjectiveService.AddAll("CheckpointLoop", "- Ask for the driver's ID and file.")
    PhotoService.DriverArrived(car)
    CaseResolutionService.BeginCase(car)
    InterrogationService.BeginCase(car, truth, record, profile)
    -- All the services that care about a case are told it has begun, and each one only needs the pieces it uses.

    local decision = waitForCheckpointDecision(car, isKaren)

    resolveCheckpointCase(car, decision)
    queueReturningDriver(decision, profile, returningDriver, appearance, driverId)

    InterrogationService.EndCase(car)
    PhotoService.DriverDeparted(car)
    KarenService.Stop(car)
    fireDecisionEvent(decision)
    resetCheckpointDesk()
    moveCarOut(session.invisibleMover, decision)

    GateService.Lower()
    ShutterService.Open()
    -- The gate and shutter are put back to their starting state so the next car begins from a known setup.

    forgetOldDrivers(driverId)
end

local function recoverFromFailure(session: CarSession)
    KarenService.Stop(session.car)
    resetCheckpointDesk()
    GateService.Lower()
    ShutterService.Open()
end
-- If a case errors halfway, the desk, gate, shutter and Karen timer are reset so the next car does not inherit a broken state.

local function finishSession(session: CarSession)
    if activeCar == session.car then
        activeCar = nil
        activeCarAppearance = nil
        activeDriverId = nil
    end
    -- Only clears the active car if it is still this one, so a late cleanup can never erase a newer car.

    session.followConnection:Disconnect()
    session.invisibleMover:Destroy()

    local reported, reportError = pcall(CarProgressService.ReportFinished, session.car)
    if not reported then
        warn("CarSystem: reporting a finished car failed: " .. tostring(reportError))
    end
    -- Reporting is protected, because a failure in the progress service must not stop traffic.

    session.car:Destroy()
    -- Destroyed after the report returns, so listeners finish with the car still present. This replaces the old task.defer, which did not wait for anything.
end

local function runCar()
    local session = createCarSession()
    local succeeded, errorMessage = pcall(runCheckpointCase, session)
    if not succeeded then
        warn("CarSystem: a checkpoint case failed: " .. tostring(errorMessage))
        pcall(recoverFromFailure, session)
    end
    -- pcall catches any error from any service. Without it one error would kill the whole traffic loop for the rest of the session.
    finishSession(session)
    -- Cleanup runs on both the success and the failure path, so the mover, connection and car never leak.
end

local CarSystem = {}

function CarSystem.GetActiveCar(): Model?
    return activeCar
end

function CarSystem.GetActiveCarAppearance(): any
    return activeCarAppearance
end

function CarSystem.GetActiveCarDriverId(): number?
    return activeDriverId
end

function CarSystem.GetAppearanceById(driverId: number): any
    return appearanceById[driverId]
end

function CarSystem.GetRecordById(driverId: number): DriverRecord?
    return recordsById[driverId]
end

function CarSystem.GetTruthById(driverId: number): DriverTruth?
    return truthById[driverId]
end

function CarSystem.GetProfileById(driverId: number): DriverProfile?
    return profileById[driverId]
end
-- Reading a missing key from a Luau table already returns nil, so the old nil guards were unnecessary. The public function names keep their original casing so other scripts calling them do not break.

function CarSystem.Init()
    local trafficLoopRunning = false

    CarRuntimeService.OnStarted(function()
        if trafficLoopRunning then
            return
        end
        trafficLoopRunning = true
        -- The flag makes Init safe if the runtime starts more than once, so two loops can never spawn cars at the same time.

        task.spawn(function()
            while true do
                while CarRuntimeService.IsPaused() do
                    task.wait(pausedPollSeconds)
                end
                -- Pausing the runtime stops new cars from spawning.

                if CarRuntimeService.IsStoryControlled() and not CarRuntimeService.TryConsumeSpawn() then
                    CarRuntimeService.WaitForSpawnBudget()
                    continue
                end
                -- During story scenes a car may only spawn if the story grants budget for it.

                runCar()
            end
        end)
        -- task.spawn runs the loop on its own thread, so the OnStarted callback returns immediately.
    end)
end

return CarSystem
