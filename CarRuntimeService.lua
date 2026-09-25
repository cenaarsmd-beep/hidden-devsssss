local carRuntimeService = {}

local startEvent = Instance.new("BindableEvent")
local hasStarted = false
local paused = false

local storyControlled = false
local remainingSpawns = 0
local spawnAvailable = Instance.new("BindableEvent")

function carRuntimeService.Start()
	if hasStarted then
		return false
	end

	hasStarted = true
	startEvent:Fire()
	return true
end

function carRuntimeService.OnStarted(callback)
	local connection = startEvent.Event:Connect(callback)

	if hasStarted then
		task.spawn(callback)
	end

	return connection
end

function carRuntimeService.HasStarted()
	return hasStarted
end

function carRuntimeService.Pause()
	paused = true
end

function carRuntimeService.Resume()
	paused = false
end

function carRuntimeService.IsPaused()
	return paused
end

function carRuntimeService.SetStoryControlled(value)
	storyControlled = value
	if value then
		remainingSpawns = 0
	end
end

function carRuntimeService.IsStoryControlled()
	return storyControlled
end

function carRuntimeService.RequestCars(amount)
	amount = math.max(0, amount or 0)
	if amount <= 0 then
		return
	end

	remainingSpawns += amount
	spawnAvailable:Fire()
end

function carRuntimeService.TryConsumeSpawn()
	if remainingSpawns > 0 then
		remainingSpawns -= 1
		return true
	end
	return false
end

function carRuntimeService.GetRemainingSpawns()
	return remainingSpawns
end

function carRuntimeService.WaitForSpawnBudget()
	while remainingSpawns <= 0 do
		spawnAvailable.Event:Wait()
	end
end

return carRuntimeService
