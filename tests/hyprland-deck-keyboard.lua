local config = assert(arg[1], "pass the production hyprland.lua path")
local bindings, calls, layers, keyHandlers = {}, {}, {}, {}
local activeWindow = { class = "org.quickshell", title = "cockpit-qs · personal · personal" }
local noop = setmetatable({}, { __index = function(self) return self end, __call = function() return {} end })
package.loaded["canvas-state"] = { read = function() return {} end }
hl = setmetatable({
    dsp = setmetatable({ exec_cmd = function(command) return command end,
                         send_key_state = function(data) return data end }, getmetatable(noop)),
    bind = function(key, action, options)
        if not options or not options.release then bindings[key] = action end
        return noop
    end,
    on = function(event, callback)
        if event == "input.keyboard.key" then keyHandlers[#keyHandlers + 1] = callback end
        return noop
    end,
    dispatch = function(command) calls[#calls + 1] = command end,
    get_active_window = function() return activeWindow end,
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
assert(bindings.Return().pass_event, "A without RT must reach the focused window")
assert(bindings.F22() == nil and calls[#calls] == "deck-osk-toggle", "X without RT must open the keyboard")
print("PASS Deck X uses the global keyboard toggle")
calls = {}
assert(bindings.F7() == nil, "RT must keep its compositor state")
for _, pair in ipairs({ { "Return", 1 }, { "Escape", 2 }, { "F22", 3 }, { "F21", 4 } }) do
    assert(bindings[pair[1]]() == nil, "RT + " .. pair[1] .. " leaked its normal action")
    assert(#calls == 2 and calls[1].key == tostring(pair[2]) and calls[1].state == "down"
           and calls[2].key == tostring(pair[2]) and calls[2].state == "up", "wrong Deck answer key")
    calls = {}
end
for _, handler in ipairs(keyHandlers) do handler(73, nil, 0) end
assert(bindings.Return().pass_event and bindings.Escape().pass_event, "releasing RT must restore A and B")
assert(bindings.F22() == nil and calls[#calls] == "deck-osk-toggle", "releasing RT must restore X")
activeWindow = { class = "browser-personal", title = "Browser" }
calls = {}
bindings.F7()
assert(bindings.Return() == nil and #calls == 2 and calls[1].key == "f" and calls[2].key == "f",
       "browser RT + A must keep its fullscreen shortcut")
assert(bindings.Escape().pass_event, "browser RT + B must pass through")
assert(bindings.F22() == nil and calls[#calls] == "deck-osk-toggle", "RT + X must keep keyboard in other apps")
print("PASS Deck Cockpit answer keys and browser fullscreen shortcut; normal controls survive")
