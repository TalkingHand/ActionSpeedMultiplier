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

local DEFAULT_ACTION = 20.0

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
-- before its work is done. On a server the same clock sets the period of serverStart's
-- emulateAnimEvent (timePerX * 20 ms), which does the work there.
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
	if ASM.skip > 0 or type(t) ~= "number" or TRANSFER_TYPES[self.Type] then
		return t
	end
	-- -1: no fixed time, the action runs until its work is done. ISHutchGrabEgg, ISGiveWaterToAnimal and
	-- ISAddWaterToTrough return it from getDuration on a server, ISMilkAnimal everywhere. The time stays -1,
	-- but the work clock is still scaled, or the server takes one egg per 800 ms as vanilla
	-- (serverStart: emulateAnimEvent every timePerEgg * 20 ms; NetTimedAction.start calls
	-- adjustMaxTime(getDuration()) just before serverStart).
	if t < 0 then
		local m = ASM.actionMultiplier()
		if m ~= 1 then scaleOwnClocks(self, m) end
		return t
	end
	if t <= 1 then return t end
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

-- ISHutchGrabEgg (hutch window, "Grab eggs"), single player. Vanilla update takes one egg each time its
-- timer passes another timePerEgg, at most one per tick, and the action's time is eggs * timePerEgg + 5.
-- Divided, timePerEgg is 2 ticks at 20x and 0.4 at 100x: it can pass more than once in a tick, and the
-- 5-tick slack for the last egg shrinks to under one tick (lost when the game keeps the time as an int).
-- So the eggs that came due in a tick are all taken, and if the time runs out with eggs still in the box,
-- perform takes the rest of the eggs counted when the action began (vanilla takes them all within its time).
-- On a server the eggs come from animEvent instead (serverStart's period, scaled in adjustMaxTime).
-- new is not wrapped: NetTimedAction sends new's parameter names to the server, a vararg wrapper has none.
local function takeEgg(action)
	-- vanilla ISHutchGrabEgg:update, one egg
	local egg = action.nestbox:removeEgg(0)
	if not egg then return false end
	addXp(action.character, Perks.Husbandry, 1)
	action.character:getInventory():AddItem(egg)
	return true
end

local function takeDueEggs(action, count)
	local taken = 0
	while taken < count and action.nestbox and action.nestbox:getEggsNb() > 0 do
		if not takeEgg(action) then break end
		taken = taken + 1
	end
	return taken
end

local function wrapHutchGrabEgg()
	if not ISHutchGrabEgg or ISHutchGrabEgg._ASM_wrapped then return end
	ISHutchGrabEgg._ASM_wrapped = true
	local originalUpdate = ISHutchGrabEgg.update
	function ISHutchGrabEgg:update(...)
		local here = not isClient() and not isServer()
		if here and self._ASM_eggs == nil and self.nestbox then
			self._ASM_eggs = self.nestbox:getEggsNb()
		end
		local before = tonumber(self.lastTimer) or 0
		local r = originalUpdate(self, ...)
		local after = tonumber(self.lastTimer) or 0
		-- vanilla took one egg for this step; take the others that also came due
		if here and self._ASM_clocksScaled and after > before + 1 then
			local ok, err = pcall(takeDueEggs, self, after - before - 1)
			if not ok then print("[ActionSpeedMultiplier] ISHutchGrabEgg catch-up failed: " .. tostring(err)) end
		end
		return r
	end
	local originalPerform = ISHutchGrabEgg.perform
	function ISHutchGrabEgg:perform(...)
		if not isClient() and not isServer() and self._ASM_clocksScaled and self._ASM_eggs then
			local left = self._ASM_eggs - (tonumber(self.lastTimer) or 0)
			if left > 0 then
				local ok, err = pcall(takeDueEggs, self, left)
				if not ok then print("[ActionSpeedMultiplier] ISHutchGrabEgg perform top-up failed: " .. tostring(err)) end
			end
		end
		return originalPerform(self, ...)
	end
end

pcall(require, "TimedActions/Animals/ISHutchGrabEgg")
wrapHutchGrabEgg()
Events.OnGameStart.Add(wrapHutchGrabEgg)
if Events.OnServerStarted then Events.OnServerStarted.Add(wrapHutchGrabEgg) end
ASM.takeDueEggs = takeDueEggs

ActionSpeedMultiplierLua = ASM
print("[ActionSpeedMultiplier] ISBaseTimedAction.adjustMaxTime wrapped, ISHutchGrabEgg update/perform wrapped: " .. tostring(ISHutchGrabEgg ~= nil and ISHutchGrabEgg._ASM_wrapped == true))
