local bindings, calls, events, options = {}, {}, {}, {}
local noop = setmetatable({}, { __index = function(self) return self end, __call = function() return {} end })
package.loaded['canvas-state'] = { read = function() return {} end }
hl = setmetatable({
    dsp = setmetatable({ exec_cmd = function(s) return s end, layout = function(s) return 'layout:' .. s end }, getmetatable(noop)),
    bind = function(key, action, opts) bindings[key] = action; options[key] = opts; return noop end,
    on = function(event, action) events[event] = action end,
    dispatch = function(s) calls[#calls + 1] = s end,
    exec_cmd = function(s) calls[#calls + 1] = s end,
    get_layers = function() return {} end,
    get_active_window = function() return { class = 'browser-personal' } end,
    timer = function() return noop end,
}, { __index = function() return noop end })
assert(loadfile(assert(arg[1])))()
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
calls = {}
events['window.active']({ title = 'Steam Big Picture Mode' })
assert(calls[#calls]:match('deck%-gaming%-mode sync$'), 'refocusing Big Picture must restore fullscreen')
print('PASS public Lua bindings: navigation, paging, X11 palette close, and Big Picture focus')
