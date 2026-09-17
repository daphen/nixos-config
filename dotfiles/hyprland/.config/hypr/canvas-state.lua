local root = (os.getenv("XDG_STATE_HOME") or (os.getenv("HOME") .. "/.local/state")) .. "/hypr-canvas"
local path = root .. "/layout.lua"
local instance = os.getenv("HYPRLAND_INSTANCE_SIGNATURE")
local previous
if instance then os.execute("mkdir -p -m 700 -- '" .. root:gsub("'", "'\\''") .. "'") end

local function encode(value)
    if type(value) ~= "table" then
        return type(value) == "string" and string.format("%q", value) or tostring(value)
    end
    local keys, parts = {}, {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, key in ipairs(keys) do
        parts[#parts + 1] = "[" .. encode(key) .. "]=" .. encode(value[key])
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

return {
    read = function()
        local file = io.open(path, "r")
        if not file then return {} end
        local text = file:read("*a")
        file:close()
        local chunk = load(text, "canvas layout", "t", {})
        local ok, saved = pcall(chunk or function() end)
        if not ok or type(saved) ~= "table" or saved.instance ~= instance or type(saved.workspaces) ~= "table" then
            return {}
        end
        for _, state in pairs(saved.workspaces) do
            if type(state) ~= "table" then return {} end
            for _, key in ipairs({"rows", "sizes", "camera", "row_offsets", "fullscreen", "widened"}) do
                if type(state[key]) ~= "table" then return {} end
            end
            if type(state.camera.x) ~= "number" or type(state.camera.y) ~= "number" then return {} end
        end
        previous = text
        return saved.workspaces
    end,
    write = function(states)
        if not instance then return end
        local workspaces = {}
        for key, state in pairs(states) do
            workspaces[key] = {
                rows = state.rows, sizes = state.sizes, camera = state.camera,
                row_offsets = state.row_offsets, row_center = state.row_center,
                focused_row = state.focused_row, viewport = state.viewport,
                fullscreen = state.fullscreen, widened = state.widened,
            }
        end
        local text = "return " .. encode({instance = instance, workspaces = workspaces}) .. "\n"
        if text == previous then return end
        local file, err = io.open(path .. ".tmp", "w")
        if file then
            local written
            written, err = file:write(text)
            local closed, close_err = file:close()
            if written and closed then
                local renamed
                renamed, err = os.rename(path .. ".tmp", path)
                if renamed then previous = text; return end
            else
                err = err or close_err
            end
        end
        print("Could not save canvas layout: " .. tostring(err))
    end,
}
