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

function T.summary()
	log("summary pass", T.pass, "fail", T.fail)
end
