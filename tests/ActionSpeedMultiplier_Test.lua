-- Single-player in-game test, test environment only: pzt installs this file into the test copy
-- of the mod (TEST_FILES in pzt.conf). Results: "[ActionSpeedMultiplierTest]" lines
-- (failures also "[PZTest] FAIL"). Never error(): under -debug it opens the debugger.

local function log(...)
	local parts = {}
	for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
	print("[ActionSpeedMultiplierTest] " .. table.concat(parts, " "))
end

local T = { pass = 0, fail = 0, runs = {} }
ActionSpeedMultiplierTest = T

local function check(label, ok, extra)
	if ok then T.pass = T.pass + 1 else T.fail = T.fail + 1 end
	log(ok and "PASS" or "FAIL", label, extra or "")
	if not ok and PZTest then PZTest.fail("ActionSpeedMultiplierTest " .. label .. " " .. tostring(extra or "")) end
end

local function near(label, got, want, tol)
	tol = tol or 0.01
	check(label, got ~= nil and want ~= nil and math.abs(got - want) <= tol * math.max(1, math.abs(want)),
		"got=" .. tostring(got) .. " want=" .. tostring(want))
end

-- both sides: Lua reads SandboxVars, Java reads SandboxOptions.instance
local function setOption(name, m)
	local opt = getSandboxOptions():getOptionByName("ActionSpeedMultiplier." .. name)
	if opt then opt:setValue(m) end
	SandboxVars.ActionSpeedMultiplier = SandboxVars.ActionSpeedMultiplier or {}
	SandboxVars.ActionSpeedMultiplier[name] = m
end
local function setMultiplier(m) setOption("TransferSpeed", m) end
local function setActionMultiplier(m) setOption("ActionSpeed", m) end

local function setup()
	local player = getPlayer()
	local inv = player:getInventory()
	if not T.bag or T.bag:getContainer() ~= inv then
		T.bag = inv:AddItem("Base.Bag_Schoolbag")
	end
	if not T.plank or not T.plank:getContainer() then
		T.plank = inv:AddItem("Base.Plank")
	end
	return player, inv, T.bag:getInventory()
end

function T.basics()
	check("Java API exposed", ActionSpeedMultiplier ~= nil)
	check("Lua side loaded", ActionSpeedMultiplierLua ~= nil)
	check("transfer option exists", getSandboxOptions():getOptionByName("ActionSpeedMultiplier.TransferSpeed") ~= nil)
	check("action option exists", getSandboxOptions():getOptionByName("ActionSpeedMultiplier.ActionSpeed") ~= nil)
	if ActionSpeedMultiplier then
		near("default transfer multiplier 20", ActionSpeedMultiplier.multiplier(), 20.0)
	end
	if ActionSpeedMultiplierLua then
		near("default action multiplier 20", ActionSpeedMultiplierLua.actionMultiplier(), 20.0)
	end
	check("ISWashClothing getDuration wrapped", ISWashClothing ~= nil and ISWashClothing._ASM_wrapped == true)
	check("single player (Lua side active)", not isClient())
end

-- Lua side (single player): maxTime divided by the multiplier
function T.luaTimes()
	local player, inv, bagInv = setup()
	local times = {}
	for _, m in ipairs({ 1, 2, 4, 0.5 }) do
		setMultiplier(m)
		local a = ISInventoryTransferAction:new(player, T.plank, inv, bagInv)
		times[m] = a.maxTime
		near("queue entry follows maxTime m=" .. m, a.queueList[1].time, a.maxTime)
	end
	log("lua maxTime by multiplier", times[1], times[2], times[4], times[0.5])
	check("vanilla time > 1", times[1] > 1, times[1])
	near("lua m=2", times[2], times[1] / 2)
	near("lua m=4", times[4], times[1] / 4)
	near("lua m=0.5 (slower)", times[0.5], times[1] * 2)

	-- the option's max is 100; a lighter item at 100x would go below 1
	setMultiplier(100)
	local light = player:getInventory():AddItem("Base.Pencil")
	local a = ISInventoryTransferAction:new(player, light, inv, bagInv)
	check("never below 1", a.maxTime >= 1, a.maxTime)
	player:getInventory():Remove(light)
	T.vanillaLua = times[1]
	setMultiplier(20)
end

-- Java side: the duration a server would give (private Transaction.getDuration, patched)
function T.serverTimes()
	if not ActionSpeedMultiplier then check("Java API for serverTimes", false) return end
	local player, inv, bagInv = setup()
	local before = ActionSpeedMultiplier.applied()
	for _, m in ipairs({ 1, 2, 4, 0.5 }) do
		setMultiplier(m)
		local v = ActionSpeedMultiplier.serverDuration(player, T.plank, inv, bagInv, true)
		local p = ActionSpeedMultiplier.serverDuration(player, T.plank, inv, bagInv, false)
		log("server duration ms m=" .. m, "vanilla", v, "patched", p)
		check("server vanilla > 0 m=" .. m, v > 0, v)
		near("server patched = vanilla / m, m=" .. m, p, v / m)
	end
	check("patch ran", ActionSpeedMultiplier.applied() > before, ActionSpeedMultiplier.applied() - before)
	-- the server formula is Lua's maxTime * 20 ms; matches when the containers resolve in single player
	setMultiplier(1)
	local v = ActionSpeedMultiplier.serverDuration(player, T.plank, inv, bagInv, true)
	log("server vanilla", v, "lua vanilla * 20", (T.vanillaLua or 0) * 20)
	setMultiplier(20)
end

-- a real queued transfer, timed in game ms, for two multipliers
function T.transferStart(m)
	local player, inv, bagInv = setup()
	setMultiplier(m)
	-- start from the main inventory
	if T.plank:getContainer() ~= inv then
		T.plank:getContainer():Remove(T.plank)
		inv:AddItem(T.plank)
	end
	local run = { m = m, start = getTimestampMs() }
	T.runs[m] = run
	local a = ISInventoryTransferAction:new(player, T.plank, inv, bagInv)
	run.maxTime = a.maxTime
	a:setOnComplete(function() run.done = getTimestampMs() end)
	ISTimedActionQueue.add(a)
	log("transfer queued m=" .. m, "maxTime", a.maxTime)
end

function T.transferCheck(m)
	local run = T.runs[m]
	local _, _, bagInv = setup()
	check("plank arrived m=" .. m, T.plank:getContainer() == bagInv)
	check("transfer finished m=" .. m, run and run.done ~= nil)
	if run and run.done then
		run.ms = run.done - run.start
		log("transfer took ms m=" .. m, run.ms, "maxTime", run.maxTime)
	end
end

function T.compare()
	local slow, fast = T.runs[1], T.runs[4]
	if slow and fast and slow.ms and fast.ms then
		local ratio = slow.ms / math.max(1, fast.ms)
		log("real time ratio m=1 / m=4", ratio)
		check("m=4 at least 2.5x faster in real time", ratio >= 2.5, ratio)
	else
		check("both timed transfers finished", false)
	end
	setMultiplier(20)
end

-- general actions: adjustMaxTime divides by ActionSpeed, transfers stay out of it
local TestAction = ISBaseTimedAction:derive("ActionSpeedMultiplierTestAction")
function TestAction:isValid() return true end
function TestAction:perform()
	if self.onDone then self.onDone() end
	ISBaseTimedAction.perform(self)
end
function TestAction:new(character, time)
	local o = ISBaseTimedAction.new(self, character)
	o.maxTime = time
	o.stopOnWalk = false
	o.stopOnRun = false
	return o
end

function T.actionTimes()
	local player, inv, bagInv = setup()
	local times = {}
	for _, m in ipairs({ 1, 2, 4, 0.5 }) do
		setActionMultiplier(m)
		times[m] = TestAction:new(player, 100):adjustMaxTime(100)
	end
	log("action adjustMaxTime(100) by multiplier", times[1], times[2], times[4], times[0.5])
	near("action m=2", times[2], times[1] / 2)
	near("action m=4", times[4], times[1] / 4)
	near("action m=0.5 (slower)", times[0.5], times[1] * 2)

	setActionMultiplier(4)
	setMultiplier(1)
	local tr = ISInventoryTransferAction:new(player, T.plank, inv, bagInv)
	near("transfer action not divided by ActionSpeed", tr:adjustMaxTime(100), times[1])
	setActionMultiplier(100)
	near("never below 1", TestAction:new(player, 100):adjustMaxTime(1.5), 1)

	-- an action with its own clock (ISMilkAnimal-style timePerLiter): scaled once with maxTime
	setActionMultiplier(4)
	local clocked = TestAction:new(player, 100)
	clocked.timePerLiter = 40
	clocked.timer = 0
	clocked:adjustMaxTime(100)
	near("own clock timePerLiter divided", clocked.timePerLiter, 10)
	clocked:adjustMaxTime(100)
	near("own clock divided only once", clocked.timePerLiter, 10)
	check("other fields untouched", clocked.timer == 0)
	setActionMultiplier(20)
	setMultiplier(20)
end

-- ISGrabItemAction (pick up from the ground) follows TransferSpeed in single player
function T.grabTimes()
	local player = getPlayer()
	local sq = player:getCurrentSquare()
	local ok, w = pcall(function() return sq:AddWorldInventoryItem("Base.Plank", 0.5, 0.5, 0) end)
	local worldItem = ok and w and w:getWorldItem()
	if not worldItem then check("world item for grab", false) return end
	setMultiplier(4)
	local a = ISGrabItemAction:new(player, worldItem, 100)
	near("grab maxTime m=4", a.maxTime, 25)
	near("grab queue entry follows", a.queueList and a.queueList[1] and a.queueList[1].time, 25)
	pcall(function() sq:transmitRemoveItemFromSquare(worldItem) end)
	setMultiplier(20)
end

-- a real queued action through create()/adjustMaxTime, timed in game ms
function T.actionStart(m)
	local player = getPlayer()
	setActionMultiplier(m)
	local run = { m = m, start = getTimestampMs() }
	T.actionRuns = T.actionRuns or {}
	T.actionRuns[m] = run
	local a = TestAction:new(player, 150)
	a.onDone = function() run.done = getTimestampMs() end
	ISTimedActionQueue.add(a)
	log("test action queued m=" .. m)
end

function T.actionCheck(m)
	local run = T.actionRuns and T.actionRuns[m]
	check("test action finished m=" .. m, run and run.done ~= nil)
	if run and run.done then
		run.ms = run.done - run.start
		log("test action took ms m=" .. m, run.ms)
	end
end

function T.actionCompare()
	local slow, fast = T.actionRuns and T.actionRuns[1], T.actionRuns and T.actionRuns[4]
	if slow and fast and slow.ms and fast.ms then
		local ratio = slow.ms / math.max(1, fast.ms)
		log("action real time ratio m=1 / m=4", ratio)
		check("action m=4 at least 2.5x faster in real time", ratio >= 2.5, ratio)
	else
		check("both timed test actions finished", false)
	end
	setActionMultiplier(20)
end

-- batches: foldQueue on plain tables, then real queued transfers of 15 apples item by item and in one batch
local function setBulk(n) setOption("BulkTransferSize", n) end

function T.bulkFold()
	local fold = ActionSpeedMultiplierLua and ActionSpeedMultiplierLua.foldQueue
	check("foldQueue exposed", fold ~= nil)
	if not fold then return end
	local function list(n, t)
		local l = {}
		for i = 1, n do l[i] = { items = { "a" .. i }, time = t or 5, type = "x" } end
		return { queueList = l }
	end
	setBulk(20)
	local a = list(100, 5)
	local t = fold(a)
	check("100 items, size 20: 5 batches", #a.queueList == 5 and #a.queueList[1].items == 20, #a.queueList)
	near("batch time = 20 items' time", t, 100)
	local total = 0
	for _, e in ipairs(a.queueList) do total = total + e.time end
	near("total = 100 items' time", total, 500)
	check("item order kept", a.queueList[1].items[1] == "a1" and a.queueList[5].items[20] == "a100")
	check("second update: unchanged", fold(a) == nil)
	-- a vanilla bundle of 20 light items with one item's time keeps that time in total
	local c = { queueList = { { items = {}, time = 4, type = "n" }, { items = { "b" }, time = 6, type = "y" } } }
	for i = 1, 20 do c.queueList[1].items[i] = "n" .. i end
	fold(c)
	check("21 items, size 20: 2 batches", #c.queueList == 2, #c.queueList)
	near("bundle time split, not multiplied", c.queueList[1].time + c.queueList[2].time, 10)
	setBulk(1)
	check("size 1: vanilla", fold(list(50)) == nil)
	setBulk(20)
end

function T.bulkStart(n)
	local player, inv, bagInv = setup()
	setMultiplier(2)
	setBulk(n)
	T.apples = T.apples or {}
	for i = 1, 15 do
		local a = T.apples[i]
		if a and a:getContainer() then a:getContainer():Remove(a) end
		T.apples[i] = inv:AddItem("Base.Apple")
	end
	T.bulkRuns = T.bulkRuns or {}
	local run = { n = n, start = getTimestampMs(), exact = 0 }
	T.bulkRuns[n] = run
	for i = 1, 15 do
		local a = ISInventoryTransferAction:new(player, T.apples[i], inv, bagInv)
		run.exact = run.exact + (ActionSpeedMultiplierLua.exactTransferTime[T.apples[i]] or 0)
		ISTimedActionQueue.add(a)
	end
	log("batch queued n=" .. n, "sum of exact times", run.exact)
	-- onComplete blocks merging, so watch arrivals on tick
	T.bulkWatch = function()
		local now = getTimestampMs()
		for i = 1, 15 do
			if T.apples[i]:getContainer() == bagInv then
				run.first = run.first or now
				if i == 15 then run.done = run.done or now end
			end
		end
	end
	Events.OnTick.Add(T.bulkWatch)
end

function T.bulkCheck(n)
	local run = T.bulkRuns and T.bulkRuns[n]
	local _, _, bagInv = setup()
	if T.bulkWatch then Events.OnTick.Remove(T.bulkWatch); T.bulkWatch = nil end
	local arrived = 0
	for i = 1, 15 do if T.apples[i]:getContainer() == bagInv then arrived = arrived + 1 end end
	check("all 15 apples arrived n=" .. n, arrived == 15, arrived)
	check("transfer finished n=" .. n, run and run.done ~= nil)
	if run and run.done then
		run.ms = run.done - run.start
		run.spread = run.done - run.first
		log("15 apples took ms n=" .. n, run.ms, "first to last arrival ms", run.spread)
	end
end

-- The game keeps maxTime as an int (BaseAction.maxTime, LuaTimedActionNew.setTime(int)), so item by item
-- each apple's 4.8 ticks runs as 4 and the total comes out under the exact sum. A batch adds the exact
-- times first, so it should take the exact sum: compared with ms per tick from the plank run (transferStart(1)).
function T.bulkCompare()
	local seq, bulk, plank = T.bulkRuns and T.bulkRuns[1], T.bulkRuns and T.bulkRuns[20], T.runs[1]
	if seq and bulk and seq.ms and bulk.ms and plank and plank.ms and plank.maxTime then
		local msPerTick = plank.ms / plank.maxTime
		local ideal = bulk.exact * msPerTick
		local ratio = bulk.ms / ideal
		log("ms per tick", msPerTick, "ideal ms", ideal, "batch ms", bulk.ms, "item by item ms", seq.ms)
		check("batch takes the exact sum of item times (0.9-1.1x ideal)", ratio >= 0.9 and ratio <= 1.1, ratio)
		check("batch: apples arrive together", bulk.spread <= 100, bulk.spread)
		check("item by item: apples arrive spread out", seq.spread > 200, seq.spread)
	else
		check("plank and both batch runs finished", false)
	end
	setMultiplier(20)
	setBulk(20)
end

-- floor grabs: 15 different types (vanilla grabs up to 20 of one type in one item's time, any weight),
-- queued the way the context menu does; item by item vs one batch, against the exact sum
local GRAB_TYPES = { "Apple", "Banana", "Orange", "Carrots", "Potato", "Tomato", "Lemon", "Lime", "Peach",
	"Pear", "Cabbage", "Corn", "Eggplant", "Onion", "Grapefruit" }

function T.grabBulkStart(n)
	local player = getPlayer()
	local inv = player:getInventory()
	local sq = player:getCurrentSquare()
	setMultiplier(2)
	setBulk(n)
	T.grabRuns = T.grabRuns or {}
	local run = { n = n, exact = 0, items = {} }
	T.grabRuns[n] = run
	local exactTime = ActionSpeedMultiplierLua.exactTransferTime
	local worlds = {}
	for i, t in ipairs(GRAB_TYPES) do
		local ok, item = pcall(function() return sq:AddWorldInventoryItem("Base." .. t, 0.2 + (i % 5) * 0.15, 0.2 + math.floor(i / 5) * 0.2, 0) end)
		if ok and item and item:getWorldItem() then
			run.items[#run.items + 1] = item
			worlds[#worlds + 1] = item:getWorldItem()
		end
	end
	run.start = getTimestampMs()
	for _, w in ipairs(worlds) do
		local time = ISWorldObjectContextMenu.grabItemTime(player, w)
		ISTimedActionQueue.add(ISGrabItemAction:new(player, w, time))
		run.exact = run.exact + (exactTime[w] or 0)
	end
	log("grab queued n=" .. n, "items", #run.items, "sum of exact times", run.exact)
	T.grabWatch = function()
		local now = getTimestampMs()
		local got = 0
		for _, item in ipairs(run.items) do if item:getContainer() == inv then got = got + 1 end end
		if got > 0 then run.first = run.first or now end
		if got == #run.items then run.done = run.done or now end
	end
	Events.OnTick.Add(T.grabWatch)
end

function T.grabBulkCheck(n)
	local run = T.grabRuns and T.grabRuns[n]
	local inv = getPlayer():getInventory()
	if T.grabWatch then Events.OnTick.Remove(T.grabWatch); T.grabWatch = nil end
	if not run then check("grab run n=" .. n, false) return end
	local got = 0
	for _, item in ipairs(run.items) do if item:getContainer() == inv then got = got + 1 end end
	check("15 floor items picked up n=" .. n, #run.items == 15 and got == 15, got .. "/" .. #run.items)
	check("grab finished n=" .. n, run.done ~= nil)
	if run.done then
		run.ms = run.done - run.start
		run.spread = run.done - run.first
		log("15 grabs took ms n=" .. n, run.ms, "first to last pickup ms", run.spread)
	end
	-- clean up so the next run starts with the same inventory weight
	for _, item in ipairs(run.items) do
		if item:getContainer() then item:getContainer():Remove(item) end
	end
end

function T.grabBulkCompare()
	local seq, bulk, plank = T.grabRuns and T.grabRuns[1], T.grabRuns and T.grabRuns[20], T.runs[1]
	if seq and bulk and seq.ms and bulk.ms and plank and plank.ms and plank.maxTime then
		local msPerTick = plank.ms / plank.maxTime
		local ideal = bulk.exact * msPerTick
		local ratio = bulk.ms / ideal
		log("grab ms per tick", msPerTick, "ideal ms", ideal, "batch ms", bulk.ms, "item by item ms", seq.ms)
		check("grab batch takes the exact sum of item times (0.9-1.1x ideal)", ratio >= 0.9 and ratio <= 1.1, ratio)
		check("grab batch: items arrive together", bulk.spread <= 100, bulk.spread)
		check("grab item by item: items arrive spread out", seq.spread > 200, seq.spread)
	else
		check("plank and both grab runs finished", false)
	end
	setMultiplier(20)
	setBulk(20)
end

-- inventory transfers of 15 different types (main inventory -> school bag), item by item vs one batch
function T.mixStart(n)
	local player, inv, bagInv = setup()
	setMultiplier(2)
	setBulk(n)
	-- empty the bag of earlier runs' apples so both runs see the same bag weight
	for i = 1, 15 do
		local a = T.apples and T.apples[i]
		if a and a:getContainer() then a:getContainer():Remove(a) end
	end
	T.mixRuns = T.mixRuns or {}
	local run = { n = n, exact = 0, items = {} }
	T.mixRuns[n] = run
	for _, t in ipairs(GRAB_TYPES) do
		local item = inv:AddItem("Base." .. t)
		if item then run.items[#run.items + 1] = item end
	end
	local exactTime = ActionSpeedMultiplierLua.exactTransferTime
	run.start = getTimestampMs()
	for _, item in ipairs(run.items) do
		ISTimedActionQueue.add(ISInventoryTransferAction:new(player, item, inv, bagInv))
		run.exact = run.exact + (exactTime[item] or 0)
	end
	log("mix queued n=" .. n, "items", #run.items, "sum of exact times", run.exact)
	T.mixWatch = function()
		local now = getTimestampMs()
		local got = 0
		for _, item in ipairs(run.items) do if item:getContainer() == bagInv then got = got + 1 end end
		if got > 0 then run.first = run.first or now end
		if got == #run.items then run.done = run.done or now end
	end
	Events.OnTick.Add(T.mixWatch)
end

function T.mixCheck(n)
	local run = T.mixRuns and T.mixRuns[n]
	local _, _, bagInv = setup()
	if T.mixWatch then Events.OnTick.Remove(T.mixWatch); T.mixWatch = nil end
	if not run then check("mix run n=" .. n, false) return end
	local got = 0
	for _, item in ipairs(run.items) do if item:getContainer() == bagInv then got = got + 1 end end
	check("15 different items moved n=" .. n, #run.items == 15 and got == 15, got .. "/" .. #run.items)
	check("mix finished n=" .. n, run.done ~= nil)
	if run.done then
		run.ms = run.done - run.start
		run.spread = run.done - run.first
		log("15 different items took ms n=" .. n, run.ms, "first to last arrival ms", run.spread)
	end
	for _, item in ipairs(run.items) do
		if item:getContainer() then item:getContainer():Remove(item) end
	end
end

function T.mixCompare()
	local seq, bulk, plank = T.mixRuns and T.mixRuns[1], T.mixRuns and T.mixRuns[20], T.runs[1]
	if seq and bulk and seq.ms and bulk.ms and plank and plank.ms and plank.maxTime then
		local msPerTick = plank.ms / plank.maxTime
		local ideal = bulk.exact * msPerTick
		local ratio = bulk.ms / ideal
		log("mix ms per tick", msPerTick, "ideal ms", ideal, "batch ms", bulk.ms, "item by item ms", seq.ms)
		check("mix batch takes the exact sum of item times (0.9-1.1x ideal)", ratio >= 0.9 and ratio <= 1.1, ratio)
		check("mix batch: items arrive together", bulk.spread <= 100, bulk.spread)
		check("mix item by item: items arrive spread out", seq.spread > 200, seq.spread)
	else
		check("plank and both mix runs finished", false)
	end
	setMultiplier(20)
	setBulk(20)
end

-- Multiplayer batches, checked in single player by calling the pieces directly (no server here):
-- foldQueueMP (client side: regroup the -1-timed queue, first batch cut to what fits) and the Java
-- batch sum (server side: a transaction of several items takes their times added up, light bundles once).
local function freshItems(key, fullType, n, container)
	T[key] = T[key] or {}
	for i, it in ipairs(T[key]) do
		if it:getContainer() then it:getContainer():Remove(it) end
		T[key][i] = nil
	end
	for i = 1, n do T[key][i] = container:AddItem(fullType) end
	return T[key]
end

local function clearItems(key)
	for i, it in ipairs(T[key] or {}) do
		if it:getContainer() then it:getContainer():Remove(it) end
	end
	T[key] = {}
end

-- an empty schoolbag of its own, so earlier tests' items don't fill it
local function mpSetup()
	local player, inv = setup()
	if T.mpBag and T.mpBag:getContainer() then T.mpBag:getContainer():Remove(T.mpBag) end
	T.mpBag = inv:AddItem("Base.Bag_Schoolbag")
	return player, inv, T.mpBag:getInventory()
end

local function mpCleanup()
	if T.mpBag and T.mpBag:getContainer() then T.mpBag:getContainer():Remove(T.mpBag) end
	T.mpBag = nil
end

local function mpAction(player, items, src, dest, perEntry)
	local list = {}
	local k = 1
	while k <= #items do
		local e = { items = {}, time = -1, type = items[k]:getFullType() }
		for j = k, math.min(k + (perEntry or 1) - 1, #items) do e.items[#e.items + 1] = items[j] end
		list[#list + 1] = e
		k = k + (perEntry or 1)
	end
	return { queueList = list, character = player, srcContainer = src, destContainer = dest }
end

function T.mpFold()
	local L = ActionSpeedMultiplierLua
	check("foldQueueMP exposed", L ~= nil and L.foldQueueMP ~= nil and L.roomForBatch ~= nil)
	if not (L and L.foldQueueMP) then return end
	local player, inv, bagInv = mpSetup()
	setBulk(20)
	-- 30 apples, one entry each: batches of 20 and 10 (an empty schoolbag holds 20 apples)
	local apples = freshItems("mpApples", "Base.Apple", 30, inv)
	local a = mpAction(player, apples, inv, bagInv)
	check("30 apples folded", L.foldQueueMP(a) == true)
	check("30 apples: 2 batches 20 + 10", #a.queueList == 2 and #a.queueList[1].items == 20 and #a.queueList[2].items == 10,
		#a.queueList .. " " .. #a.queueList[1].items)
	check("batch times stay -1 (server-timed)", a.queueList[1].time == -1 and a.queueList[2].time == -1)
	check("batch type is the mod's", a.queueList[1].type == "ActionSpeedMultiplier.Batch")
	check("order kept", a.queueList[1].items[1] == apples[1] and a.queueList[2].items[10] == apples[30])
	check("second fold: unchanged", L.foldQueueMP(a) == false)
	-- vanilla bundles (one entry, several items) are flattened too
	local b = mpAction(player, apples, inv, bagInv, 15)
	L.foldQueueMP(b)
	check("2 entries of 15 -> 20 + 10", #b.queueList == 2 and #b.queueList[1].items == 20, #b.queueList)
	clearItems("mpApples")
	-- heavy items: the first batch stops where the bag would be full
	local planks = freshItems("mpPlanks", "Base.Plank", 12, inv)
	local c = mpAction(player, planks, inv, bagInv)
	L.foldQueueMP(c)
	local first = #c.queueList[1].items
	local w = 0
	for _, it in ipairs(c.queueList[1].items) do w = w + it:getUnequippedWeight() end
	local cap = bagInv:getEffectiveCapacity(player)
	local used = bagInv:getCapacityWeight()
	local plankW = planks[1]:getUnequippedWeight()
	log("12 planks into the schoolbag: first batch", first, "weight", w, "bag used", used, "capacity", cap)
	check("first batch fits the bag", first == 1 or used + w <= cap, used + w .. " <= " .. cap)
	check("first batch is as big as fits", first == 12 or used + w + plankW > cap or not bagInv:hasRoomFor(player, w + plankW),
		"first=" .. first)
	check("first batch smaller than 12", first < 12, first)
	local total = 0
	for _, e in ipairs(c.queueList) do total = total + #e.items end
	check("no plank lost", total == 12, total)
	clearItems("mpPlanks")
	-- not the multiplayer form (times not -1), size 1, a single item: left alone
	local d = { queueList = { { items = { "x" }, time = 5, type = "t" }, { items = { "y" }, time = 5, type = "t" } } }
	check("SP-timed entries left alone", L.foldQueueMP(d) == false and #d.queueList == 2)
	setBulk(1)
	local e = mpAction(player, freshItems("mpApples", "Base.Apple", 5, inv), inv, bagInv)
	check("size 1: vanilla", L.foldQueueMP(e) == false and #e.queueList == 5)
	clearItems("mpApples")
	mpCleanup()
	setBulk(20)
end

function T.mpServerTimes()
	if not (ActionSpeedMultiplier and ActionSpeedMultiplier.serverDurationList) then
		check("Java serverDurationList", false)
		return
	end
	local player, inv, bagInv = mpSetup()
	setBulk(20)
	setMultiplier(2)
	local function list(items)
		local l = ArrayList.new()
		for _, it in ipairs(items) do l:add(it) end
		return l
	end
	local planks = freshItems("mpPlanks", "Base.Plank", 5, inv)
	local one = ActionSpeedMultiplier.serverDurationList(player, list({ planks[1] }), inv, bagInv, 1)
	local vmax = ActionSpeedMultiplier.serverDurationList(player, list(planks), inv, bagInv, 1)
	local before = ActionSpeedMultiplier.batched()
	local sum = ActionSpeedMultiplier.serverDurationList(player, list(planks), inv, bagInv, 2)
	local patched = ActionSpeedMultiplier.serverDurationList(player, list(planks), inv, bagInv, 0)
	log("5 planks server ms: one", one, "vanilla (slowest)", vmax, "sum", sum, "patched", patched)
	check("one plank > 0", one > 0, one)
	near("vanilla takes the slowest (= one plank)", vmax, one)
	near("batch sum = 5 planks", sum, 5 * one)
	near("patched = sum / 2", patched, 5 * one / 2)
	check("batch counter ran", ActionSpeedMultiplier.batched() > before)
	-- 25 nails (light, one type): vanilla bundles 20 into one item's time, so 2 items' time
	local nails = freshItems("mpNails", "Base.Nails", 25, inv)
	local nail = ActionSpeedMultiplier.serverDurationList(player, list({ nails[1] }), inv, bagInv, 1)
	local nsum = ActionSpeedMultiplier.serverDurationList(player, list(nails), inv, bagInv, 2)
	log("25 nails server ms: one", nail, "sum", nsum, "nail weight", nails[1]:getWeight())
	near("25 nails = 2 bundles", nsum, 2 * nail)
	-- mixed: 5 planks + 20 nails = 5 planks + 1 nail
	local mixed = {}
	for _, p in ipairs(planks) do mixed[#mixed + 1] = p end
	for i = 1, 20 do mixed[#mixed + 1] = nails[i] end
	local msum = ActionSpeedMultiplier.serverDurationList(player, list(mixed), inv, bagInv, 2)
	near("5 planks + 20 nails = 5 planks + 1 nail", msum, 5 * one + nail)
	-- size 1: vanilla rule (slowest), divided
	setBulk(1)
	local off = ActionSpeedMultiplier.serverDurationList(player, list(planks), inv, bagInv, 0)
	near("size 1: slowest / 2 (vanilla rule)", off, one / 2)
	setBulk(20)
	-- the single-item path is unchanged
	near("single item patched = one / 2", ActionSpeedMultiplier.serverDurationList(player, list({ planks[1] }), inv, bagInv, 0), one / 2)
	clearItems("mpPlanks")
	clearItems("mpNails")
	mpCleanup()
	setMultiplier(20)
end

-- Grabbing eggs from a hutch (ISHutchGrabEgg, 1.2.1). A real hen hutch is built 3 squares from the player
-- (IsoHutch.new with HutchDefinitions "hutchhen", as ISHutch:create) and its first nest box filled with
-- eggs; if that fails, a stub nest box (a Lua table) and the floor object stand in, and the run says so.
-- Server path (no server here): adjustMaxTime(-1) must scale timePerEgg, and serverStart's
-- emulateAnimEvent period (captured by swapping the global for the call) must be 800 ms / ActionSpeed.
local EGG = "Base.Egg"

local function protect(on)
	local p = getPlayer()
	p:setGodMod(on)
	p:setInvisible(on)
	p:setZombiesDontAttack(on)
	if p.setGhostMode then p:setGhostMode(on) end
end

local function invEggs()
	return getPlayer():getInventory():getItemsFromFullType(EGG):size()
end

local function clearInvEggs()
	local inv = getPlayer():getInventory()
	local list = inv:getItemsFromFullType(EGG)
	for i = list:size() - 1, 0, -1 do inv:Remove(list:get(i)) end
end

local function stubNest()
	local nest = { eggs = {} }
	function nest:getEggsNb() return #self.eggs end
	function nest:removeEgg(i) return table.remove(self.eggs, (i or 0) + 1) end
	function nest:addEgg(e) self.eggs[#self.eggs + 1] = e end
	return nest
end

local function eggHutch()
	if T.hutch and T.nest then return T.hutch, T.nest end
	local player = getPlayer()
	local ok, hutch = pcall(function()
		local sq = getCell():getGridSquare(math.floor(player:getX()) + 3, math.floor(player:getY()) + 3, math.floor(player:getZ()))
		if not sq or not HutchDefinitions or not HutchDefinitions.hutchs["hutchhen"] then return nil end
		local def = HutchDefinitions.hutchs["hutchhen"]
		return IsoHutch.new(sq, false, def.baseSprite, def, nil)
	end)
	local nest = ok and hutch and hutch:getNestBox(0)
	if nest then
		T.realHutch = true
		T.hutch, T.nest = hutch, nest
	else
		log("real hutch not built (" .. tostring(hutch) .. "), using a stub nest box")
		T.realHutch = false
		T.hutch, T.nest = player:getCurrentSquare():getFloor(), stubNest()
	end
	return T.hutch, T.nest
end

local function fillNest(nest, n)
	while nest:getEggsNb() > 0 do nest:removeEgg(0) end
	for _ = 1, n do nest:addEgg(instanceItem(EGG)) end
	return nest:getEggsNb()
end

-- the period serverStart would give emulateAnimEvent (ms), or nil
local function serverPeriod(a)
	local saved = emulateAnimEvent
	local period
	emulateAnimEvent = function(_, p) period = p end
	local ok, err = pcall(a.serverStart, a)
	emulateAnimEvent = saved
	if not ok then log("serverStart failed", err) end
	return period
end

function T.eggUnit()
	protect(true)
	local player = getPlayer()
	check("ISHutchGrabEgg wrapped", ISHutchGrabEgg ~= nil and ISHutchGrabEgg._ASM_wrapped == true)
	check("timed actions not instant (debug cheat off)", not player:isTimedActionInstant())
	local hutch, nest = eggHutch()
	check("real hen hutch built", T.realHutch == true, tostring(hutch))
	check("nest box filled with 10 eggs", fillNest(nest, 10) == 10, nest:getEggsNb())

	-- single player: maxTime and the egg clock divided together
	setActionMultiplier(1)
	local v = ISHutchGrabEgg:new(player, nest, hutch)
	near("vanilla getDuration = 10 eggs * 40 + 5", v.maxTime, 405)
	local vt = v:adjustMaxTime(v.maxTime)
	near("m=1: timePerEgg stays 40", v.timePerEgg, 40)
	setActionMultiplier(20)
	local a = ISHutchGrabEgg:new(player, nest, hutch)
	local at = a:adjustMaxTime(a.maxTime)
	log("egg action time m=1", vt, "m=20", at)
	near("m=20: time / 20", at, vt / 20)
	near("m=20: timePerEgg 2", a.timePerEgg, 2)

	-- server: getDuration returns -1, NetTimedAction.start calls adjustMaxTime(-1), then serverStart
	setActionMultiplier(1)
	local s1 = ISHutchGrabEgg:new(player, nest, hutch)
	check("m=1: adjustMaxTime(-1) stays -1", s1:adjustMaxTime(-1) == -1)
	near("m=1: server period 800 ms (vanilla)", serverPeriod(s1), 800)
	setActionMultiplier(20)
	local s20 = ISHutchGrabEgg:new(player, nest, hutch)
	check("m=20: adjustMaxTime(-1) stays -1", s20:adjustMaxTime(-1) == -1)
	near("m=20: timePerEgg 2 after adjustMaxTime(-1)", s20.timePerEgg, 2)
	near("m=20: server period 40 ms", serverPeriod(s20), 40)
	s20:adjustMaxTime(-1)
	near("m=20: server clock divided only once", s20.timePerEgg, 2)

	-- other -1 actions with their own clock (ISMilkAnimal everywhere, watering on servers)
	local milk = TestAction:new(player, -1)
	milk.timePerLiter = 40
	check("-1 action keeps -1", milk:adjustMaxTime(-1) == -1)
	near("-1 action: timePerLiter divided", milk.timePerLiter, 2)
	local zero = TestAction:new(player, 0)
	zero.timePerLiter = 40
	zero:adjustMaxTime(0)
	near("0 (instant) action: clock untouched", zero.timePerLiter, 40)
	fillNest(nest, 0)
	clearInvEggs()
end

-- a real queued egg grab: n eggs at ActionSpeed m, timed until the last egg is in the inventory
function T.eggStart(m, n)
	protect(true)
	local player = getPlayer()
	local hutch, nest = eggHutch()
	clearInvEggs()
	fillNest(nest, n)
	setActionMultiplier(m)
	T.eggRuns = T.eggRuns or {}
	local run = { m = m, n = n, start = getTimestampMs() }
	T.eggRuns[m] = run
	local a = ISHutchGrabEgg:new(player, nest, hutch)
	run.action = a
	ISTimedActionQueue.add(a)
	T.eggWatch = function()
		protect(true)
		if not run.done and invEggs() >= n then run.done = getTimestampMs() end
		local q = ISTimedActionQueue.getTimedActionQueue(player)
		if not run.ended and (not q or not q.queue or #q.queue == 0) then run.ended = getTimestampMs() end
	end
	log("egg grab queued m=" .. m, "eggs", n, "maxTime", a.maxTime, "real hutch", tostring(T.realHutch))
end

function T.eggCheck(m)
	T.eggWatch = nil
	local run = T.eggRuns and T.eggRuns[m]
	if not run then check("egg run m=" .. m .. " started", false) return end
	local _, nest = eggHutch()
	check("egg box empty m=" .. m, nest:getEggsNb() == 0, nest:getEggsNb())
	check("all " .. run.n .. " eggs in the inventory m=" .. m, invEggs() == run.n, invEggs())
	check("egg action ended m=" .. m, run.ended ~= nil)
	if run.done then
		run.ms = run.done - run.start
		log("egg grab took ms m=" .. m, run.ms, "eggs", run.n, "action ended after ms", run.ended and (run.ended - run.start))
	end
	fillNest(nest, 0)
	clearInvEggs()
	setActionMultiplier(20)
end

function T.eggCompare()
	local slow, fast = T.eggRuns and T.eggRuns[1], T.eggRuns and T.eggRuns[20]
	if slow and fast and slow.ms and fast.ms then
		local ratio = slow.ms / math.max(1, fast.ms)
		log("egg real time ratio m=1 / m=20 (5 eggs each)", ratio)
		check("eggs m=20 at least 8x faster in real time", ratio >= 8, ratio)
	else
		check("both egg runs finished", false)
	end
end

function T.eggCleanup()
	T.eggWatch = nil
	if T.hutch and T.realHutch then
		local ok, err = pcall(function() T.hutch:removeHutch() end)
		check("test hutch removed", ok, tostring(err))
	end
	T.hutch, T.nest, T.realHutch = nil, nil, nil
	clearInvEggs()
	setActionMultiplier(20)
	protect(false)
	check("protection off", not getPlayer():isGodMod())
end

-- one OnTick handler at file level (a hot reload replaces it); the state lives in T.eggWatch
Events.OnTick.Add(function()
	if T.eggWatch then
		local ok, err = pcall(T.eggWatch)
		if not ok then log("egg watch failed", err); T.eggWatch = nil end
	end
end)

function T.summary()
	log("summary pass", T.pass, "fail", T.fail)
end
