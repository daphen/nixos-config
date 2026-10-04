return function(ctx)
	local hl = ctx.hl
	local REAL_MODE = ctx.REAL_MODE
	local DECK_MODE = ctx.DECK_MODE

	local input = {
		follow_mouse = 0,
		touchpad = { natural_scroll = true },
	}
	if REAL_MODE and not DECK_MODE then
		input = {
			follow_mouse = 0,
			kb_file = "/home/daphen/.config/kanata/keymap.xkb",
			numlock_by_default = true,
			natural_scroll = true,
			touchpad = {
				disable_while_typing = true,
				natural_scroll = false,
				scroll_factor = 0.3,
				tap_to_click = true,
				tap_and_drag = false,
			},
		}
	end

	input.float_switch_override_focus = 0

	if DECK_MODE then
		hl.device({ name = "fts3528:00-2808:1015", output = "eDP-1", transform = 3 })
		for _, name in ipairs({ "inputplumber-mouse", "extest-fake-device-1" }) do
			hl.device({ name = name, enabled = true })
		end
		for _, name in ipairs({ "steamos-manager", "extest-fake-device", "inputplumber-keyboard" }) do
			hl.device({ name = name, kb_layout = "se" })
		end
		input.kb_options = "fkeys:basic_13-24"
		input.invert_horizontal_scroll = false
		hl.device({
			name = "inputplumber-touchpad",
			natural_scroll = false,
			sensitivity = 0.0,
			scroll_factor = 3.0,
		})
	end

	for _, name in ipairs({ "k:04-mini-mouse", "ergohaven-k:04-mini-mouse" }) do
		hl.device({ name = name, sensitivity = -0.2 })
	end
	hl.config({ input = input })
end
