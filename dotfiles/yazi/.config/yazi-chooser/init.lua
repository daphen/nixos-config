-- Save-dialog only (YAZI_CONFIG_HOME points here). The chooser has no visible
-- "save as" field, so spell out what Enter does and where the file lands,
-- following whatever dir you navigate to. YAZI_SAVE_NAME is set by the wrapper.
local save_name = os.getenv("YAZI_SAVE_NAME")
if save_name and save_name ~= "" then
	Header:children_add(function()
		return ui.Line({
			ui.Span(" SAVE " .. save_name .. " here "):fg("black"):bg("green"),
			ui.Span(" ⏎ save · ⌃⏎ overwrite hovered · q cancel "):fg("green"),
		})
	end, 2000, Header.RIGHT)
end
