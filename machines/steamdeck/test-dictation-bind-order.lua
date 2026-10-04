local config = assert(arg[1])
local bindings, commands, dispatches, keyboard_key = {}, {}, {}, nil
local noop = setmetatable({}, { __index = function(self) return self end, __call = function() return {} end })
package.loaded["canvas-state"] = { read = function() return {} end }
hl = setmetatable({
    dsp = setmetatable({ exec_cmd = function(command) return command end }, getmetatable(noop)),
    bind = function(key, action, options)
        bindings[key] = bindings[key] or {}
        bindings[key][#bindings[key] + 1] = { action = action, options = options or {} }
        return noop
    end,
    exec_cmd = function(command) commands[#commands + 1] = command end,
    dispatch = function(action) dispatches[#dispatches + 1] = action end,
    on = function(event, callback)
        if event == "input.keyboard.key" then keyboard_key = callback end
        return noop
    end,
}, { __index = function() return noop end })
assert(loadfile(config))()
local f9 = assert(bindings.F9)
local chord = assert(bindings["SUPER + F9"])
local meta = assert(bindings["code:133"])
local super = assert(bindings.Super_L)
assert(type(keyboard_key) == "function")
assert(#f9 == 1 and type(f9[1].action) == "function" and not f9[1].options.release)
assert(#chord == 1 and type(chord[1].action) == "function")
assert(#meta == 1 and meta[1].options.ignore_mods and not meta[1].options.locked)
assert(#super == 1 and super[1].options.release and super[1].options.ignore_mods)
local function expect(index, suffix, message)
    assert(commands[index] and commands[index]:match(suffix .. "$"), message)
end
local function press_super()
    keyboard_key(133, 0, 1)
    meta[1].action()
end
local function release_super()
    keyboard_key(133, 0, 0)
    super[1].action()
end
local function release_f9() keyboard_key(75, 0, 0) end
local function reset() commands = {} end

f9[1].action()
assert(#commands == 0, "F9-first press must remain consumed")
press_super()
expect(1, "PttDown", "F9-first then LT must start once")
release_f9()
expect(2, "PttUp", "F9-first sequence must stop when F9 releases")
release_super()
assert(#commands == 2, "second trigger release must not duplicate PttUp")

reset()
press_super()
chord[1].action()
chord[1].action()
assert(#commands == 1, "LT-first chord and repeats must start once")
expect(1, "PttDown", "LT-first then F9 must start")
release_super()
expect(2, "PttUp", "LT-first sequence must stop when LT releases")
release_f9()
assert(#commands == 2, "second trigger release must not duplicate PttUp")

reset()
f9[1].action()
press_super()
release_super()
expect(2, "PttUp", "F9-first sequence must also stop when LT releases")
release_f9()
assert(#commands == 2, "F9 release after LT must not duplicate PttUp")

reset()
press_super()
chord[1].action()
release_f9()
expect(2, "PttUp", "LT-first sequence must also stop when F9 releases")
release_super()
assert(#commands == 2, "LT release after F9 must not duplicate PttUp")

reset()
press_super()
chord[1].action()
release_super()
press_super()
expect(3, "PttDown", "repressing LT while F9 remains held must start again")
release_f9()
release_super()
expect(4, "PttUp", "restarted chord must stop on F9 release")
assert(#commands == 4, "restarted chord emitted extra commands")
assert(#dispatches >= 6, "Super_L release must retain the pan-end binding")
print("PASS both press orders, both release orders, and LT repress while F9 remains held")
