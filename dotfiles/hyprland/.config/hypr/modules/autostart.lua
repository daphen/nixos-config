return function(ctx)
	local hl = ctx.hl
	local REAL_MODE = ctx.REAL_MODE
	local DECK_MODE = ctx.DECK_MODE
	local SCRIPTS = ctx.SCRIPTS
	local ROW_COUNT = ctx.ROW_COUNT

	hl.on("hyprland.start", function()
		if DECK_MODE then
			local startup = {
				"sh -c 'dbus-update-activation-environment --systemd WAYLAND_DISPLAY DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE && systemctl --user start nixos-fake-graphical-session.target'",
				SCRIPTS .. "start-quickshell-desktop >> /tmp/hyprland-quickshell-main.log 2>&1",
				"wl-clip-persist --clipboard regular",
				"wvkbd-mobintl -H 280 -L 280 --hidden",
				"steam -silent",
			}
			for _, command in ipairs(startup) do
				hl.exec_cmd(command)
			end
			return
		end

		if REAL_MODE then
			local target, largest = nil, 0
			for _, monitor in ipairs(hl.get_monitors()) do
				local mode = monitor.mode
				local area = mode.width * mode.height * monitor.scale ^ 2
				if not monitor.name:match("^eDP%-") and area > largest then
					target, largest = monitor, area
				end
			end
			if target then
				hl.dispatch(hl.dsp.focus({ monitor = target.name }))
				hl.dispatch(
					hl.dsp.cursor.move({ x = target.x + target.mode.width / 2, y = target.y + target.mode.height / 2 })
				)
			end
			local startup = {
				"sh -c 'dbus-update-activation-environment --systemd WAYLAND_DISPLAY DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE && systemctl --user start nixos-fake-graphical-session.target'",
				SCRIPTS .. "start-quickshell-desktop >> /tmp/hyprland-quickshell-main.log 2>&1",
				"mutagen daemon start",
				"bash /home/daphen/.config/kanata/start-kanata.sh",
				"wl-clip-persist --clipboard regular",
				"systemd-run --user --collect --unit=clipse-image-session --property=Restart=always --property=RestartSec=1 wl-paste --type image/png --watch clipse --wl-store",
				"systemd-run --user --collect --unit=clipse-text-session --property=Restart=always --property=RestartSec=1 wl-paste --type text --watch clipse --wl-store",
				"swayidle -w timeout 300 "
					.. SCRIPTS
					.. "set-presence idle resume "
					.. SCRIPTS
					.. "set-presence active",
				SCRIPTS .. "hyprland-hotplug-handler >> /tmp/hyprland-hotplug-handler.log 2>&1",
				SCRIPTS .. "start-session-apps",
			}
			for _, command in ipairs(startup) do
				hl.exec_cmd(command)
			end
			return
		end

		for row = 1, ROW_COUNT do
			for column = 1, 3 do
				local title = string.format("Canvas %d.%d", row, column)
				hl.exec_cmd(
					string.format("kitty --class=hypr-canvas-fixture --title='%s' sh -c 'exec sleep infinity'", title)
				)
			end
		end
	end)
	if not DECK_MODE then
		pcall(require, "/home/daphen/.config/hypr/openwhispr-binds.lua")
	end
end
