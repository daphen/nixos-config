local config = assert(arg[1], "pass the canvas config path")
package.path = config:match("^(.*)/") .. "/?.lua;" .. package.path
local path = assert(os.getenv("XDG_STATE_HOME")) .. "/hypr-canvas/layout.lua"
local world, provider, events, timers = {}, nil, {}, {}
local noop = function() return {} end
local dispatchers = {}
setmetatable(dispatchers, {__index = function() return dispatchers end, __call = noop})
hl = setmetatable({
    layout = {register = function(_, value) provider = value end},
    dsp = dispatchers,
    get_windows = function() return world end,
    on = function(name, fn)
        local previous = events[name]
        events[name] = function(...)
            if previous then previous(...) end
            fn(...)
        end
    end,
    bind = function() return {set_enabled = function() end} end,
    timer = function(fn) timers[#timers + 1] = fn end,
}, {__index = function() return noop end})
local function load_config()
    package.loaded["canvas-state"] = nil
    dofile(config)
end
local function contents()
    local file = assert(io.open(path))
    local text = file:read("*a")
    file:close()
    return text
end
local function saved() return assert(load(contents(), "checkpoint", "t", {}))().workspaces end
local function contains(state, id)
    for _, row in ipairs(state.rows) do
        for _, item in ipairs(row) do if item == tostring(id) then return true end end
    end
    return false
end
local function target(id, workspace, row)
    local window = {
        stable_id = id, address = id, class = "test", mapped = true, floating = false,
        title = row and ("Canvas " .. row .. ".1") or "Normal app",
        workspace = {addressable_name = workspace, tiled_layout = "lua:canvas"},
    }
    world[#world + 1] = window
    return {window = window, index = id, set_box = function(self, box) self.box = box end}
end
local a = {area = {x=0, y=0, w=1600, h=1000}, targets = {}}
local b = {area = {x=1600, y=0, w=1600, h=1000}, targets = {}}
for i=1,3 do a.targets[i] = target(i, "1", i) end
load_config()
provider.recalculate(a)
assert(a.targets[1].box.y ~= a.targets[2].box.y and a.targets[2].box.y ~= a.targets[3].box.y)
for _, item in ipairs(a.targets) do item.window.title = "Normal app" end
local original = contents()
provider.recalculate({area=a.area, targets={}})
provider.recalculate(a)
assert(contents() == original, "empty workspace must not erase rows")
print("PASS empty callbacks preserve the checkpoint")

b.targets[1] = target(4, "2", 1)
provider.recalculate(b)
provider.recalculate(a)
assert(contains(saved()["1"], 1) and contains(saved()["2"], 4))
assert(a.targets[1].box.y ~= a.targets[2].box.y)
print("PASS separate workspace layouts")

a.targets[1].window.active = true
provider.layout_msg(a, "move j")
provider.recalculate(a)
local moved = saved()["1"]
assert(moved.rows[2][1] == "1" or moved.rows[2][2] == "1")
local width = moved.sizes["1"].w
provider.layout_msg(a, "resize l")
provider.recalculate(a)
assert(saved()["1"].sizes["1"].w > width)
print("PASS moves and resizes save")

local before = contents()
local boxes = {}
for i, item in ipairs(a.targets) do boxes[i] = item.box end
load_config()
provider.recalculate({area=a.area, targets={a.targets[1]}})
assert(contents() == before, "partial reattachment must keep absent-but-live windows")
provider.recalculate(b)
provider.recalculate(a)
assert(contents() == before)
for i, item in ipairs(a.targets) do
    for _, field in ipairs({"x", "y", "w", "h"}) do assert(item.box[field] == boxes[i][field], "reload changed geometry") end
end
print("PASS reload and partial reattachment restore exact geometry")

a.targets[#a.targets + 1] = target(5, "1")
provider.recalculate(a)
assert(contains(saved()["1"], 5))
print("PASS additions save")

local closed = table.remove(a.targets, 2).window
events["window.close"](closed)
assert(not contains(saved()["1"], closed.stable_id), "inactive close must save immediately")
closed.mapped = false
provider.recalculate(a)
assert(not contains(saved()["1"], closed.stable_id))
print("PASS inactive closes save")

local only = b.targets[1].window
events["window.close"](only)
only.mapped = false
b.targets = {}
provider.recalculate(b)
assert(not contains(saved()["2"], 4) and contains(saved()["1"], 1))
print("PASS final close and empty workspace keep other layouts")

local migrated = table.remove(a.targets, #a.targets)
migrated.window.workspace = {addressable_name="2", tiled_layout="lua:canvas"}
b.targets = {migrated}
provider.recalculate(b)
provider.recalculate(a)
assert(not contains(saved()["1"], 5) and contains(saved()["2"], 5))
print("PASS workspace moves leave no stale membership")

local active = table.remove(a.targets, 1).window
events["window.close"](active)
active.mapped = false
provider.recalculate(a)
provider.recalculate(b)
for _, timer in ipairs(timers) do timer() end
assert(not contains(saved()["1"], active.stable_id))
print("PASS active close retains delayed focus behavior across workspace callbacks")

local last_good = contents()
os.execute("chmod 500 '" .. path:match("^(.*)/") .. "'")
b.targets[1].window.active = true
provider.layout_msg(b, "resize l")
assert(contents() == last_good, "failed save must preserve last checkpoint")
os.execute("chmod 700 '" .. path:match("^(.*)/") .. "'")
provider.recalculate(b)
assert(contents() ~= last_good)
print("PASS failed writes keep the previous checkpoint")

local file = assert(io.open(path, "w")); file:write("not a valid checkpoint"); file:close()
load_config()
provider.recalculate(b)
assert(contains(saved()["2"], 5))
print("PASS malformed checkpoint does not break layout")

file = assert(io.open(path, "w"))
file:write('return {instance="different-compositor",workspaces={bogus={}}}')
file:close()
load_config()
provider.recalculate(b)
assert(not saved().bogus and contains(saved()["2"], 5))
print("PASS different compositor identity cannot restore reused window IDs")
