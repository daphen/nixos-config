return function(ctx)
	local hl = ctx.hl
	local REAL_MODE = ctx.REAL_MODE

	hl.config({
		general = {
			layout = "lua:canvas",
			gaps_in = 0,
			gaps_out = 0,
			border_size = 2,
			col = {
				active_border = { colors = { "rgb(10100E)", "rgb(10100E)" }, angle = 180 },
				inactive_border = "rgb(3A3A3A)",
			},
		},
		decoration = {
			rounding = 16,
			active_opacity = 1,
			inactive_opacity = 1,
			shadow = {
				enabled = false,
				range = 30,
				offset = "0 0",
				color = 0x77000000,
			},
			blur = {
				enabled = true,
				passes = 2,
				size = 6,
				noise = 0.02,
				vibrancy = 0.1,
			},
		},
		animations = { enabled = true },
		misc = {
			disable_hyprland_logo = true,
			force_default_wallpaper = 0,
		},
		input = input,
		cursor = {
			no_warps = true,
			inactive_timeout = REAL_MODE and 1.5 or 0,
			hide_on_key_press = REAL_MODE,
		},
	})

	local theme_path = (os.getenv("XDG_CONFIG_HOME") or os.getenv("HOME") .. "/.config") .. "/hypr/theme.lua"
	local theme_file = io.open(theme_path, "r")
	if theme_file then
		theme_file:close()
		hl.config(dofile(theme_path))
	end
end
