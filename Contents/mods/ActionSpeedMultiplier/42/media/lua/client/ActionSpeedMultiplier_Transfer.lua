-- Action Speed Multiplier, item transfers in single player: ISInventoryTransferAction and
-- ISGrabItemAction take their time divided by the sandbox option TransferSpeed.
-- In multiplayer the client sets maxTime to -1 and waits for the server's time, which the Java patch on
-- zombie.core.Transaction.getDuration scales, so these wrappers do nothing there.
-- (ActionSpeedMultiplier.lua leaves both actions out of the general ActionSpeed.)

require "TimedActions/ISInventoryTransferAction"
require "TimedActions/ISGrabItemAction"

local DEFAULT_TRANSFER = 20.0

local function transferMultiplier()
	local vars = SandboxVars and SandboxVars.ActionSpeedMultiplier
	local m = vars and tonumber(vars.TransferSpeed)
	if m and m > 0 then return m end
	return DEFAULT_TRANSFER
end

local function wrapNew(class)
	local originalNew = class.new
	class.new = function(self, ...)
		local o = originalNew(self, ...)
		if isClient() or not o or type(o.maxTime) ~= "number" or o.maxTime <= 1 then
			return o
		end
		-- vanilla: 0 is instant (favourites, TradeUI), 1 is "timed action instant" (debug cheat)
		o.maxTime = math.max(1, o.maxTime / transferMultiplier())
		-- the first queued entry copied maxTime before we changed it; later entries copy the merged
		-- actions' maxTime, which this function already scaled
		if o.queueList and o.queueList[1] then
			o.queueList[1].time = o.maxTime
		end
		return o
	end
end

wrapNew(ISInventoryTransferAction)

-- ISGrabItemAction:new(character, item, time) copies time into a queue entry inside new (checkQueueList,
-- possibly an earlier grab action's queue), so the time is divided before the original runs.
local originalGrabNew = ISGrabItemAction.new
ISGrabItemAction.new = function(self, character, item, time, ...)
	if not isClient() and type(time) == "number" and time > 1 then
		time = math.max(1, time / transferMultiplier())
	end
	return originalGrabNew(self, character, item, time, ...)
end

print("[ActionSpeedMultiplier] ISInventoryTransferAction.new and ISGrabItemAction.new wrapped (single player)")
