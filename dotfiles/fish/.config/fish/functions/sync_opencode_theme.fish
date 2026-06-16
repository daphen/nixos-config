function sync_opencode_theme --description "Sync OpenCode theme with system"
    set -l current_theme "Light"

    # Check system theme based on OS
    if test (uname) = "Darwin"
        # macOS
        set current_theme (defaults read -g AppleInterfaceStyle 2>/dev/null || echo "Light")
    else if test -f ~/.config/theme_mode
        # Linux/Other - use theme_mode file
        set -l theme_content (cat ~/.config/theme_mode)
        if test "$theme_content" = "dark"
            set current_theme "Dark"
        end
    end

    set -l opencode_theme "light"
    if test "$current_theme" = "Dark"
        set opencode_theme "dark"
    end
    
    # Update OpenCode config
    set -l config_file ~/.config/opencode/opencode.json
    if test -f $config_file
        # Use jq if available, otherwise use sed
        if command -v jq > /dev/null
            jq ".theme = \"$opencode_theme\"" $config_file > $config_file.tmp && mv $config_file.tmp $config_file
        else
            # Cross-platform sed: macOS needs -i '', Linux needs -i
            if test (uname) = "Darwin"
                sed -i '' "s/\"theme\": \"[^\"]*\"/\"theme\": \"$opencode_theme\"/" $config_file
            else
                sed -i "s/\"theme\": \"[^\"]*\"/\"theme\": \"$opencode_theme\"/" $config_file
            end
        end
    end
end
