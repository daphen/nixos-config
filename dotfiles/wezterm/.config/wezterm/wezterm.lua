local wezterm = require("wezterm")
local config = {}

-- Load theme from generated files
local home = os.getenv("HOME")
local theme_mode_file = home .. "/.config/theme_mode"

-- Read current theme mode (dark or light)
local function read_theme_mode()
  local file = io.open(theme_mode_file, "r")
  if file then
    local mode = file:read("*line")
    file:close()
    return mode or "dark"
  end
  return "dark"
end

-- Load generated theme
local theme_mode = read_theme_mode()
local theme_path = home .. "/.config/themes/generated/wezterm/" .. theme_mode .. ".theme"
local theme_ok, theme_colors = pcall(dofile, theme_path)

if theme_ok and theme_colors then
  config.color_schemes = {
    ["CustomTheme"] = theme_colors
  }
  config.color_scheme = "CustomTheme"
else
  -- Fallback to dark theme if loading fails
  wezterm.log_error("Failed to load theme from: " .. theme_path)
  config.color_schemes = {
    ["CustomDark"] = {
      background = "#181818",
      foreground = "#EDEDED",
      cursor_bg = "#FF570D",
      cursor_border = "#FF570D",
      cursor_fg = "#181818",
      ansi = {
        "#1B1B1B", "#FF7B72", "#97B5A6", "#FF570D",
        "#CCD5E4", "#8A92A7", "#8A9AA6", "#C3C8C6",
      },
      brights = {
        "#292826", "#FF7B72", "#97B5A6", "#ff8a31",
        "#CCD5E4", "#8A92A7", "#8A9AA6", "#EDEDED",
      },
    },
  }
  config.color_scheme = "CustomDark"
end

-- Window appearance
config.enable_tab_bar = false
config.window_decorations = "RESIZE"

-- Scrollback
config.scrollback_lines = 10000

-- Font configuration (from Ghostty)
config.font = wezterm.font("GeistMono Nerd Font")
config.font_size = 13
config.line_height = 1.25 -- equivalent to adjust-cell-height = 25%

-- Window padding
config.window_padding = {
  left = 30,
  right = 30,
  top = 30,
  bottom = 30,
}

-- Cursor configuration (from Ghostty)
config.cursor_thickness = 2

-- Other settings from Ghostty
config.hide_mouse_cursor_when_typing = true

config.default_prog = { "/usr/bin/fish" }
config.window_close_confirmation = "NeverPrompt"

-- Custom keybinding: Ctrl+S to enter copy mode
config.keys = {
  {
    key = "s",
    mods = "CTRL",
    action = wezterm.action.ActivateCopyMode,
  },
  -- Reload config
  {
    key = "r",
    mods = "CTRL|SHIFT",
    action = wezterm.action.ReloadConfiguration,
  },
  -- Paste from clipboard (Ctrl+Shift+V)
  {
    key = "v",
    mods = "CTRL|SHIFT",
    action = wezterm.action.PasteFrom("Clipboard"),
  },
  {
    key = "V",
    mods = "CTRL",
    action = wezterm.action.PasteFrom("Clipboard"),
  },
}

-- Override just the 'y' key in copy mode to copy to both clipboard and primary
local copy_mode = wezterm.gui.default_key_tables().copy_mode
for i, binding in ipairs(copy_mode) do
  if binding.key == "y" then
    copy_mode[i] = {
      key = "y",
      mods = "NONE",
      action = wezterm.action.Multiple({
        wezterm.action.CopyTo("ClipboardAndPrimarySelection"),
        wezterm.action.CopyMode("Close"),
      }),
    }
    break
  end
end
config.key_tables = { copy_mode = copy_mode }

return config
