-- Single-player in-game test, test environment only: pzt installs this file into the test copy
-- of the mod (TEST_FILES in pzt.conf). Results: "[TransferSpeedMultiplierTest]" lines
-- (failures also "[PZTest] FAIL"). Never error(): under -debug it opens the debugger.

local function log(...)
	local parts = {}
	for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
	print("[TransferSpeedMultiplierTest] " .. table.concat(parts, " "))
end

local T = { pass = 0, fail = 0, runs = {} }
TransferSpeedMultiplierTest = T

local function check(label, ok, extra)
	if ok then T.pass = T.pass + 1 else T.fail = T.fail + 1 end
	log(ok and "PASS" or "FAIL", label, extra or "")
	if not ok and PZTest then PZTest.fail("TransferSpeedMultiplierTest " .. label .. " " .. tostring(extra or "")) end
end

local function near(label, got, want, tol)
	tol = tol or 0.01
	check(label, got ~= nil and want ~= nil and math.abs(got - want) <= tol * math.max(1, math.abs(want)),
		"got=" .. tostring(got) .. " want=" .. tostring(want))
end

-- both sides: Lua reads SandboxVars, Java reads SandboxOptions.instance
local function setMultiplier(m)
	local opt = getSandboxOptions():getOptionByName("TransferSpeedMultiplier.Multiplier")
	if opt then opt:setValue(m) end
	SandboxVars.TransferSpeedMultiplier = SandboxVars.TransferSpeedMultiplier or {}
	SandboxVars.TransferSpeedMultiplier.Multiplier = m
end

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
	check("Java API exposed", TransferSpeedMultiplier ~= nil)
	check("sandbox option exists", getSandboxOptions():getOptionByName("TransferSpeedMultiplier.Multiplier") ~= nil)
	if TransferSpeedMultiplier then
		near("default multiplier 20", TransferSpeedMultiplier.multiplier(), 20.0)
	end
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
	if not TransferSpeedMultiplier then check("Java API for serverTimes", false) return end
	local player, inv, bagInv = setup()
	local before = TransferSpeedMultiplier.applied()
	for _, m in ipairs({ 1, 2, 4, 0.5 }) do
		setMultiplier(m)
		local v = TransferSpeedMultiplier.serverDuration(player, T.plank, inv, bagInv, true)
		local p = TransferSpeedMultiplier.serverDuration(player, T.plank, inv, bagInv, false)
		log("server duration ms m=" .. m, "vanilla", v, "patched", p)
		check("server vanilla > 0 m=" .. m, v > 0, v)
		near("server patched = vanilla / m, m=" .. m, p, v / m)
	end
	check("patch ran", TransferSpeedMultiplier.applied() > before, TransferSpeedMultiplier.applied() - before)
	-- the server formula is Lua's maxTime * 20 ms; matches when the containers resolve in single player
	setMultiplier(1)
	local v = TransferSpeedMultiplier.serverDuration(player, T.plank, inv, bagInv, true)
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

function T.summary()
	log("summary pass", T.pass, "fail", T.fail)
end
