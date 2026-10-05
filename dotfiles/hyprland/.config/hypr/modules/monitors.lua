return function(ctx)
	local hl = ctx.hl
	local REAL_MODE = ctx.REAL_MODE
	local DECK_MODE = ctx.DECK_MODE

	hl.monitor({
		output = "",
		mode = "preferred",
		position = "auto",
		scale = DECK_MODE and 1 or (REAL_MODE and "auto" or 1),
	})

	if DECK_MODE then
		hl.monitor({ output = "eDP-1", mode = "800x1280@90", position = "0x0", scale = 1, transform = 3 })
	elseif REAL_MODE then
		local monitors = {
			-- Hyprland requires integer logical dimensions; 1.75 is invalid at 3840x2400.
			{ output = "eDP-1", mode = "3840x2400@120", position = "0x0", scale = 1.6666666666667 },
			{
				output = "desc:ASUSTek COMPUTER INC PA32UCDM T7LMSB001350",
				mode = "3840x2160@120",
				position = "2304x0",
				scale = 1.25,
			},
			{ output = "desc:Dell Inc. DELL U2725QE G37YLF4", mode = "3840x2160@120", position = "-2560x0", scale = 1.5 },
			{
				output = "desc:Dell Inc. DELL P3425WE B94NY54",
				mode = "3440x1440@59.973",
				position = "-3440x-823",
				scale = 1,
			},
			{
				output = "desc:Dell Inc. DELL P3425WE 8Y8PY54",
				mode = "3440x1440@59.973",
				position = "-3440x-823",
				scale = 1,
			},
			{
				output = "desc:Dell Inc. DELL U2515H 9X2VY5840MWL",
				mode = "2560x1440@59.951",
				position = "-2560x0",
				scale = 1,
			},
			{
				output = "desc:Technical Concepts Ltd 27R83U X2414000823",
				mode = "3840x2160@144",
				position = "2304x0",
				scale = 1.5,
			},
			{
				output = "desc:Samsung Electric Company S34C65xV HNTY700216",
				mode = "3440x1440@59.973",
				position = "-3440x0",
				scale = 1,
			},
		}
		for _, monitor in ipairs(monitors) do
			hl.monitor(monitor)
		end
		hl.env("GTK_THEME", "", true)
		hl.env("FZF_DEFAULT_OPTS_FILE", "/home/daphen/.config/fzf/opts.conf")
		hl.env("FZF_DEFAULT_OPTS", "")
	end
	if REAL_MODE then
		hl.env("XCURSOR_THEME", "Adwaita")
		hl.env("XCURSOR_SIZE", "24")
	end
end
