function reload_all --description "Reload Fish shell configuration and restart Kanata"
    # Use the restart script
    if test -f "$HOME/.config/kanata/restart-kanata.sh"
        echo "Restarting Kanata..."
        bash "$HOME/.config/kanata/restart-kanata.sh" &
        sleep 2  # Give kanata time to start
    else
        echo "Kanata restart script not found!"
    end

    # Reload Fish
    exec fish
end