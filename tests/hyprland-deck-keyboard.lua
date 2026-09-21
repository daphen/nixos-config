local config = assert(arg[1], "pass the production hyprland.lua path")
local bindings, calls, layers = {}, {}, {}
local noop = setmetatable({}, { __index = function(self) return self end, __call = function() return {} end })
package.loaded["canvas-state"] = { read = function() return {} end }
hl = setmetatable({
    dsp = setmetatable({ exec_cmd = function(command) return command end }, getmetatable(noop)),
    bind = function(key, action) bindings[key] = action; return noop end,
    dispatch = function(command) calls[#calls + 1] = command end,
    get_layers = function(query)
        assert(query == nil or query.namespace == "wvkbd")
        return layers
    end,
}, { __index = function() return noop end })
assert(loadfile(config))()
if os.getenv("HYPR_CANVAS_PROFILE") ~= "deck" then
    assert(bindings.Escape == nil and bindings.F22 == nil, "workstation bindings must remain untouched")
    assert(bindings["ALT + escape"]:match("session%-exit$"), "workstation logout shortcut must remain available")
    print("PASS workstation keyboard and logout bindings unchanged")
    return
end
assert(bindings["ALT + escape"] == nil, "Deck modifier plus B must never log out")
local escape = assert(bindings.Escape)
assert(escape().pass_event, "hidden keyboard must forward Escape")
assert(#calls == 0)
layers = { { mapped = false } }
assert(escape().pass_event, "unmapped keyboard must forward Escape")
assert(#calls == 0)
layers = { { mapped = true } }
assert(escape() == nil, "visible keyboard must consume Escape")
assert(#calls == 1 and calls[1] == "pkill -USR1 -x wvkbd-mobintl")
layers = {}
assert(escape().pass_event, "Escape must pass through again after hiding")
assert(#calls == 1)
print("PASS Deck B/Escape hides only a mapped keyboard; otherwise passes through")
assert(bindings.F22 == "deck-osk-toggle", "Deck X must use the deployed global Steam keyboard toggle")
print("PASS Deck X uses the global keyboard toggle")
