local bindings, calls = {}, {}
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
	on = function() end,
	window_rule = function() end,
	gesture = function() end,
	dispatch = function(value) table.insert(calls, value) end,
	exec_cmd = function(value) table.insert(calls, { name = "exec", value = value }) end,
	bind = function(key, callback, options)
		table.insert(bindings, { key = key, callback = callback, options = options or {} })
		return { set_enabled = function() end }
	end,
}
local function press(key, device)
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
		if matches and not binding.options.release and
			(candidate == normalized or binding.options.ignore_mods and candidate == bare) then
			if type(binding.callback) == "function" then binding.callback() else hl.dispatch(binding.callback) end
		end
	end
end
local function clear() calls = {} end
local function has(name, value)
	for _, call in ipairs(calls) do
		if call.name == name and (value == nil or call.value == value) then return true end
	end
	return false
end
assert(loadfile("dotfiles/hyprland/.config/hypr/modules/binds.lua"))()({
	hl = hl, REAL_MODE = false, DECK_MODE = true, SCRIPTS = "/scripts/", PAN_GAIN = 1,
	is_canvas_workspace = function() return true end,
	is_game_window = function() return false end,
})
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
print("PASS Deck face-button isolation, radial Y/B, Steam duplicates and right-stick resizing")
