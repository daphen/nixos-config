local bindings, calls, events, options, rules, right_bindings = {}, {}, {}, {}, {}, {}
local function right_stick(repeat_event)
    for _, bind in ipairs(right_bindings) do
        if not repeat_event or (bind.options and bind.options.repeating) then bind.action() end
    end
end
local noop = setmetatable({}, { __index = function(self) return self end, __call = function() return {} end })
package.loaded['canvas-state'] = { read = function() return {} end }
hl = setmetatable({
    dsp = setmetatable({ exec_cmd = function(s) return s end, layout = function(s) return 'layout:' .. s end,
        window = setmetatable({ close = function() return 'window.close' end }, getmetatable(noop)) }, getmetatable(noop)),
    bind = function(key, action, opts)
        bindings[key] = action; options[key] = opts
        if key == 'SUPER + F4' then right_bindings[#right_bindings + 1] = { action = action, options = opts } end
        return noop
    end,
    on = function(event, action) events[event] = action end,
    window_rule = function(rule) rules[rule.name] = rule end,
    dispatch = function(s) calls[#calls + 1] = s end,
    exec_cmd = function(s) calls[#calls + 1] = s end,
    get_layers = function() return {} end,
    get_active_window = function() return { class = 'browser-personal' } end,
    timer = function() return noop end,
}, { __index = function() return noop end })
assert(loadfile(assert(arg[1])))()
assert(rules.mail == nil, 'Deck mail must use normal canvas tiling')
assert(rules['file-chooser'].float and rules['slqs-upload'].float, 'dialogs must remain floating')
assert(rules['deck-radial-overlay'].float, 'radial overlay must remain floating')
calls = {}
for index, direction in ipairs({'h', 'j', 'k', 'l'}) do
    local key = 'F' .. (12 + index)
    assert(bindings[key], key .. ' missing')()
    assert(calls[#calls] == 'layout:focus ' .. direction, key .. ' focus changed')
    assert(bindings['SHIFT + ' .. key] == 'layout:move ' .. direction)
    assert(bindings['CTRL + ' .. key] == 'layout:resize ' .. direction)
end
local before = #calls
for _, key in ipairs({'F17', 'F18', 'F19', 'F20'}) do
    assert(bindings[key])()
    assert(options[key].ignore_mods, 'digital stick events must be consumed, not forwarded')
    assert(bindings['SHIFT + ' .. key] == nil and bindings['CTRL + ' .. key] == nil)
end
for _, key in ipairs({'Left', 'Down', 'Up', 'Right'}) do
    assert(bindings[key] == nil, 'normal arrows must pass through')
    assert(bindings['SUPER + ' .. key])()
    assert(options['SUPER + ' .. key].device.list[1] == 'extest-fake-device', 'LT arrow suppression must only affect Steam')
end
assert(#calls == before, 'normal stick or LT Steam arrows must not dispatch window commands')
bindings['SUPER + F19']()
assert(calls[#calls]:match('palette%-toggle 16$'), 'left up must open app menu')
local opened = #calls
for _ = 1, 20 do
    bindings['SUPER + F20']()
    bindings['SUPER + F18']()
end
for keycode = 195, 198 do events['input.keyboard.key'](keycode, 0, 0) end
assert(#calls == opened, 'analog key repeats/releases must not overwrite raw direction')
bindings['SUPER + F16']()
assert(calls[#calls]:match("radial direction 2 ''$"), 'D-pad must retain app selection')
events['input.keyboard.key'](194, 0, 0)
bindings['SUPER + F13']()
assert(calls[#calls]:match("radial direction 6 ''$"), 'D-pad left must retain app selection')
events['input.keyboard.key'](133, 0, 0)
assert(calls[#calls]:match("radial activate 0 ''$"), 'LT release must activate app')
bindings['F7']()
bindings['SUPER + F19']()
assert(calls[#calls]:match('palette%-toggle 0$'), 'RT + left stick up must open browser menu')
events['input.keyboard.key'](69, 0, 0)
right_stick()
assert(calls[#calls]:match("radial direction 2 ''$"), 'RT + right-stick right must retain browser radial selection')
bindings['SUPER + F13']()
assert(calls[#calls]:match("radial step %-1 ''$"), 'D-pad must retain browser paging')
events['input.keyboard.key'](73, 0, 0)
assert(calls[#calls]:match("radial finish 0 ''$"), 'RT release must finish browser menu')
bindings['SUPER + F19']()
assert(bindings['SUPER + mouse_up']() == nil, 'open menu must consume its scroll input')
events['window.close']({ title = 'quickshell' })
assert(bindings['SUPER + mouse_up']().pass_event, 'hiding X11 palette must release mouse input')
bindings['SUPER + F19']()
assert(bindings['SUPER + mouse_up']() == nil, 'menu must reopen after X11 palette closes')
assert(options.F12.dont_inhibit, 'right-stick click must remain consumed on the desktop')
before = #calls
bindings['F7']()
bindings['SUPER + F12']()
right_stick()
assert(#calls == before, 'close and widen must not affect windows while an app radial is open')
events['window.close']({ title = 'quickshell' })
events['input.keyboard.key'](73, 0, 0)
before = #calls
bindings['SUPER + F12']()
assert(#calls == before, 'LT + right-stick without RT must not close')
bindings['F4']()
assert(calls[#calls] == 'layout:focus l', 'right-stick right without LT must focus')
right_stick()
assert(calls[#calls] == 'layout:move l', 'LT + right-stick right without RT must move')
before = #calls
right_stick(true)
assert(#calls == before + 1 and calls[#calls] == 'layout:move l', 'LT movement must still repeat')
bindings['F7']()
right_stick()
assert(calls[#calls] == 'layout:widen', 'LT + RT + right-stick right must widen')
before = #calls
for _ = 1, 20 do right_stick(true) end
assert(#calls == before, 'held right-stick must not toggle widen repeatedly')
events['input.keyboard.key'](70, 0, 0)
right_stick()
assert(#calls == before + 1 and calls[#calls] == 'layout:widen', 'released right-stick must rearm widening')
bindings['SUPER + F1']()
assert(calls[#calls] == 'layout:resize h', 'other RT + right-stick resize directions must remain')
bindings['SUPER + F12']()
assert(calls[#calls] == 'window.close', 'LT + RT + right-stick click must close, not widen')
assert(not options['SUPER + F12'].locked, 'close chord must remain blocked while locked')
assert(not options['SUPER + F12'].repeating, 'close click must not repeat')
events['input.keyboard.key'](73, 0, 0)
before = #calls
bindings['SUPER + F12']()
assert(#calls == before, 'RT release must disarm close chord')
calls = {}
events['window.active']({ title = 'Steam Big Picture Mode' })
assert(calls[#calls]:match('deck%-gaming%-mode sync$'), 'refocusing Big Picture must restore fullscreen')
print('PASS public Lua bindings: navigation, paging, guarded close chord, X11 palette close, and Big Picture focus')
