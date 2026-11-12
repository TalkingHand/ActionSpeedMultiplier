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

function T.summary()
	log("summary pass", T.pass, "fail", T.fail)
end
