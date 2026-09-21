local now, timers, calls, gesture = 0, {}, {}, nil
local noop = setmetatable({}, { __index = function(self) return self end, __call = function() end })
hl = setmetatable({
    dsp = setmetatable({ layout = function(message) return message end }, getmetatable(noop)),
    gesture = function(spec)
        assert(spec.fingers == 3 and spec.direction == "swipe")
        gesture = spec.action
    end,
    dispatch = function(message) calls[#calls + 1] = message end,
    timer = function(callback, options)
        assert(options.type == "oneshot")
        local timer = { due = now + options.timeout, enabled = true, callback = callback }
        function timer:set_enabled(enabled) self.enabled = enabled end
        timers[#timers + 1] = timer
        return timer
    end,
}, { __index = function() return noop end })
local config = assert(arg[1], "pass the production hyprland.lua path")
package.path = config:match("^(.*)/") .. "/?.lua;" .. package.path
assert(loadfile(config))()
assert(gesture)

local function advance(ms)
    now = now + ms
    for _, timer in ipairs(timers) do
        if timer.enabled and timer.due <= now then
            timer.enabled = false
            timer.callback()
        end
    end
end
local function expect(...)
    local wanted = { ... }
    assert(#calls == #wanted, "unexpected dispatch count: " .. table.concat(calls, ", "))
    for i, value in ipairs(wanted) do assert(calls[i] == value, tostring(calls[i])) end
    calls = {}
end

gesture.start()
gesture.update({ delta = { x = 2, y = -3 } })
advance(349)
expect("pan-begin", "pan 16.000000 -24.000000")
advance(1)
expect("pan-overview")
gesture.finish({ cancelled = false })
advance(500)
expect("pan-end")

for _, cancelled in ipairs({ false, true }) do
    gesture.start()
    advance(100)
    gesture.finish({ cancelled = cancelled })
    advance(300)
    expect("pan-begin", "pan-end")
end

gesture.start()
advance(200)
gesture.finish()
gesture.start()
advance(150)
expect("pan-begin", "pan-end", "pan-begin")
advance(200)
expect("pan-overview")
gesture.finish({ cancelled = true })
expect("pan-end")
print("PASS: hold-to-overview, immediate pan, early/cancelled release, consecutive gestures")
