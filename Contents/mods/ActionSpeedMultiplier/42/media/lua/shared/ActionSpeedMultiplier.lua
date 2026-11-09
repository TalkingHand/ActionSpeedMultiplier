-- Action Speed Multiplier: timed actions take the vanilla time divided by the sandbox option ActionSpeed.
--
-- Every timed action's time goes through ISBaseTimedAction:adjustMaxTime: create() on the client and in
-- single player, and NetTimedAction.getDuration (Java) on the server, which calls
-- adjustMaxTime(getDuration()). Dividing there keeps client and server in step. Shared, so the server
-- loads it too.
--
-- Item transfers (ISInventoryTransferAction, ISGrabItemAction) are left alone here: they follow
-- TransferSpeed instead (ActionSpeedMultiplier_Transfer.lua in single player, the Java patch on servers).

require "TimedActions/ISBaseTimedAction"

local DEFAULT_ACTION = 2.0

local TRANSFER_TYPES = {
	ISInventoryTransferAction = true,
	ISGrabItemAction = true,
}

local ASM = {}
ASM.skip = 0 -- > 0 while a call must stay vanilla (ISWashClothing:getDuration)

function ASM.actionMultiplier()
	local vars = SandboxVars and SandboxVars.ActionSpeedMultiplier
	local m = vars and tonumber(vars.ActionSpeed)
	if m and m > 0 then return m end
	return DEFAULT_ACTION
end

-- Some actions do part of their work on their own clock inside update() (one litre of milk, one egg,
-- one dirt patch every timePerX ticks). Those clocks are scaled once with maxTime, or the action ends
-- before its work is done.
local function scaleOwnClocks(action, m)
	if action._ASM_clocksScaled then return end
	action._ASM_clocksScaled = true
	for k, v in pairs(action) do
		if type(k) == "string" and type(v) == "number" and v > 0 and k:sub(1, 7) == "timePer" then
			action[k] = v / m
		end
	end
end

local originalAdjust = ISBaseTimedAction.adjustMaxTime

function ISBaseTimedAction:adjustMaxTime(maxTime)
	local t = originalAdjust(self, maxTime)
	if ASM.skip > 0 or type(t) ~= "number" or t <= 1 or TRANSFER_TYPES[self.Type] then
		return t
	end
	local m = ASM.actionMultiplier()
	if m == 1 then return t end
	scaleOwnClocks(self, m)
	return math.max(1, t / m)
end

-- ISWashClothing:getDuration already returns adjustMaxTime(maxTime), and create() adjusts again
-- (vanilla adjusts that one twice). Keep the first one vanilla so it is divided once.
local function wrapWashClothing()
	if not ISWashClothing or ISWashClothing._ASM_wrapped then return end
	ISWashClothing._ASM_wrapped = true
	local originalGetDuration = ISWashClothing.getDuration
	function ISWashClothing:getDuration(...)
		ASM.skip = ASM.skip + 1
		local ok, result = pcall(originalGetDuration, self, ...)
		ASM.skip = ASM.skip - 1
		if not ok then
			print("[ActionSpeedMultiplier] ISWashClothing:getDuration failed: " .. tostring(result))
			return self.maxTime
		end
		return result
	end
end

pcall(require, "TimedActions/ISWashClothing")
wrapWashClothing()
Events.OnGameStart.Add(wrapWashClothing)
if Events.OnServerStarted then Events.OnServerStarted.Add(wrapWashClothing) end

ActionSpeedMultiplierLua = ASM
print("[ActionSpeedMultiplier] ISBaseTimedAction.adjustMaxTime wrapped")
