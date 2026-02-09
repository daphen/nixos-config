function toggle_theme -d "Toggle between light and dark themes"
    # Get current theme from file
    set -l current_theme "light"
    if test -f ~/.config/theme_mode
        set current_theme (cat ~/.config/theme_mode)
    end

    # Toggle the theme
    if test "$current_theme" = "dark"
        # Switch to light mode
        echo "light" > ~/.config/theme_mode
        set_light_theme
    else
        # Switch to dark mode
        echo "dark" > ~/.config/theme_mode
        set_dark_theme
    end

end