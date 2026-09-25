return function(ctx)
	local hl = ctx.hl
	local REAL_MODE = ctx.REAL_MODE
	local DECK_MODE = ctx.DECK_MODE
	local SCRIPTS = ctx.SCRIPTS
	local PAN_GAIN = ctx.PAN_GAIN
	local is_canvas_workspace = ctx.is_canvas_workspace

	for _, direction in ipairs({ "h", "j", "k", "l" }) do
		hl.bind("SUPER + " .. direction, hl.dsp.layout("focus " .. direction))
		hl.bind("SUPER + SHIFT + " .. direction, hl.dsp.layout("move " .. direction))
		hl.bind("SUPER + CTRL + " .. direction, hl.dsp.layout("resize " .. direction))
	end

	local palette_tab_cycle_active = false
	local palette_tab_cycle_output = ""
	local function palette_tab_cycle(direction)
		return function()
			local window = hl.get_active_window()
			if not palette_tab_cycle_active then
				palette_tab_cycle_output = window and window.monitor and window.monitor.name or ""
			end
			palette_tab_cycle_active = true
			hl.exec_cmd(
				string.format("%spalette-shell-ipc tabCycle %d false %q", SCRIPTS, direction, palette_tab_cycle_output)
			)
		end
	end

	local function finish_palette_tab_cycle()
		if not palette_tab_cycle_active then
			return
		end
		palette_tab_cycle_active = false
		palette_tab_cycle_output = ""
		hl.exec_cmd(SCRIPTS .. "palette-shell-ipc tabCycle 0 true ''")
	end

	local palette_tab_bindings = {
		hl.bind("CTRL + h", palette_tab_cycle(-1), { repeating = true }),
		hl.bind("CTRL + l", palette_tab_cycle(1), { repeating = true }),
	}

	hl.on("input.keyboard.key", function(keycode, _, state)
		if state == 0 and (keycode == 37 or keycode == 105) then
			finish_palette_tab_cycle()
		end
	end)

	local function set_palette_tab_bindings(window)
		local class = window and window.class or ""
		local enabled = class == "browser-personal" or class == "browser-work"
		for _, binding in ipairs(palette_tab_bindings) do
			binding:set_enabled(enabled)
		end
		if enabled then
			local profile = class == "browser-work" and "work" or "personal"
			hl.exec_cmd(string.format("%spalette-shell-ipc focusProfile %q", SCRIPTS, profile))
		end
	end

	set_palette_tab_bindings(hl.get_active_window())
	hl.on("window.active", set_palette_tab_bindings)

	hl.bind("ALT + CTRL + h", hl.dsp.layout("pan -120 0"), { repeating = true })
	hl.bind("ALT + CTRL + l", hl.dsp.layout("pan 120 0"), { repeating = true })
	hl.bind("ALT + CTRL + k", hl.dsp.layout("pan 0 -120"), { repeating = true })
	hl.bind("ALT + CTRL + j", hl.dsp.layout("pan 0 120"), { repeating = true })
	hl.bind("ALT + SHIFT + j", hl.dsp.layout("move-row j"))
	hl.bind("ALT + SHIFT + k", hl.dsp.layout("move-row k"))
	hl.bind("ALT + r", hl.dsp.layout("reset"))
	hl.bind("SUPER + SHIFT + d", hl.dsp.exec_cmd(SCRIPTS .. "desktop-launch kitty"))
	hl.bind("SUPER + CTRL + w", hl.dsp.window.close())
	hl.bind("SUPER + TAB", hl.dsp.layout("overview"))
	hl.bind("SUPER + CTRL + f", hl.dsp.layout("widen"))
	hl.bind("SUPER + CTRL + SHIFT + f", hl.dsp.window.float({ action = "toggle" }))
	hl.bind("SUPER + d", hl.dsp.exec_cmd(SCRIPTS .. "focus-kitty-cycle"))
	hl.bind("SUPER + u", hl.dsp.focus({ monitor = "+1" }))
	hl.bind("ALT + h", hl.dsp.focus({ monitor = "l" }))
	hl.bind("ALT + j", hl.dsp.focus({ monitor = "d" }))
	hl.bind("ALT + k", hl.dsp.focus({ monitor = "u" }))
	hl.bind("ALT + l", hl.dsp.focus({ monitor = "r" }))
	hl.bind("SUPER + CTRL + SHIFT + h", hl.dsp.window.move({ monitor = "l" }))
	hl.bind("SUPER + CTRL + SHIFT + j", hl.dsp.window.move({ monitor = "d" }))
	hl.bind("SUPER + CTRL + SHIFT + k", hl.dsp.window.move({ monitor = "u" }))
	hl.bind("SUPER + CTRL + SHIFT + l", hl.dsp.window.move({ monitor = "r" }))
	hl.bind("ALT + CTRL + SHIFT + h", hl.dsp.workspace.move({ monitor = "l" }))
	hl.bind("ALT + CTRL + SHIFT + j", hl.dsp.workspace.move({ monitor = "d" }))
	hl.bind("ALT + CTRL + SHIFT + k", hl.dsp.workspace.move({ monitor = "u" }))
	hl.bind("ALT + CTRL + SHIFT + l", hl.dsp.workspace.move({ monitor = "r" }))
	if not DECK_MODE then
		hl.bind("ALT + escape", hl.dsp.exec_cmd(SCRIPTS .. "session-exit"))
	end

	local deck_dictation_active = false
	local deck_dictation_f9_down = false
	local function stop_deck_dictation()
		if not deck_dictation_active then
			return
		end
		deck_dictation_active = false
		hl.exec_cmd(
			"dbus-send --session --type=method_call --dest=com.openwhispr.App /com/openwhispr/App com.openwhispr.App.PttUp"
		)
	end

	if DECK_MODE then
		hl.workspace_rule({ workspace = "name:gaming", layout = "dwindle" })
		hl.window_rule({
			name = "deck-big-picture-fullscreen",
			match = { class = "(?i)^steam$", title = "^Steam Big Picture Mode$" },
			fullscreen = true,
		})
		hl.window_rule({
			name = "deck-steam",
			match = {
				class = "(?i)^(steam|steam_app_[0-9]+)$",
				title = "negative:^Steam Input On-screen Keyboard$",
			},
			workspace = "name:gaming",
			sync_fullscreen = true,
		})
		hl.window_rule({
			name = "deck-game-fullscreen",
			match = { workspace = "name:gaming" },
			sync_fullscreen = true,
		})
		hl.window_rule({
			name = "deck-steam-keyboard",
			match = { class = "(?i)^steam$", title = "^Steam Input On-screen Keyboard$" },
			opacity = "0.7",
			float = true,
			pin = true,
			no_initial_focus = true,
			no_blur = true,
			border_size = 0,
			no_shadow = true,
		})
		hl.on("workspace.active", function()
			hl.dispatch(hl.dsp.exec_cmd(SCRIPTS .. "deck-gaming-mode sync"))
		end)
		for _, event in ipairs({ "window.open", "window.close" }) do
			hl.on(event, function(window)
				if window.title == "Steam Input On-screen Keyboard" then
					hl.dispatch(hl.dsp.exec_cmd(SCRIPTS .. "deck-gaming-mode sync"))
				end
			end)
		end
		hl.on("window.active", function(window)
			if window and window.title == "Steam Big Picture Mode" then
				hl.dispatch(hl.dsp.exec_cmd(SCRIPTS .. "deck-gaming-mode sync"))
			end
		end)
		local steam_held = false
		hl.bind("F23", function()
			steam_held = false
		end, { dont_inhibit = true })
		hl.bind("F23", function()
			steam_held = true
			hl.dispatch(hl.dsp.exec_cmd(SCRIPTS .. "deck-gaming-mode return"))
		end, { long_press = true, dont_inhibit = true })
		hl.bind("F23", function()
			if not steam_held then
				hl.dispatch(hl.dsp.exec_cmd(SCRIPTS .. "deck-gaming-mode tap"))
			end
		end, { release = true, dont_inhibit = true })
		local radial_open, radial_outer, radial_kind = false, false, nil
		local radial_ring_outer = false
		local deck_rt_down = false
		local keyboard_toggle_held = false
		local radial_held = { false, false, false, false }
		local apps_held = { false, false, false, false }
		local radial_last_direction = 0
		local radial_release_timer
		local function cancel_radial_release()
			if radial_release_timer then
				radial_release_timer:set_enabled(false)
				radial_release_timer = nil
			end
		end
		local function radial_ipc(action, value)
			hl.exec_cmd(string.format("%spalette-shell-ipc radial %s %d ''", SCRIPTS, action, value or 0))
		end
		local function toggle_radial_ring(kind)
			if radial_open and radial_kind == kind then
				if kind == "apps" then
					radial_ipc("cycle", 0)
				else
					radial_ring_outer = not radial_ring_outer
					radial_ipc("outer", radial_ring_outer and 1 or 0)
				end
			end
		end
		local function reset_radial()
			cancel_radial_release()
			radial_open, radial_kind = false, nil
			radial_ring_outer = false
			radial_held = { false, false, false, false }
			apps_held = { false, false, false, false }
		end
		local function close_radial(action)
			if not radial_open then
				return
			end
			reset_radial()
			radial_ipc(action, 0)
		end
		hl.on("window.close", function(window)
			if window.title == "quickshell" then
				reset_radial()
			end
		end)
		local function start_deck_dictation()
			if deck_dictation_active then
				return
			end
			close_radial("cancel")
			deck_dictation_active = true
			hl.exec_cmd(
				"dbus-send --session --type=method_call --dest=com.openwhispr.App /com/openwhispr/App com.openwhispr.App.PttDown"
			)
		end
		local function stick_direction(held)
			local x = (held[4] and 1 or 0) - (held[1] and 1 or 0)
			local y = (held[2] and 1 or 0) - (held[3] and 1 or 0)
			local directions = {
				["0,-1"] = 0,
				["1,-1"] = 1,
				["1,0"] = 2,
				["1,1"] = 3,
				["0,1"] = 4,
				["-1,1"] = 5,
				["-1,0"] = 6,
				["-1,-1"] = 7,
			}
			return directions[x .. "," .. y]
		end
		local function update_radial_direction(held)
			local direction = stick_direction(held)
			if direction ~= nil then
				radial_last_direction = direction
				if radial_open then
					radial_ipc("direction", direction)
				end
			end
			return radial_last_direction
		end
		local function schedule_radial_release(held)
			cancel_radial_release()
			radial_release_timer = hl.timer(function()
				radial_release_timer = nil
				if radial_open and stick_direction(held) ~= nil then
					update_radial_direction(held)
				end
			end, { timeout = 25, type = "oneshot" })
		end
		local function radial_press(index)
			if deck_dictation_active or radial_kind == "apps" then
				return
			end
			cancel_radial_release()
			radial_held[index] = true
			if radial_open then
				if radial_kind == "browser" then
					update_radial_direction(radial_held)
				end
				return
			end
			local direction = update_radial_direction(radial_held)
			local window = hl.get_active_window()
			if window and (window.class == "browser-personal" or window.class == "browser-work") then
				radial_open, radial_kind = true, "browser"
				radial_ring_outer = false
				hl.dispatch(hl.dsp.layout("pan-cancel"))
				hl.exec_cmd(string.format("%spalette-toggle %d", SCRIPTS, direction))
			end
		end
		local function apps_radial_press(index, analog)
			if deck_dictation_active then
				return
			end
			cancel_radial_release()
			if not analog then
				apps_held[index] = true
			end
			if radial_open and radial_kind == "browser" then
				if not analog then
					if index == 1 then
						radial_ipc("step", -1)
					elseif index == 4 then
						radial_ipc("step", 1)
					end
				end
				return
			end
			local direction = analog and ({ 6, 4, 0, 2 })[index] or update_radial_direction(apps_held)
			if not radial_open then
				radial_open, radial_kind = true, "apps"
				radial_ring_outer = false
				hl.dispatch(hl.dsp.layout("pan-cancel"))
				hl.exec_cmd(string.format("%spalette-toggle %d", SCRIPTS, 16 + direction))
			end
		end
		hl.bind("F7", function()
			deck_rt_down = true
		end, { ignore_mods = true })
		local right_stick_directions = { "h", "j", "k", "l" }
		for index, key in ipairs({ "F1", "F2", "F3", "F4" }) do
			local direction = right_stick_directions[index]
			hl.bind(key, function()
				if radial_open then
					if radial_kind == "browser" then
						radial_press(index)
					end
					return
				end
				if radial_outer and (key == "F1" or key == "F4") then
					local window = hl.get_active_window()
					if window and (window.class == "browser-personal" or window.class == "browser-work") then
						hl.dispatch(hl.dsp.send_shortcut({ mods = "ALT", key = key == "F1" and "Left" or "Right" }))
						return
					end
				end
				hl.dispatch(hl.dsp.layout("focus " .. direction))
			end, { repeating = true })
			hl.bind("SUPER + " .. key, function()
				if radial_open then
					if radial_kind == "browser" then
						radial_press(index)
					end
					return
				end
				hl.dispatch(hl.dsp.layout((deck_rt_down and "resize " or "move ") .. direction))
			end, { repeating = true })
		end
		local function radial_outer_press()
			if not radial_open then
				radial_outer = true
			end
		end
		hl.bind("F11", radial_outer_press)
		hl.bind("SUPER + F11", radial_outer_press)
		hl.on("input.keyboard.key", function(keycode, _, key_state)
			if key_state == 0 then
				if keycode == 73 then
					deck_rt_down = false
					if radial_open and radial_kind == "browser" then
						close_radial(radial_ring_outer and "activate" or "finish")
					end
				end
				if keycode == 75 then
					deck_dictation_f9_down = false
				end
				if keycode == 75 or keycode == 133 then
					stop_deck_dictation()
				end
			end
			if keycode >= 67 and keycode <= 70 and key_state == 0 then
				radial_held[keycode - 66] = false
				if radial_kind == "browser" then
					schedule_radial_release(radial_held)
				end
			elseif keycode >= 191 and keycode <= 194 and key_state == 0 then
				apps_held[keycode - 190] = false
				radial_held[keycode - 190] = false
				if radial_kind == "apps" then
					schedule_radial_release(apps_held)
				elseif radial_kind == "browser" then
					schedule_radial_release(radial_held)
				end
			elseif keycode == 95 and key_state == 0 then
				radial_outer = false
			elseif keycode == 133 and key_state == 0 and radial_open then
				close_radial((radial_kind == "apps" or radial_ring_outer) and "activate" or "finish")
			end
		end)
		local deck_directions = {
			F13 = "h",
			F14 = "j",
			F15 = "k",
			F16 = "l",
		}
		local deck_arrows = { h = "Left", j = "Down", k = "Up", l = "Right" }
		for key, direction in pairs(deck_directions) do
			hl.bind(key, function()
				if radial_open then
					if key == "F13" then
						radial_ipc("step", -1)
					elseif key == "F16" then
						radial_ipc("step", 1)
					end
					return
				end
				for _, layer in ipairs(hl.get_layers({ namespace = "qs-rounded-bar" })) do
					if layer.keyboard_interactivity ~= 0 then
						hl.dispatch(hl.dsp.send_key_state({ mods = "", key = deck_arrows[direction], state = "down" }))
						hl.dispatch(hl.dsp.send_key_state({ mods = "", key = deck_arrows[direction], state = "up" }))
						return
					end
				end
				hl.dispatch(hl.dsp.layout("focus " .. direction))
			end, { repeating = true })
			local apps_index = ({ F13 = 1, F14 = 2, F15 = 3, F16 = 4 })[key]
			hl.bind("SUPER + " .. key, function()
				apps_radial_press(apps_index)
			end, { repeating = true })
			hl.bind("SHIFT + " .. key, hl.dsp.layout("move " .. direction), { repeating = true })
			hl.bind("CTRL + " .. key, hl.dsp.layout("resize " .. direction), { repeating = true })
		end
		for index, key in ipairs({ "F17", "F18", "F19", "F20" }) do
			hl.bind(key, function() end, { ignore_mods = true })
			hl.bind("SUPER + " .. key, function()
				if deck_rt_down then
					radial_press(index)
				else
					apps_radial_press(index, true)
				end
			end, { repeating = true })
		end
		-- Steam owns normal stick arrows; LT selection must not also send arrows.
		for _, key in ipairs({ "Left", "Down", "Up", "Right" }) do
			hl.bind("SUPER + " .. key, function() end, { device = { list = { "extest-fake-device" } } })
		end
		for _, axis in ipairs({ "mouse_up", "mouse_down", "mouse_left", "mouse_right" }) do
			hl.bind("SUPER + " .. axis, function()
				if not radial_open then
					return { pass_event = true }
				end
			end)
		end
		local function rt_face_key(index)
			if not deck_rt_down then
				return false
			end
			local window = hl.get_active_window()
			if not window then
				return false
			end
			local key
			if window.class == "org.quickshell" and (window.title or ""):match("^cockpit%-qs") then
				key = tostring(index)
			elseif index == 1 and (window.class == "browser-personal" or window.class == "browser-work") then
				key = "f"
			else
				return false
			end
			for _, state in ipairs({ "down", "up" }) do
				hl.dispatch(hl.dsp.send_key_state({ mods = "", key = key, state = state }))
			end
			return true
		end
		hl.bind("Return", function()
			if rt_face_key(1) then
				return
			end
			return { pass_event = true }
		end)
		hl.bind("F21", function()
			if rt_face_key(4) then
				return
			end
			if radial_open then
				radial_ipc("delete", 0)
			else
				hl.dispatch(hl.dsp.layout("overview"))
			end
		end)
		hl.bind("F22", function()
			if rt_face_key(3) then
				return
			end
			hl.dispatch(hl.dsp.exec_cmd("deck-osk-toggle"))
		end)
		hl.bind("Escape", function()
			if radial_open then
				close_radial("cancel")
				return
			end
			local window = hl.get_active_window()
			if window and window.title == "quickshell" then
				radial_ipc("cancel", 0)
				return
			end
			if rt_face_key(2) then
				return
			end
			for _, layer in ipairs(hl.get_layers({ namespace = "wvkbd" })) do
				if layer.mapped then
					hl.dispatch(hl.dsp.exec_cmd("pkill -USR1 -x wvkbd-mobintl"))
					return
				end
			end
			return { pass_event = true }
		end, { dont_inhibit = true })
		hl.bind("F24", hl.dsp.exec_cmd("qs ipc call -- launcher toggle"))
		hl.bind("F10", hl.dsp.exec_cmd("qs ipc call -- controlCenter toggle"))
		hl.bind("SUPER + mouse:272", hl.dsp.exec_cmd("qs ipc call -- launcher toggle"))
		hl.bind("SUPER + F21", function()
			if deck_rt_down and not radial_open then
				hl.dispatch(hl.dsp.window.close())
			elseif radial_open then
				radial_ipc("delete", 0)
			elseif radial_outer then
				hl.dispatch(hl.dsp.layout("move k"))
			end
		end)
		hl.bind("SUPER + Escape", function()
			if radial_open then
				close_radial("cancel")
			elseif radial_outer then
				hl.dispatch(hl.dsp.layout("move l"))
			else
				hl.dispatch(hl.dsp.layout("resize l"))
			end
		end)
		hl.bind("SUPER + F22", function()
			if radial_open then
				return
			elseif deck_rt_down then
				if keyboard_toggle_held then
					return
				end
				keyboard_toggle_held = true
				local window = hl.get_active_window()
				if window and is_canvas_workspace(window.workspace) then
					hl.dispatch(hl.dsp.layout("keyboard"))
				end
			elseif radial_outer then
				hl.dispatch(hl.dsp.layout("move h"))
			else
				hl.dispatch(hl.dsp.layout("resize h"))
			end
		end, { repeating = true })
		hl.bind("F22", function()
			keyboard_toggle_held = false
		end, { release = true, ignore_mods = true })
		hl.bind("F9", function()
			deck_dictation_f9_down = true
		end)
		hl.bind("SUPER + F9", function()
			deck_dictation_f9_down = true
			start_deck_dictation()
		end)
		hl.bind("code:133", function()
			if deck_dictation_f9_down then
				start_deck_dictation()
			end
		end, { ignore_mods = true })
		hl.bind("F8", function()
			toggle_radial_ring(radial_kind)
		end, { dont_inhibit = true })
		hl.bind("SUPER + F8", function()
			if radial_open then
				toggle_radial_ring(radial_kind)
			else
				start_deck_dictation()
			end
		end, { dont_inhibit = true })
		hl.bind("SUPER + F8", stop_deck_dictation, { release = true, dont_inhibit = true })
		hl.bind("F12", function() end, { dont_inhibit = true })
		hl.bind("SUPER + F12", function()
			if not radial_open and deck_rt_down then
				hl.dispatch(hl.dsp.layout("widen"))
			end
		end, { dont_inhibit = true })
		hl.bind("SUPER + SPACE", hl.dsp.exec_cmd("qs ipc call -- launcher toggle"))
		hl.bind("SUPER + RETURN", function()
			if radial_open then
				close_radial("activate")
			elseif radial_outer then
				hl.dispatch(hl.dsp.layout("move j"))
			else
				hl.exec_cmd("qs ipc call -- launcher toggle")
			end
		end)
		hl.bind("XF86PowerOff", hl.dsp.exec_cmd("systemctl suspend"), { locked = true })
	end

	if REAL_MODE and DECK_MODE then
		local function app(key, selector, command)
			hl.bind(
				"SUPER + " .. key,
				hl.dsp.exec_cmd(string.format("%sjump-or-exec %q %q", SCRIPTS, selector, command))
			)
		end
		local launch = SCRIPTS .. "desktop-launch "
		hl.bind("SUPER + q", hl.dsp.exec_cmd(launch .. SCRIPTS .. "browser-personal"))
		hl.bind("SUPER + w", hl.dsp.exec_cmd(launch .. SCRIPTS .. "browser-work"))
		app("c", "title:dsqrd", "dsqrd-client")
		app("s", "title:slqs", "slqs-client")
		app("a", "spotify_player", "kitty --class spotify_player " .. SCRIPTS .. "spotify-player-launch")
		app("m", "title:mlqs", "mlqs-client")
		app("o", "title:cockpit-qs", "deck-cockpit")
		app("p", "title:opqs", "opqs-client")
		app("b", "btop", "kitty --class btop btop")
		hl.bind("SUPER + e", hl.dsp.exec_cmd(launch .. SCRIPTS .. "spawn-terminal-with-yazi"))
	end

	if REAL_MODE and not DECK_MODE then
		local scripts = SCRIPTS
		local function picker(name)
			return hl.dsp.exec_cmd("qs ipc call -- " .. name .. " toggle")
		end
		local function launch(command)
			return scripts .. "desktop-launch " .. command
		end
		local function bind_exec(key, command, options)
			hl.bind(key, hl.dsp.exec_cmd(command), options)
		end
		local function jump(selector, command, here)
			local flag = here and "--here " or ""
			return hl.dsp.exec_cmd(string.format("%sjump-or-exec %s%q %q", scripts, flag, selector, command))
		end

		hl.bind("SUPER + q", hl.dsp.exec_cmd(launch(scripts .. "browser-personal")))
		hl.bind("SUPER + w", hl.dsp.exec_cmd(launch(scripts .. "browser-work")))
		hl.bind("SUPER + SHIFT + q", hl.dsp.exec_cmd(launch(scripts .. "chromium-launch")))
		hl.bind("SUPER + SHIFT + w", hl.dsp.exec_cmd(launch(scripts .. "browser-work-new")))
		hl.bind("SUPER + c", jump("title:dsqrd", scripts .. "launch-discord-client"))
		hl.bind("SUPER + s", jump("Slack", "slack"))
		hl.bind("SUPER + SHIFT + s", jump("Slack", "slack"))
		hl.bind(
			"SUPER + a",
			jump("spotify_player", "kitty --class spotify_player " .. scripts .. "spotify-player-launch")
		)
		hl.bind("SUPER + m", jump("title:mlqs", scripts .. "launch-mail-client", true))
		hl.bind("SUPER + SHIFT + g", jump("title:qstns", "/home/daphen/personal/qstns/run.sh", true))
		hl.bind("SUPER + g", jump("cockpit-nvim", "true"))
		hl.bind("SUPER + i", hl.dsp.exec_cmd(scripts .. "inbox-jump"))
		hl.bind(
			"SUPER + v",
			hl.dsp.exec_cmd(
				"dbus-send --session --type=method_call --dest=com.openwhispr.App /com/openwhispr/App com.openwhispr.App.PttDown"
			)
		)
		hl.bind(
			"SUPER + v",
			hl.dsp.exec_cmd(
				"dbus-send --session --type=method_call --dest=com.openwhispr.App /com/openwhispr/App com.openwhispr.App.PttUp"
			),
			{ release = true }
		)
		hl.bind("SUPER + t", hl.dsp.exec_cmd(scripts .. "cockpit-rail-roster"))
		hl.bind("SUPER + y", hl.dsp.exec_cmd(scripts .. "agent-ask-or-cockpit"))
		hl.bind("SUPER + SHIFT + y", hl.dsp.exec_cmd(launch(scripts .. "cockpit-new")))
		hl.bind(
			"SUPER + CTRL + y",
			hl.dsp.exec_cmd(
				"notify-send -t 3000 'Orchestrator' 'handover starting…'; out=$($HOME/.local/bin/cockpit-handover 2>&1 | tail -3); notify-send -t 8000 'Orchestrator' \"$out\""
			)
		)
		hl.bind("SUPER + o", hl.dsp.exec_cmd(scripts .. "cockpit-toggle"))
		hl.bind(
			"SUPER + CTRL + g",
			hl.dsp.exec_cmd(launch("kitty --class lovable_picker " .. scripts .. "spawn-claude-session-picker"))
		)
		hl.bind("SUPER + e", hl.dsp.exec_cmd(launch(scripts .. "spawn-terminal-with-yazi")))
		hl.bind("SUPER + b", jump("btop", "kitty --class btop btop", true))
		hl.bind("SUPER + SPACE", picker("launcher"))
		hl.bind("SUPER + RETURN", picker("launcher"))
		hl.bind("SUPER + r", picker("review-create"))
		hl.bind("SUPER + f", hl.dsp.exec_cmd(scripts .. "palette-toggle"))
		hl.bind("SUPER + CTRL + t", picker("cockpit"))
		hl.bind("SUPER + n", picker("notes"))
		hl.bind("SUPER + CTRL + v", picker("clipboard"))
		hl.bind("SUPER + CTRL + i", picker("timers"))
		hl.bind("SUPER + CTRL + b", picker("bluetooth"))
		hl.bind("SUPER + CTRL + n", picker("network"))
		hl.bind("SUPER + CTRL + p", picker("asus-profile"))
		hl.bind("SUPER + escape", hl.dsp.exec_cmd("qs ipc call -- notifications dismissAll"))
		hl.bind("F8", picker("emoji"), { locked = true })

		bind_exec("SUPER + p", launch("opqs-client"))
		bind_exec("SUPER + SHIFT + p", scripts .. "jump-or-exec 1password 1password")
		bind_exec("SUPER + CTRL + q", scripts .. "force-kill-focused")
		if not DECK_MODE then
			bind_exec("SUPER + CTRL + SHIFT + q", "swaylock")
		end
		bind_exec("SUPER + ALT + s", "pkill orca || exec orca", { locked = true })
		bind_exec("SUPER + SHIFT + m", "palette-ipc add-quickmark")
		bind_exec("SUPER + CTRL + SHIFT + t", "qs ipc call -- todos toggle")
		bind_exec("SUPER + SHIFT + n", "/home/daphen/.config/quickshell/scripts/notes-capture note")
		bind_exec("SUPER + CTRL + SHIFT + c", "qs ipc call -- color-format toggle")
		bind_exec(
			"SUPER + CTRL + SHIFT + d",
			'f=$HOME/.config/quickshell/dnd; if [ -e "$f" ]; then rm -f "$f"; else mkdir -p "$(dirname "$f")" && touch "$f"; fi'
		)
		bind_exec("SUPER + CTRL + SHIFT + b", scripts .. "waybar-theme --cycle")
		bind_exec("SUPER + CTRL + a", scripts .. "toggle-headphones")
		bind_exec("SUPER + SHIFT + r", scripts .. "record-toggle region")
		bind_exec("SUPER + CTRL + c", scripts .. "pick-color")
		bind_exec("SUPER + CTRL + SHIFT + e", scripts .. "screenshot-to-clipboard")
		bind_exec(
			"SUPER + SHIFT + e",
			'f="$HOME/Pictures/Screenshots/Screenshot from $(date +\'%Y-%m-%d %H-%M-%S\').png"; id=$(hyprctl -j activewindow | jq -er \'.stableId\') && grim -T "$id" - | tee "$f" | wl-copy && [ -s "$f" ] && notify-send -a Screenshot Screenshot \'Copied to clipboard\''
		)
		bind_exec(
			"SUPER + CTRL + e",
			"o=$(hyprctl -j monitors | jq -r '.[] | select(.focused).name'); grim -o \"$o\" - | tee \"$HOME/Pictures/Screenshots/Screenshot from $(date +'%Y-%m-%d %H-%M-%S').png\" | wl-copy"
		)

		bind_exec(
			"XF86AudioRaiseVolume",
			"wpctl set-mute @DEFAULT_AUDIO_SINK@ 0 && wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+",
			{ locked = true, repeating = true }
		)
		bind_exec(
			"XF86AudioLowerVolume",
			"wpctl set-mute @DEFAULT_AUDIO_SINK@ 0 && wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-",
			{ locked = true, repeating = true }
		)
		bind_exec("XF86AudioMute", "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle", { locked = true })
		bind_exec("XF86AudioMicMute", scripts .. "toggle-mic", { locked = true })
		bind_exec("XF86WebCam", scripts .. "toggle-camera", { locked = true })
		bind_exec("XF86MonBrightnessUp", scripts .. "brightness-throttled 5%+", { locked = true, repeating = true })
		bind_exec("XF86MonBrightnessDown", scripts .. "brightness-throttled 5%-", { locked = true, repeating = true })
		bind_exec("XF86KbdBrightnessUp", "asusctl leds next", { locked = true })
		bind_exec("XF86KbdBrightnessDown", "asusctl leds prev", { locked = true })
		bind_exec("XF86KbdLightOnOff", "asusctl leds next", { locked = true })
		bind_exec("F1", "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle", { locked = true })
		bind_exec(
			"F2",
			"wpctl set-mute @DEFAULT_AUDIO_SINK@ 0 && wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-",
			{ locked = true, repeating = true }
		)
		bind_exec(
			"F3",
			"wpctl set-mute @DEFAULT_AUDIO_SINK@ 0 && wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+",
			{ locked = true, repeating = true }
		)
		bind_exec("F4", "brightnessctl --device='*kbd_backlight' set 33%+", { locked = true, repeating = true })
		bind_exec("F5", scripts .. "brightness-throttled 5%-", { locked = true, repeating = true })
		bind_exec("F6", scripts .. "brightness-throttled 5%+", { locked = true, repeating = true })
		bind_exec("F9", scripts .. "toggle-mic", { locked = true })
		bind_exec("F10", scripts .. "toggle-camera", { locked = true })
		bind_exec("XF86AudioPlay", "playerctl play-pause", { locked = true })
		bind_exec("XF86AudioPause", "playerctl play-pause", { locked = true })
		bind_exec("XF86AudioNext", "playerctl next", { locked = true })
		bind_exec("XF86AudioPrev", "playerctl previous", { locked = true })
	end

	hl.bind("Super_L", function()
		hl.dispatch(hl.dsp.layout("pan-end"))
	end, { release = true, ignore_mods = true })
	hl.bind("Super_R", hl.dsp.layout("pan-end"), { release = true, ignore_mods = true })

	local overview_timer
	hl.gesture({
		fingers = 3,
		direction = "swipe",
		action = {
			start = function()
				hl.dispatch(hl.dsp.layout("pan-begin"))
				overview_timer = hl.timer(function()
					overview_timer = nil
					hl.dispatch(hl.dsp.layout("pan-overview"))
				end, { timeout = 350, type = "oneshot" })
			end,
			update = function(e)
				hl.dispatch(hl.dsp.layout(string.format("pan %.6f %.6f", e.delta.x * PAN_GAIN, e.delta.y * PAN_GAIN)))
			end,
			finish = function()
				if overview_timer then
					overview_timer:set_enabled(false)
					overview_timer = nil
				end
				hl.dispatch(hl.dsp.layout("pan-end"))
			end,
		},
	})
end
