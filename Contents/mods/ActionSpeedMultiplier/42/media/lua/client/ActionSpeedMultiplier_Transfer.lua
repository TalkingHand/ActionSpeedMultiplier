-- Action Speed Multiplier, item transfers in single player: ISInventoryTransferAction and
-- ISGrabItemAction take their time divided by the sandbox option TransferSpeed.
-- In multiplayer the client sets maxTime to -1 and waits for the server's time, which the Java patch on
-- zombie.core.Transaction.getDuration scales, so the time wrappers do nothing there. Batches work in
-- multiplayer too (checkQueueList wrapper below): one server transaction per batch, timed by the server.
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

-- Each item's divided time before the 1-tick floor, so a batch can add up the exact times
-- (keyed by the moved object: InventoryItem for transfers, IsoWorldInventoryObject for grabs).
local exactTime = setmetatable({}, { __mode = "k" })

local function wrapNew(class)
	local originalNew = class.new
	class.new = function(self, ...)
		local o = originalNew(self, ...)
		if isClient() or not o or type(o.maxTime) ~= "number" or o.maxTime <= 1 then
			return o
		end
		-- vanilla: 0 is instant (favourites, TradeUI), 1 is "timed action instant" (debug cheat)
		local exact = o.maxTime / transferMultiplier()
		if o.item then exactTime[o.item] = exact end
		o.maxTime = math.max(1, exact)
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
		local exact = time / transferMultiplier()
		if item then exactTime[item] = exact end
		time = math.max(1, exact)
	end
	return originalGrabNew(self, character, item, time, ...)
end

-- Batches (sandbox option BulkTransferSize, single player). Vanilla times a queue of transfers one entry
-- at a time (an entry is one item, or up to 20 light items of one type sharing one item's time), each
-- with its own timer, restart and 1-tick floor. Here the queue is regrouped into batches of BulkTransferSize
-- items; a batch moves its items together and takes the sum of their times. So the total is the vanilla
-- total divided by TransferSpeed (100 items, size 20: 5 steps of 20 items, each 20 items' time).
-- perform still checks isValid item by item and stops at the first item that no longer fits, as vanilla.
local DEFAULT_BULK = 20

local function bulkSize()
	local vars = SandboxVars and SandboxVars.ActionSpeedMultiplier
	local n = vars and tonumber(vars.BulkTransferSize)
	if n then return math.floor(n) end
	return DEFAULT_BULK
end

-- Regroups action.queueList in place. Returns the first batch's time and the first entry's time before,
-- or nil when nothing changed.
local function foldQueue(action)
	local list = action.queueList
	if type(list) ~= "table" or #list == 0 then return nil end
	local size = bulkSize()
	if size <= 1 then return nil end
	local items, times = {}, {}
	for _, entry in ipairs(list) do
		local n = #entry.items
		local share = n > 0 and (tonumber(entry.time) or 0) / n or 0
		for _, item in ipairs(entry.items) do
			items[#items + 1] = item
			-- an entry of vanilla-bundled light items shares one item's time: split it, not multiply it
			times[#times + 1] = (n == 1 and exactTime[item]) or share
		end
	end
	local batches = {}
	for i = 1, #items, size do
		-- a type no item has, so vanilla checkQueueList never adds light items to a batch without its time
		local b = { items = {}, time = 0, type = "ActionSpeedMultiplier.Batch" }
		for j = i, math.min(i + size - 1, #items) do
			b.items[#b.items + 1] = items[j]
			b.time = b.time + times[j]
		end
		b.time = math.max(1, b.time)
		batches[#batches + 1] = b
	end
	-- unchanged (same batches as last update): leave it
	if #batches == #list then
		local same = true
		for k, b in ipairs(batches) do
			if #b.items ~= #list[k].items or math.abs(b.time - (tonumber(list[k].time) or 0)) > 1e-6 then
				same = false
				break
			end
		end
		if same then return nil end
	end
	local before = tonumber(list[1].time) or 0
	for k = #list, 1, -1 do list[k] = nil end
	for k, b in ipairs(batches) do list[k] = b end
	return batches[1].time, before
end

local function applyFold(action)
	local t, before = foldQueue(action)
	if not t or not action.action or type(action.maxTime) ~= "number" or action.maxTime <= 0 then return end
	-- keep vanilla's factor on the running entry (start() makes it 1.5x while walking)
	local factor = before and before > 0 and action.maxTime / before or 1
	local newTime = math.max(1, t * factor)
	if math.abs(newTime - action.maxTime) > 1e-6 then
		action.maxTime = newTime
		action.action:setTime(newTime)
	end
end

-- ISInventoryTransferAction: in single player the following transfers join the queue list only in
-- perform (checkQueueList); the first action starts before the others are queued, so this merges them
-- on update (the queueing call has finished by then) and regroups the result.
local originalTransferUpdate = ISInventoryTransferAction.update
ISInventoryTransferAction.update = function(self, ...)
	if not isClient() and self.queueList and bulkSize() > 1 then
		self:checkQueueList()
		applyFold(self)
	end
	return originalTransferUpdate(self, ...)
end

-- ISGrabItemAction: later grabs join the running grab's queue list in new; regroup it on update.
local originalGrabUpdate = ISGrabItemAction.update
ISGrabItemAction.update = function(self, ...)
	if not isClient() and self.queueList then
		applyFold(self)
	end
	return originalGrabUpdate(self, ...)
end

-- Batches in multiplayer. The client sends one server transaction per queueList entry (start and perform:
-- checkQueueList, then createItemTransaction(queueList[1].items)), so the queue is regrouped right after
-- vanilla's checkQueueList. The server times a transaction of several items by the sum of their times
-- (Java Speed.batchSum; vanilla takes the slowest), so the total stays the vanilla total divided by
-- TransferSpeed. The server checks room for each item alone, not for the batch together, so the first
-- batch (the one sent next) is cut where the destination would be full or over the server's item limit.
local function itemCount(item)
	if instanceof(item, "InventoryContainer") and item:getInventory() then
		return luautils.countItemsRecursive({ item:getInventory() }, 1)
	end
	return 1
end

-- How many of items (from 1) fit in the destination together, at least 1 (vanilla then accepts or rejects it).
local function roomForBatch(action, items, size)
	local dest, chr = action.destContainer, action.character
	local n = math.min(size, #items)
	if not dest or not chr or n <= 1 then return n end
	local floor = dest:getType() == "floor"
	local square = floor and chr:getCurrentSquare() or nil
	local capacity = dest:getEffectiveCapacity(chr)
	local parent = dest:getParent()
	local plain = not instanceof(parent, "IsoGameCharacter") and not instanceof(parent, "BaseVehicle")
	local used = floor and (square and square:getTotalWeightOfItemsOnFloor() or 0) or dest:getCapacityWeight()
	-- the server option ItemNumbersLimitPerContainer, as ISInventoryTransferAction:isValid counts it
	local countLeft = nil
	local limit = getServerOptions and getServerOptions():getInteger("ItemNumbersLimitPerContainer") or 0
	if limit > 0 and not instanceof(parent, "IsoGameCharacter") and not dest:getItems():isEmpty() then
		local destRoot = luautils.findRootInventory(dest)
		local srcRoot = luautils.findRootInventory(action.srcContainer)
		if destRoot ~= srcRoot then
			local inDest = luautils.countItemsRecursive({ destRoot }, 0)
			if destRoot:getContainingItem() then inDest = inDest + 1 end
			countLeft = limit - inDest
		end
	end
	local weight, count = 0, 0
	for k = 1, n do
		local item = items[k]
		local w = weight + item:getUnequippedWeight()
		local c = count + itemCount(item)
		if k > 1 then
			if floor then
				if used + w > capacity then return k - 1 end
			else
				if not dest:hasRoomFor(chr, w) then return k - 1 end
				if plain and capacity < used + w then return k - 1 end
			end
			if countLeft and c > countLeft then return k - 1 end
		end
		weight, count = w, c
	end
	return n
end

-- Regroups a multiplayer action's queueList in place: batches of BulkTransferSize items, the first one cut
-- to what fits. Entry times stay -1 (the client waits for the server's time). Returns true if it changed.
local function foldQueueMP(action)
	local list = action.queueList
	if type(list) ~= "table" or #list == 0 then return false end
	local size = bulkSize()
	if size <= 1 then return false end
	local items = {}
	for _, entry in ipairs(list) do
		-- only the vanilla multiplayer form: maxTime -1, timed by the server
		if tonumber(entry.time) ~= -1 or type(entry.items) ~= "table" then return false end
		for _, item in ipairs(entry.items) do items[#items + 1] = item end
	end
	if #items <= 1 then return false end
	-- if the room check fails, leave the queue to vanilla rather than send an unchecked batch
	local ok, first = pcall(roomForBatch, action, items, size)
	if not ok or type(first) ~= "number" or first < 1 then
		print("[ActionSpeedMultiplier] batch room check failed, queue left as vanilla: " .. tostring(first))
		return false
	end
	local batches = {}
	local i = 1
	while i <= #items do
		local count = (#batches == 0) and first or size
		local b = { items = {}, time = -1, type = "ActionSpeedMultiplier.Batch" }
		for j = i, math.min(i + count - 1, #items) do b.items[#b.items + 1] = items[j] end
		batches[#batches + 1] = b
		i = i + count
	end
	if #batches == #list then
		local same = true
		for k, b in ipairs(batches) do
			if #b.items ~= #list[k].items then same = false break end
		end
		if same then return false end
	end
	for k = #list, 1, -1 do list[k] = nil end
	for k, b in ipairs(batches) do list[k] = b end
	return true
end

local originalCheckQueueList = ISInventoryTransferAction.checkQueueList
ISInventoryTransferAction.checkQueueList = function(self, ...)
	local r = originalCheckQueueList(self, ...)
	if isClient() then foldQueueMP(self) end
	return r
end

ActionSpeedMultiplierLua = ActionSpeedMultiplierLua or {}
ActionSpeedMultiplierLua.foldQueue = foldQueue
ActionSpeedMultiplierLua.exactTransferTime = exactTime
ActionSpeedMultiplierLua.foldQueueMP = foldQueueMP
ActionSpeedMultiplierLua.roomForBatch = roomForBatch

print("[ActionSpeedMultiplier] ISInventoryTransferAction and ISGrabItemAction new/update wrapped (single player), checkQueueList wrapped (multiplayer batches)")
