local directory = debug.getinfo(1, "S").source:sub(2):match("(.*/)")
dofile(directory .. "../phantomat-camera.lua")
local config = (os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config")) .. "/hypr/canvas-tuning.lua"
local saved = io.open(config, "r")
if saved then
    saved:close()
    dofile(config)
end
hl.on("hyprland.start", function()
    hl.exec_cmd(string.format("qs -n -p %q", directory))
end)
hl.bind("CTRL + comma", hl.dsp.exec_cmd(string.format("qs ipc -p %q call canvas-tuning toggle", directory)))
