return function(ctx)
	local hl = ctx.hl
	local REAL_MODE = ctx.REAL_MODE
	local DECK_MODE = ctx.DECK_MODE

	if REAL_MODE then
		local function floating_rule(name, match, size)
			if DECK_MODE and size then
				size = "90% 80%"
			end
			local rule = {
				name = name,
				match = match,
				float = true,
				center = true,
			}
			if size then
				rule.size = size
			end
			hl.window_rule(rule)
		end

		if DECK_MODE then
			hl.window_rule({
				name = "deck-radial-overlay",
				match = { title = "^deck-radial-palette$", xwayland = true },
				float = true,
				no_initial_focus = true,
				size = "monitor_w monitor_h",
				move = "0 0",
				border_size = 0,
				rounding = 0,
				no_anim = true,
				no_blur = true,
			})
			hl.on("window.open", function(window)
				if window.title ~= "deck-radial-palette" then
					return
				end
				hl.dispatch(hl.dsp.window.set_prop({ prop = "no_blur", value = "1", window = window }))
				hl.timer(function()
					if window.mapped then
						hl.dispatch(hl.dsp.window.set_prop({ prop = "no_blur", value = "0", window = window }))
					end
				end, { timeout = 220, type = "oneshot" })
			end)
		end

		floating_rule("picture-in-picture", { class = "firefox$", title = "^Picture-in-Picture$" })
		floating_rule("slqs-upload", { class = "^slqs-upload$" }, "1100 800")
		hl.window_rule({
			name = "satty",
			match = { class = "^com\\.gabm\\.satty$" },
			float = true,
			center = true,
			size = "monitor_w*0.95 monitor_h*0.95",
			max_size = "monitor_w*0.95 monitor_h*0.95",
		})
		floating_rule("file-chooser", { class = "^file-chooser$" }, "62% 72%")
		floating_rule("media-viewer", { class = "^(imv|mpv)$" })
		floating_rule("one-password", { class = "^1password$" }, "1400 950")
		if DECK_MODE then
			hl.window_rule({
				name = "mail",
				match = { title = "^mlqs$" },
				float = true,
				size = "1264 732",
				move = "8 60",
			})
		else
			floating_rule("mail", { title = "^mlqs$" }, "1700 1100")
		end
		floating_rule("discord-voice", { class = "^(chrome-discord\\.com.*|dsqrd-voice)$" })
		floating_rule("calculator", { title = "(?i)calculator" })
		floating_rule("nautilus-dialog", { class = "(?i)org\\.gnome\\.Nautilus", title = "(?i)^(open|save)" })
		floating_rule("zenity", { class = "(?i)zenity" })
		floating_rule("clipse", { class = "^clipse$" }, "1000 750")
		floating_rule("btop", { class = "^btop$" }, "1600 1000")
		floating_rule("lovable-picker", { class = "^lovable_picker$" }, "1400 900")

		hl.window_rule({
			name = "canvas-client-fullscreen",
			match = { class = ".*" },
			sync_fullscreen = false,
		})
		hl.window_rule({
			name = "canvas-client-fullscreen-decorations",
			match = { class = ".*", fullscreen_state_client = 2 },
			border_size = 0,
			rounding = 0,
		})
		hl.window_rule({
			name = "opaque-heavy-apps",
			match = { class = "^(browser-personal|browser-work|Slack|vesktop)$" },
			no_blur = true,
			opaque = true,
		})
		hl.window_rule({
			name = "opaque-quickshell-workspaces",
			match = { class = "^org\\.quickshell$", title = "^(cockpit-qs|dsqrd)" },
			no_blur = true,
			opaque = true,
		})
		hl.layer_rule({
			name = "palette-rounding",
			match = { namespace = "^palette-daemon$" },
			ignore_alpha = 0,
		})
		hl.layer_rule({
			name = "palette-qml-animation",
			match = { namespace = "^qs-picker$" },
			no_anim = true,
		})
	end
end
