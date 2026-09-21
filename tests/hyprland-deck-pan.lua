local config = assert(arg[1], "pass the production hyprland.lua path")
local bindings, calls, timers, gesture = {}, {}, {}, nil
local noop = setmetatable({}, { __index = function(self) return self end, __call = function() return {} end })
package.loaded["canvas-state"] = { read = function() return {} end }
hl = setmetatable({
    dsp = setmetatable({
        layout = function(command) return command end,
        exec_cmd = function(command) return command end,
        window = setmetatable({ close = function() return "close" end }, getmetatable(noop)),
    }, getmetatable(noop)),
    bind = function(key, action, options)
        bindings[key .. ((options and options.release) and ":release" or "")] = action
        return noop
    end,
    dispatch = function(command) calls[#calls + 1] = command end,
    gesture = function(spec) assert(spec.fingers == 3); gesture = spec.action end,
    timer = function(callback)
        local timer = { enabled = true, callback = callback }
        function timer:set_enabled(enabled) self.enabled = enabled end
        timers[#timers + 1] = timer
        return timer
    end,
}, { __index = function() return noop end })
assert(loadfile(config))()
assert(gesture)
local delta = { delta = { x = 0.125, y = -0.25 } }
if os.getenv("HYPR_CANVAS_PROFILE") ~= "deck" then
    assert(bindings.F17 == nil)
    gesture.start(); gesture.update(delta); gesture.finish()
    assert(table.concat(calls, "|") == "pan-begin|pan 1.000000 -2.000000|pan-end")
    assert(not timers[1].enabled)
    print("PASS laptop swipe still finishes when fingers lift")
    return
end
assert(bindings.F20 == "close")
assert(bindings["Super_L"] == nil and bindings["SUPER + F17"] == nil)
gesture.start(); gesture.update(delta); gesture.finish()
assert(#calls == 0 and #timers == 0, "swipe callbacks require LT")
bindings.F17()
assert(#calls == 0, "LT alone must not start canvas panning during right-pad scroll")
gesture.start(); gesture.update(delta)
assert(calls[1] == "pan-begin" and calls[2] == "pan 1.000000 -2.000000")
gesture.finish()
assert(#calls == 2 and timers[1].enabled, "thumb lift must not finish or cancel overview")
gesture.start(); gesture.update(delta); gesture.finish()
assert(#timers == 1, "regrip must not leave multiple overview timers")
bindings["F17:release"]()
assert(calls[#calls] == "pan-end" and not timers[1].enabled)
local finished = #calls
gesture.start(); gesture.update(delta); gesture.finish()
assert(#calls == finished, "queued swipe callbacks after LT release must not reopen overview")
bindings.F17(); gesture.start()
assert(#timers == 2)
timers[2].callback()
assert(calls[#calls] == "pan-overview")
gesture.finish()
assert(calls[#calls] == "pan-overview")
bindings["F17:release"]()
assert(calls[#calls] == "pan-end", "LT release must commit after zooming out")
print("PASS Deck fractional pan, regrip, LT-release commit, and late-event suppression")
