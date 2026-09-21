# Theme watcher - automatically refresh Tide prompt when theme changes
# Works with the theme-generator system

set -g __theme_watcher_last_mode ""

function __theme_watcher_check --on-event fish_prompt
    set -l theme_file "$HOME/.config/theme_mode"
    set -l themes_dir "$HOME/.config/themes/generated"

    if test -f $theme_file
        set -l current_mode (cat $theme_file)

        # Only update if theme mode changed
        if test "$current_mode" != "$__theme_watcher_last_mode"
            set -g __theme_watcher_last_mode $current_mode

            for tool in fish tide
                set -l theme "$themes_dir/$tool/$current_mode.theme"
                if test -f $theme
                    source $theme
                end
            end
        end
    end
end

# Initialize on shell start
__theme_watcher_check
