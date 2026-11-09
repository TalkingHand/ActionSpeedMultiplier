-- Transfer Speed Multiplier, single player: divides ISInventoryTransferAction's time by the sandbox
-- multiplier. In multiplayer the client sets maxTime to -1 and waits for the server's time, which the
-- Java patch on zombie.core.Transaction.getDuration scales, so this file does nothing there.

require "TimedActions/ISInventoryTransferAction"

local DEFAULT = 20.0

local function multiplier()
	local vars = SandboxVars and SandboxVars.TransferSpeedMultiplier
	local m = vars and tonumber(vars.Multiplier)
	if m and m > 0 then return m end
	return DEFAULT
end

local originalNew = ISInventoryTransferAction.new

function ISInventoryTransferAction:new(character, item, srcContainer, destContainer, time)
	local o = originalNew(self, character, item, srcContainer, destContainer, time)
	if isClient() or not o or type(o.maxTime) ~= "number" or o.maxTime <= 1 then
		return o
	end
	-- vanilla: 0 is instant (favourites, TradeUI), 1 is "timed action instant" (debug cheat)
	o.maxTime = math.max(1, o.maxTime / multiplier())
	-- the first queued entry copied maxTime before we changed it; later entries copy the merged
	-- actions' maxTime in checkQueueList, which this function already scaled
	if o.queueList and o.queueList[1] then
		o.queueList[1].time = o.maxTime
	end
	return o
end

print("[TransferSpeedMultiplier] ISInventoryTransferAction.new wrapped (single player)")
