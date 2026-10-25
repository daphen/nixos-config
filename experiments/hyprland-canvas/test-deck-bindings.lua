local bindings, calls, rules, events = {}, {}, {}, {}
local window = { class = "browser-personal", monitor = { name = "eDP-1" } }
local function dispatcher(name)
	return setmetatable({}, {
		__index = function(_, key) return dispatcher(name .. "." .. key) end,
		__call = function(_, value) return { name = name, value = value } end,
	})
end
local hl = {
	dsp = dispatcher("dsp"),
	get_active_window = function() return window end,
	get_windows = function() return {} end,
	get_layers = function() return {} end,
	on = function(event, callback)
		events[event] = events[event] or {}
		table.insert(events[event], callback)
	end,
	window_rule = function(rule) table.insert(rules, rule) end,
	gesture = function() end,
	dispatch = function(value) table.insert(calls, value) end,
	exec_cmd = function(value) table.insert(calls, { name = "exec", value = value }) end,
	bind = function(key, callback, options)
		table.insert(bindings, { key = key, callback = callback, options = options or {} })
		return { set_enabled = function() end }
	end,
}
local function press(key, device, released)
	local normalized = key:gsub("RETURN", "Return")
	local bare = normalized:gsub("SUPER %+ ", "")
	for _, binding in ipairs(bindings) do
		local filter, matches = binding.options.device, true
		if filter then
			local found = false
			for _, name in ipairs(filter.list) do found = found or name == device end
			matches = filter.inclusive == false and not found or filter.inclusive ~= false and found
		end
		local candidate = binding.key:gsub("RETURN", "Return")
		if matches and (binding.options.release or false) == (released or false) and
			(candidate == normalized or binding.options.ignore_mods and candidate == bare) then
			if type(binding.callback) == "function" then
				local result = binding.callback()
				if result and result.pass_event then table.insert(calls, { name = "pass", value = key }) end
			else hl.dispatch(binding.callback) end
		end
	end
end
local function release(key, device)
	local keycode = ({ F6 = 72, F7 = 73 })[key]
	if keycode then
		for _, callback in ipairs(events["input.keyboard.key"] or {}) do callback(keycode, 0, 0) end
	end
	press(key, device or "inputplumber-keyboard", true)
end
local function clear() calls = {} end
local function has(name, value)
	for _, call in ipairs(calls) do
		if call.name == name and (value == nil or call.value == value) then return true end
	end
	return false
end
assert(loadfile("dotfiles/hyprland/.config/hypr/modules/binds.lua"))()({
	hl = hl, REAL_MODE = true, DECK_MODE = true, SCRIPTS = "/scripts/", PAN_GAIN = 1,
	is_canvas_workspace = function() return true end,
	is_game_window = function(w)
		return w and w.title ~= "Steam Input On-screen Keyboard" and
			(w.class == "steam" or w.class:match("^steam_app_%d+$") ~= nil or (w.tags and w.tags[1] == "deck-game"))
	end,
})
local startup_rule
for _, rule in ipairs(rules) do
	if rule.name == "deck-steam-startup-no-initial-focus" then startup_rule = rule end
end
assert(startup_rule and startup_rule.no_initial_focus, "Steam's cold-start splash must not steal focus")
assert(startup_rule.match.class == "(?i)^(steam)?$" and startup_rule.match.title == "^Steam$", "startup focus protection must not match ordinary app windows")
clear()
for _, key in ipairs({ "SUPER + Return", "SUPER + Escape", "SUPER + F21", "SUPER + F22", "F21" }) do
	press(key, "inputplumber-keyboard")
end
assert(#calls == 0, "face buttons must not move, resize, close or overview desktop windows")
press("SUPER + F17", "inputplumber-keyboard")
clear()
press("F7", "inputplumber-keyboard")
window.class, window.title = "org.quickshell", "cockpit-qs · test"
press("F21", "inputplumber-keyboard")
assert(has("exec", "/scripts/palette-shell-ipc radial delete 0 ''"), "radial Y must delete even with RT held")
clear()
press("SUPER + Escape", "inputplumber-keyboard")
assert(has("exec", "/scripts/palette-shell-ipc radial cancel 0 ''"), "B must cancel the radial")
clear()
press("Escape", "extest-fake-device")
press("SUPER + Escape", "extest-fake-device")
press("Return", "extest-fake-device")
assert(#calls == 0, "Steam's duplicated A/B must not reach desktop or app shortcuts")
press("SUPER + Escape", "inputplumber-keyboard")
assert(#calls == 0, "B after radial cancellation must not resize the underlying window")
press("SUPER + F1", "inputplumber-keyboard")
assert(has("dsp.layout", "resize h"), "right-stick window resizing must remain available")
clear()
press("F23", "inputplumber-keyboard")
assert(#calls == 0, "Steam-button press must not switch modes")
for _, binding in ipairs(bindings) do
	assert(binding.key ~= "F23" or not binding.options.long_press, "Steam-button hold must not return to desktop")
end
for _, app in ipairs({
	{ "steam", "Steam Big Picture Mode" },
	{ "steam_app_440", "Game" },
	{ "steam", "Steam Input On-screen Keyboard" },
}) do
	window.class, window.title = app[1], app[2]
	clear()
	press("Return", "extest-fake-device")
	press("Escape", "extest-fake-device")
	assert(has("pass", "Return") and has("pass", "Escape"), "Steam must receive its own A/B keyboard events")
end
window.class, window.title = "steam", "Steam Big Picture Mode"
local function steam_tap()
	press("F23", "inputplumber-keyboard")
	release("F23")
end
local function returned()
	return has("dsp.exec_cmd", "/scripts/deck-gaming-mode return")
end
for _, triggers in ipairs({ {}, { "F6" }, { "F7" } }) do
	release("F6")
	release("F7")
	clear()
	for _, key in ipairs(triggers) do press(key, "inputplumber-keyboard") end
	steam_tap()
	assert(not returned(), "Steam alone or with only one trigger must not return to desktop")
	assert(has("dsp.exec_cmd", "/scripts/deck-gaming-mode tap"), "normal Steam tap must remain available")
end
for _, triggers in ipairs({ { "F6", "F7" }, { "F7", "F6" } }) do
	release("F6")
	release("F7")
	clear()
	for _, key in ipairs(triggers) do press(key, "inputplumber-keyboard") end
	press("F23", "inputplumber-keyboard")
	assert(not returned(), "wait for Steam release before switching the input profile")
	release(triggers[1])
	release(triggers[2])
	release("F23")
	assert(returned(), "both triggers then Steam must return, even if the triggers are released first")
	assert(not has("dsp.exec_cmd", "/scripts/deck-gaming-mode tap"), "return must not also re-enter Big Picture")
	clear()
	steam_tap()
	assert(not returned(), "the consumed chord must not affect the next Steam tap")
end
for _, key in ipairs({ "F6", "F7" }) do
	press("F6", "inputplumber-keyboard")
	press("F7", "inputplumber-keyboard")
	release(key)
	clear()
	steam_tap()
	assert(not returned(), "releasing either trigger before pressing Steam must cancel the chord")
end
release("F6")
release("F7")
clear()
press("F23", "inputplumber-keyboard")
press("F6", "inputplumber-keyboard")
press("F7", "inputplumber-keyboard")
release("F23")
assert(not returned(), "both triggers must already be held when Steam is pressed")
window.class, window.title = "browser-personal", "Desktop"
release("F6")
release("F7")
clear()
steam_tap()
assert(has("dsp.exec_cmd", "/scripts/deck-gaming-mode tap"), "Steam from desktop must still enter Big Picture")
for _, game in ipairs({ { "steam", "Steam Big Picture Mode" }, { "steam_app_440", "Game" }, { "native-game", "Native game", { "deck-game" } } }) do
	window.class, window.title, window.tags = game[1], game[2], game[3]
	for _, key in ipairs({ "F1", "F6", "F7", "F21", "F23", "F24", "SUPER + l", "ALT + r", "SUPER + Return", "Escape", "Super_L", "Super_R" }) do
		clear()
		press(key, "extest-fake-device")
		release(key, "extest-fake-device")
		for _, call in ipairs(calls) do
			assert(call.name == "pass", "Steam Input's " .. key .. " must reach the game, not desktop controls")
		end
	end
end
release("F6")
release("F7")
press("F6", "extest-fake-device")
press("F7", "extest-fake-device")
clear()
steam_tap()
assert(not returned(), "Steam Input keyboard mappings must not arm the physical trigger chord")
press("F6", "inputplumber-keyboard")
press("F7", "inputplumber-keyboard")
release("F6", "extest-fake-device")
release("F7", "extest-fake-device")
clear()
press("F23", "extest-fake-device")
release("F23", "extest-fake-device")
assert(#calls == 0, "Steam Input's F23 must not be treated as the physical Steam button")
steam_tap()
assert(returned(), "Steam Input key releases must not cancel the physical trigger chord")
window.class, window.title, window.tags = "browser-personal", "Desktop", nil
release("F6")
release("F7")
clear()
press("F1", "inputplumber-keyboard")
assert(has("dsp.layout", "focus h"), "desktop controls must resume outside games")
window.class, window.title = "steam_app_440", "Game"
clear()
press("XF86PowerOff", "gpio-keys")
assert(has("dsp.exec_cmd", "systemctl suspend"), "the power button must remain available in games")
clear()
press("XF86AudioRaiseVolume", "gpio-keys")
assert(has("dsp.exec_cmd", "wpctl set-mute @DEFAULT_AUDIO_SINK@ 0 && wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+"), "volume buttons must remain available in games")
print("PASS desktop controls, stock Steam Input keyboard mappings, both-triggers Steam return and no Steam-button hold shortcut")
