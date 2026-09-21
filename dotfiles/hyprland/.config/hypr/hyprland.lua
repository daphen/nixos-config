---@diagnostic disable-next-line: undefined-global
local hl = hl

local REAL_MODE = os.getenv("HYPR_CANVAS_REAL") == "1"
local PROFILE = os.getenv("HYPR_CANVAS_PROFILE") or "workstation"
local DECK_MODE = PROFILE == "deck"
local SCRIPTS = os.getenv("HYPR_SCRIPTS") or "/home/daphen/.config/hypr/scripts/"
local ROW_COUNT = 3
local GAP = DECK_MODE and 4 or 24
local TILE_WIDTH = 0.9
local PAN_GAIN = 8.0

local checkpoint = require("canvas-state")
local states = checkpoint.read()
local state

local function select_workspace(workspace)
    if not workspace then return false end
    local key = workspace.addressable_name
    if not states[key] then
        states[key] = {
            camera = { x = 0, y = 0 }, rows = { {}, {}, {} },
            row_offsets = { 0, 0, 0 }, sizes = {}, fullscreen = {}, widened = {},
        }
    end
    state = states[key]
    state.windows = state.windows or {}
    return true
end

local function forget(saved, id)
    for _, row in ipairs(saved.rows) do
        for i = #row, 1, -1 do
            if row[i] == id then table.remove(row, i) end
        end
    end
    saved.sizes[id], saved.fullscreen[id], saved.widened[id] = nil, nil, nil
    if saved.windows then saved.windows[id] = nil end
end

local function prune_closed_windows()
    local live = {}
    for _, window in ipairs(hl.get_windows()) do
        if window.mapped and not window.floating and window.workspace then
            live[tostring(window.stable_id)] = window.workspace.addressable_name
        end
    end
    -- A layout callback can contain only some targets during provider reattachment.
    -- Only the compositor's live window inventory can prove a saved entry is gone.
    for key, saved in pairs(states) do
        for id in pairs(saved.sizes) do
            if live[id] ~= key then forget(saved, id) end
        end
    end
end

local function is_canvas_workspace(workspace)
    return workspace and workspace.tiled_layout == "lua:canvas"
end

local function target_id(target)
    local window = target.window
    return window and tostring(window.stable_id) or tostring(target.index)
end

local function index_of(items, value)
    for i, item in ipairs(items) do
        if item == value then
            return i
        end
    end
end

local function active_id(ctx)
    for _, target in ipairs(ctx.targets) do
        if target.window and target.window.active then
            return target_id(target)
        end
    end
end

local function locate(id)
    for row, items in ipairs(state.rows) do
        local column = index_of(items, id)
        if column then
            return row, column
        end
    end
end

local function shortest_row()
    local best = 1
    for row = 2, #state.rows do
        if #state.rows[row] < #state.rows[best] then
            best = row
        end
    end
    return best
end

local function fixture_row(target)
    local window = target.window
    local title = window and window.title or ""
    local row = tonumber(title:match("^Canvas (%d+)%."))
    return row and math.min(row, #state.rows) or nil
end

local geometry
local fullscreen_geometry
local align_rows

local function default_height(ctx)
    return (ctx.area.h - GAP * 2) / ctx.area.h
end

fullscreen_geometry = function(ctx)
    local viewport = state.viewport or ctx.area
    return {
        size = {
            w = viewport.w / ctx.area.w,
            h = viewport.h / ctx.area.h,
        },
        viewport = viewport,
    }
end

local function initial_size(ctx, target)
    local window = target.window
    local class = window and window.class or ""
    local title = window and window.title or ""
    local width = 0.5
    local height = default_height(ctx)

    if class:match("^(kitty|claude|lovable_deps|lovable_devenv|browser%-work|spotify_player|vesktop|Slack)$")
        or (class == "org.quickshell" and title:match("^(slqs|dsqrd)$")) then
        width = math.min(1.5, 1500 / ctx.area.w)
        height = 1
    elseif class == "org.quickshell" and title:match("^cockpit%-qs") then
        width = 0.85
    end

    return { w = width, h = height }
end

local function sync(ctx)
    local present = {}
    local targets = {}
    state.windows = {}

    for _, target in ipairs(ctx.targets) do
        local id = target_id(target)
        present[id] = true
        targets[id] = target
        if target.window then
            local monitor = target.window.monitor
            local mode = monitor and monitor.mode
            state.windows[id] = tostring(target.window.address)
            if mode then
                state.viewport = { x = monitor.x, y = monitor.y, w = mode.width, h = mode.height }
            end
            if target.window.fullscreen_client == 2 then
                if not state.fullscreen[id] then
                    state.fullscreen[id] = fullscreen_geometry(ctx)
                    state.recenter = id
                end
            elseif state.fullscreen[id] then
                state.fullscreen[id] = nil
                state.recenter = id
            end
        end
    end

    for _, row in ipairs(state.rows) do
        for _, id in ipairs(row) do present[id] = nil end
    end

    local focused = active_id(ctx)
    local focused_row, focused_column
    if focused then
        focused_row, focused_column = locate(focused)
    end
    if not focused_row then
        local best_distance
        local viewport_x = ctx.area.x + ctx.area.w / 2
        local viewport_y = ctx.area.y + ctx.area.h / 2
        for row, items in ipairs(state.rows) do
            for column, id in ipairs(items) do
                local box = geometry(ctx, row, column, id)
                local dx = box.x + box.w / 2 - viewport_x
                local dy = box.y + box.h / 2 - viewport_y
                local distance = dx * dx + dy * dy
                if not best_distance or distance < best_distance then
                    focused_row, focused_column = row, column
                    best_distance = distance
                end
            end
        end
    end
    local fallback_row = shortest_row()
    for _, target in ipairs(ctx.targets) do
        local id = target_id(target)
        if present[id] then
            local row = fixture_row(target) or focused_row or fallback_row
            local column = #state.rows[row] + 1
            if focused_row == row then
                column = focused_column + 1
            end
            table.insert(state.rows[row], column, id)
            state.sizes[id] = initial_size(ctx, targets[id])
            present[id] = nil
        end
    end

    if focused then
        state.focused_row = locate(focused)
    end
    align_rows(ctx)
    return targets
end

local function canvas_size(ctx, id)
    local fullscreen = state.fullscreen[id]
    return fullscreen and fullscreen.size or state.sizes[id] or { w = TILE_WIDTH, h = default_height(ctx) }
end

local function row_width(ctx, row)
    local width = 0
    for column, id in ipairs(state.rows[row]) do
        if column > 1 then
            width = width + GAP
        end
        width = width + ctx.area.w * canvas_size(ctx, id).w
    end
    return width
end

align_rows = function(ctx)
    if not state.row_center then
        for row, items in ipairs(state.rows) do
            if #items > 0 then
                state.row_center = (state.row_offsets[row] or 0) + row_width(ctx, row) / 2
                break
            end
        end
    end
    if not state.row_center then
        return
    end
    for row, items in ipairs(state.rows) do
        if #items > 0 then
            state.row_offsets[row] = state.row_center - row_width(ctx, row) / 2
        end
    end
end

geometry = function(ctx, row, column, id)
    local size = canvas_size(ctx, id)
    local x = ctx.area.x + (state.row_offsets[row] or 0) - state.camera.x
    local y = ctx.area.y + GAP - state.camera.y + (row - 1) * (ctx.area.h - GAP)
    if state.fullscreen[id] then
        y = y - ctx.area.y + state.fullscreen[id].viewport.y
    end
    if state.focused_row and state.focused_row > 1 and row >= state.focused_row and state.viewport then
        y = y + math.max(0, ctx.area.y - state.viewport.y)
    end
    for previous = 1, column - 1 do
        local previous_id = state.rows[row][previous]
        x = x + ctx.area.w * canvas_size(ctx, previous_id).w + GAP
    end
    return {
        x = x,
        y = y,
        w = ctx.area.w * size.w,
        h = ctx.area.h * size.h,
    }
end

local function center(ctx, id)
    local row, column = locate(id)
    if not row then
        return
    end

    state.recenter = id
end

local function recalculate(ctx)
    prune_closed_windows()
    local window = ctx.targets[1] and ctx.targets[1].window
    if not select_workspace(window and window.workspace) then
        checkpoint.write(states)
        return
    end
    local targets = sync(ctx)
    local active = active_id(ctx)
    for row, items in ipairs(state.rows) do
        for column, id in ipairs(items) do
            if targets[id] then targets[id]:set_box(geometry(ctx, row, column, id)) end
        end
    end
    if state.recenter then
        if state.recenter == active then
            hl.dispatch(hl.dsp.layout("camera-center"))
        end
        state.recenter = nil
    end
    checkpoint.write(states)
end

local function focus_direction(ctx, direction)
    sync(ctx)
    local current = active_id(ctx)
    local source_row, source_column
    if current then
        source_row, source_column = locate(current)
    end
    if not source_row then
        return
    end

    local source = geometry(ctx, source_row, source_column, current)
    local source_x = source.x + source.w / 2
    local source_y = source.y + source.h / 2
    local best_id
    local best_score

    for row, items in ipairs(state.rows) do
        for column, id in ipairs(items) do
            if id ~= current then
                local box = geometry(ctx, row, column, id)
                local dx = box.x + box.w / 2 - source_x
                local dy = box.y + box.h / 2 - source_y
                local valid = (direction == "h" and row == source_row and column < source_column)
                    or (direction == "l" and row == source_row and column > source_column)
                    or (direction == "k" and row < source_row)
                    or (direction == "j" and row > source_row)
                if valid then
                    local primary = (direction == "h" or direction == "l") and math.abs(dx) or math.abs(dy)
                    local perpendicular = (direction == "h" or direction == "l") and math.abs(dy) or math.abs(dx)
                    local score = primary * primary + perpendicular * perpendicular * 2
                    if not best_score or score < best_score then
                        best_id = id
                        best_score = score
                    end
                end
            end
        end
    end

    if best_id then
        local targets = sync(ctx)
        local window = targets[best_id] and targets[best_id].window
        if window then
            state.focused_row = locate(best_id)
            hl.dispatch(hl.dsp.focus({ window = "address:" .. tostring(window.address) }))
        end
    end
end

local function move_direction(ctx, direction)
    sync(ctx)
    local id = active_id(ctx)
    local row, column
    if id then
        row, column = locate(id)
    end
    if not row then
        return
    end

    if direction == "h" or direction == "l" then
        local next_column = column + (direction == "h" and -1 or 1)
        if next_column >= 1 and next_column <= #state.rows[row] then
            state.rows[row][column], state.rows[row][next_column] = state.rows[row][next_column], state.rows[row][column]
            center(ctx, id)
        end
        return
    end

    local next_row = row + (direction == "k" and -1 or 1)
    if next_row < 1 then
        table.insert(state.rows, 1, {})
        table.insert(state.row_offsets, 1, 0)
        row = row + 1
        next_row = 1
    elseif next_row > #state.rows then
        table.insert(state.rows, {})
        table.insert(state.row_offsets, 0)
    end

    table.remove(state.rows[row], column)
    table.insert(state.rows[next_row], math.min(column, #state.rows[next_row] + 1), id)
    state.focused_row = next_row
    align_rows(ctx)
    center(ctx, id)
end

local function resize_direction(ctx, direction)
    sync(ctx)
    local id = active_id(ctx)
    local size = id and state.sizes[id]
    if not size then
        return
    end

    if direction == "h" or direction == "l" then
        size.w = math.max(0.2, math.min(1.5, size.w + (direction == "h" and -0.05 or 0.05)))
    else
        size.h = math.max(0.2, math.min(1.5, size.h + (direction == "j" and -0.05 or 0.05)))
    end
    align_rows(ctx)
    center(ctx, id)
end

local function toggle_widen(ctx)
    local targets = sync(ctx)
    local id = active_id(ctx)
    local size = id and state.sizes[id]
    if not size or not targets[id] then
        return
    end

    if state.widened[id] then
        size.w = state.widened[id]
        state.widened[id] = nil
    else
        state.widened[id] = size.w
        size.w = (ctx.area.w - GAP * 2) / ctx.area.w
    end
    align_rows(ctx)
    center(ctx, id)
end

hl.layout.register("canvas", {
    recalculate = recalculate,
    layout_msg = function(ctx, message)
        prune_closed_windows()
        local window = ctx.targets[1] and ctx.targets[1].window
        if not select_workspace(window and window.workspace) then return true end
        local command, arg1, arg2 = message:match("^(%S+)%s*(%S*)%s*(%S*)")
        if command == "focus" and arg1:match("^[hjkl]$") then
            focus_direction(ctx, arg1)
        elseif command == "move" and arg1:match("^[hjkl]$") then
            move_direction(ctx, arg1)
        elseif command == "resize" and arg1:match("^[hjkl]$") then
            resize_direction(ctx, arg1)
        elseif command == "move-row" and arg1:match("^[jk]$") then
            sync(ctx)
            local id = active_id(ctx)
            local row = id and locate(id)
            local target = row and row + (arg1 == "j" and 1 or -1) or nil
            if target and target >= 1 and target <= #state.rows then
                state.rows[row], state.rows[target] = state.rows[target], state.rows[row]
                state.focused_row = target
                center(ctx, id)
            end
        elseif command == "center" then
            local id = arg1 ~= "" and arg1 or active_id(ctx)
            if id and locate(id) then
                state.focused_row = locate(id)
                center(ctx, id)
                local targets = sync(ctx)
                for row, items in ipairs(state.rows) do
                    for column, target_id in ipairs(items) do
                        if targets[target_id] then targets[target_id]:set_box(geometry(ctx, row, column, target_id)) end
                    end
                end
            end
        elseif command == "recalculate" then
            recalculate(ctx)
        elseif command == "widen" then
            toggle_widen(ctx)
        elseif command == "reset" then
            state.camera.x = 0
            state.camera.y = 0
        else
            return "canvas: expected focus, move, move-row, resize, center, recalculate, widen, or reset"
        end
        checkpoint.write(states)
        return true
    end,
})

hl.on("window.active", function(window)
    if not window or window.floating or not is_canvas_workspace(window.workspace) then
        return
    end
    select_workspace(window.workspace)
    local row = locate(tostring(window.stable_id))
    if row and row ~= state.focused_row then
        hl.dispatch(hl.dsp.layout("recalculate"))
    end
    hl.dispatch(hl.dsp.layout("camera-center"))
end)

hl.on("window.close", function(window)
    if not window or not select_workspace(window.workspace) then return end
    local closing_state = state
    local id = tostring(window.stable_id)
    local row, column = locate(id)
    if not window.active or not row then
        forget(state, id)
        checkpoint.write(states)
        return
    end

    local next_id = column > 1 and state.rows[row][column - 1] or nil
    if not next_id then
        local best_score
        for candidate_row, items in ipairs(state.rows) do
            if candidate_row ~= row then
                for candidate_column, candidate_id in ipairs(items) do
                    local score = math.abs(candidate_row - row) * 1000 + math.abs(candidate_column - column)
                    if not best_score or score < best_score then
                        next_id = candidate_id
                        best_score = score
                    end
                end
            end
        end
    end
    if not next_id and column < #state.rows[row] then
        next_id = state.rows[row][column + 1]
    end

    local address = next_id and state.windows[next_id]
    forget(state, id)
    checkpoint.write(states)
    if address then
        hl.timer(function()
            closing_state.recenter = next_id
            hl.dispatch(hl.dsp.focus({ window = "address:" .. address }))
        end, { timeout = 1, type = "oneshot" })
    end
end)

hl.monitor({ output = "", mode = "preferred", position = "auto", scale = DECK_MODE and 1 or (REAL_MODE and "auto" or 1) })

if DECK_MODE then
    hl.monitor({ output = "eDP-1", mode = "800x1280@90", position = "0x0", scale = 1, transform = 3 })
elseif REAL_MODE then
    local monitors = {
        -- Hyprland requires integer logical dimensions; 1.75 is invalid at 3840x2400.
        { output = "eDP-1", mode = "3840x2400@120", position = "0x0", scale = 1.6666666666667 },
        { output = "desc:Dell Inc. DELL U2725QE G37YLF4", mode = "3840x2160@120", position = "-2560x0", scale = 1.5 },
        { output = "desc:Dell Inc. DELL P3425WE B94NY54", mode = "3440x1440@59.973", position = "-3440x-823", scale = 1 },
        { output = "desc:Dell Inc. DELL P3425WE 8Y8PY54", mode = "3440x1440@59.973", position = "-3440x-823", scale = 1 },
        { output = "desc:Dell Inc. DELL U2515H 9X2VY5840MWL", mode = "2560x1440@59.951", position = "-2560x0", scale = 1 },
        { output = "desc:Technical Concepts Ltd 27R83U X2414000823", mode = "3840x2160@144", position = "2304x0", scale = 1.5 },
        { output = "desc:Samsung Electric Company S34C65xV HNTY700216", mode = "3440x1440@59.973", position = "-3440x0", scale = 1 },
    }
    for _, monitor in ipairs(monitors) do
        hl.monitor(monitor)
    end
    hl.env("GTK_THEME", "", true)
    hl.env("FZF_DEFAULT_OPTS_FILE", "/home/daphen/.config/fzf/opts.conf")
    hl.env("FZF_DEFAULT_OPTS", "")
end
if REAL_MODE then
    hl.env("XCURSOR_THEME", "Adwaita")
    hl.env("XCURSOR_SIZE", "24")
end

local input = {
    follow_mouse = 0,
    touchpad = { natural_scroll = true },
}
if REAL_MODE and not DECK_MODE then
    input = {
        follow_mouse = 0,
        kb_file = "/home/daphen/.config/kanata/keymap.xkb",
        numlock_by_default = true,
        natural_scroll = true,
        touchpad = {
            disable_while_typing = true,
            natural_scroll = false,
            scroll_factor = 0.3,
            tap_to_click = true,
            tap_and_drag = false,
        },
    }
end

if DECK_MODE then
    hl.device({ name = "fts3528:00-2808:1015", output = "eDP-1", transform = 3 })
    input.kb_options = "fkeys:basic_13-24"
    input.invert_horizontal_scroll = false
    hl.device({
        name = "inputplumber-touchpad",
        natural_scroll = false,
        sensitivity = 0.0,
        scroll_factor = 3.0,
    })
end

hl.config({
    general = {
        layout = "lua:canvas",
        gaps_in = 0,
        gaps_out = 0,
        border_size = 2,
        col = {
            active_border = { colors = { "rgb(10100E)", "rgb(10100E)" }, angle = 180 },
            inactive_border = "rgb(3A3A3A)",
        },
    },
    decoration = {
        rounding = 10,
        active_opacity = 1,
        inactive_opacity = 1,
        shadow = {
            enabled = false,
            range = 30,
            offset = "0 0",
            color = 0x77000000,
        },
        blur = {
            enabled = true,
            passes = 2,
            size = 6,
            noise = 0.02,
            vibrancy = 0.1,
        },
    },
    animations = { enabled = true },
    misc = {
        disable_hyprland_logo = true,
        force_default_wallpaper = 0,
    },
    input = input,
    cursor = {
        no_warps = true,
        inactive_timeout = REAL_MODE and 1.5 or 0,
        hide_on_key_press = REAL_MODE,
    },
})

local theme_path = (os.getenv("XDG_CONFIG_HOME") or os.getenv("HOME") .. "/.config") .. "/hypr/theme.lua"
local theme_file = io.open(theme_path, "r")
if theme_file then
    theme_file:close()
    hl.config(dofile(theme_path))
end

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
            match = { title = "^quickshell$", xwayland = true },
            float = true,
            size = "monitor_w monitor_h",
            move = "0 0",
            border_size = 0,
            rounding = 0,
            no_anim = true,
        })
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
    floating_rule("mail", { class = "^org\\.quickshell$", title = "^mlqs$" }, "1700 1100")
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
end

hl.curve("canvasMotion", { type = "spring", mass = 1, stiffness = 1200, damping = 69.282 })
hl.curve("canvasFade", { type = "bezier", points = { { 0.2, 0.8 }, { 0.2, 1 } } })
hl.animation({ leaf = "windowsMove", enabled = true, speed = 2.5, spring = "canvasMotion" })
hl.animation({ leaf = "canvasCamera", enabled = true, speed = 2.5, spring = "canvasMotion" })
hl.animation({ leaf = "windowsIn", enabled = false })
hl.animation({ leaf = "fadeIn", enabled = true, speed = 5, bezier = "canvasFade" })

for _, direction in ipairs({ "h", "j", "k", "l" }) do
    hl.bind("SUPER + " .. direction, hl.dsp.layout("focus " .. direction))
    hl.bind("SUPER + SHIFT + " .. direction, hl.dsp.layout("move " .. direction))
    hl.bind("SUPER + CTRL + " .. direction, hl.dsp.layout("resize " .. direction))
end

local palette_tab_cycle_active = false
local palette_tab_cycle_output = ""
local function palette_tab_cycle(direction)
    return function()
        local window = hl.get_active_window()
        if not palette_tab_cycle_active then
            palette_tab_cycle_output = window and window.monitor and window.monitor.name or ""
        end
        palette_tab_cycle_active = true
        hl.exec_cmd(string.format("%spalette-shell-ipc tabCycle %d false %q",
            SCRIPTS, direction, palette_tab_cycle_output))
    end
end

local function finish_palette_tab_cycle()
    if not palette_tab_cycle_active then return end
    palette_tab_cycle_active = false
    palette_tab_cycle_output = ""
    hl.exec_cmd(SCRIPTS .. "palette-shell-ipc tabCycle 0 true ''")
end

local palette_tab_bindings = {
    hl.bind("CTRL + h", palette_tab_cycle(-1), { repeating = true }),
    hl.bind("CTRL + l", palette_tab_cycle(1), { repeating = true }),
}

hl.on("input.keyboard.key", function(keycode, _, state)
    if state == 0 and (keycode == 37 or keycode == 105) then finish_palette_tab_cycle() end
end)

local function set_palette_tab_bindings(window)
    local class = window and window.class or ""
    local enabled = class == "browser-personal" or class == "browser-work"
    for _, binding in ipairs(palette_tab_bindings) do binding:set_enabled(enabled) end
    if enabled then
        local profile = class == "browser-work" and "work" or "personal"
        hl.exec_cmd(string.format("%spalette-shell-ipc focusProfile %q", SCRIPTS, profile))
    end
end

set_palette_tab_bindings(hl.get_active_window())
hl.on("window.active", set_palette_tab_bindings)

hl.bind("ALT + CTRL + h", hl.dsp.layout("pan -120 0"), { repeating = true })
hl.bind("ALT + CTRL + l", hl.dsp.layout("pan 120 0"), { repeating = true })
hl.bind("ALT + CTRL + k", hl.dsp.layout("pan 0 -120"), { repeating = true })
hl.bind("ALT + CTRL + j", hl.dsp.layout("pan 0 120"), { repeating = true })
hl.bind("ALT + SHIFT + j", hl.dsp.layout("move-row j"))
hl.bind("ALT + SHIFT + k", hl.dsp.layout("move-row k"))
hl.bind("ALT + r", hl.dsp.layout("reset"))
hl.bind("SUPER + SHIFT + d", hl.dsp.exec_cmd(SCRIPTS .. "desktop-launch kitty"))
hl.bind("SUPER + CTRL + w", hl.dsp.window.close())
hl.bind("SUPER + TAB", hl.dsp.layout("overview"))
hl.bind("SUPER + CTRL + f", hl.dsp.layout("widen"))
hl.bind("SUPER + CTRL + SHIFT + f", hl.dsp.window.float({ action = "toggle" }))
hl.bind("SUPER + d", hl.dsp.exec_cmd(SCRIPTS .. "focus-kitty-cycle"))
hl.bind("SUPER + u", hl.dsp.focus({ monitor = "+1" }))
hl.bind("ALT + h", hl.dsp.focus({ monitor = "l" }))
hl.bind("ALT + j", hl.dsp.focus({ monitor = "d" }))
hl.bind("ALT + k", hl.dsp.focus({ monitor = "u" }))
hl.bind("ALT + l", hl.dsp.focus({ monitor = "r" }))
hl.bind("SUPER + CTRL + SHIFT + h", hl.dsp.window.move({ monitor = "l" }))
hl.bind("SUPER + CTRL + SHIFT + j", hl.dsp.window.move({ monitor = "d" }))
hl.bind("SUPER + CTRL + SHIFT + k", hl.dsp.window.move({ monitor = "u" }))
hl.bind("SUPER + CTRL + SHIFT + l", hl.dsp.window.move({ monitor = "r" }))
hl.bind("ALT + CTRL + SHIFT + h", hl.dsp.workspace.move({ monitor = "l" }))
hl.bind("ALT + CTRL + SHIFT + j", hl.dsp.workspace.move({ monitor = "d" }))
hl.bind("ALT + CTRL + SHIFT + k", hl.dsp.workspace.move({ monitor = "u" }))
hl.bind("ALT + CTRL + SHIFT + l", hl.dsp.workspace.move({ monitor = "r" }))
if not DECK_MODE then
    hl.bind("ALT + escape", hl.dsp.exec_cmd(SCRIPTS .. "session-exit"))
end

local deck_dictation_active = false
local deck_dictation_f9_down = false
local function stop_deck_dictation()
    if not deck_dictation_active then return end
    deck_dictation_active = false
    hl.exec_cmd("dbus-send --session --type=method_call --dest=com.openwhispr.App /com/openwhispr/App com.openwhispr.App.PttUp")
end

if DECK_MODE then
    hl.workspace_rule({ workspace = "name:gaming", layout = "dwindle" })
    hl.window_rule({
        name = "deck-big-picture-fullscreen",
        match = { class = "(?i)^steam$", title = "^Steam Big Picture Mode$" },
        fullscreen = true,
    })
    hl.window_rule({
        name = "deck-steam",
        match = {
            class = "(?i)^(steam|steam_app_[0-9]+)$",
            title = "negative:^Steam Input On-screen Keyboard$",
        },
        workspace = "name:gaming",
        sync_fullscreen = true,
    })
    hl.window_rule({
        name = "deck-game-fullscreen",
        match = { workspace = "name:gaming" },
        sync_fullscreen = true,
    })
    hl.window_rule({
        name = "deck-steam-keyboard",
        match = { class = "(?i)^steam$", title = "^Steam Input On-screen Keyboard$" },
        float = true,
        pin = true,
        no_initial_focus = true,
        no_blur = true,
        border_size = 0,
        no_shadow = true,
    })
    hl.on("workspace.active", function()
        hl.dispatch(hl.dsp.exec_cmd(SCRIPTS .. "deck-gaming-mode sync"))
    end)
    for _, event in ipairs({ "window.open", "window.close" }) do
        hl.on(event, function(window)
            if window.title == "Steam Input On-screen Keyboard" then
                hl.dispatch(hl.dsp.exec_cmd(SCRIPTS .. "deck-gaming-mode sync"))
            end
        end)
    end
    local steam_held = false
    hl.bind("F23", function() steam_held = false end, { dont_inhibit = true })
    hl.bind("F23", function()
        steam_held = true
        hl.dispatch(hl.dsp.exec_cmd("deck-gaming-mode return"))
    end, { long_press = true, dont_inhibit = true })
    hl.bind("F23", function()
        if not steam_held then hl.dispatch(hl.dsp.exec_cmd("deck-gaming-mode tap")) end
    end, { release = true, dont_inhibit = true })
    local radial_open, radial_outer, radial_kind = false, false, nil
    local radial_held = { false, false, false, false }
    local apps_held = { false, false, false, false }
    local radial_last_direction = 0
    local radial_release_timer
    local function cancel_radial_release()
        if radial_release_timer then
            radial_release_timer:set_enabled(false)
            radial_release_timer = nil
        end
    end
    local function set_radial_pointer_blocked(blocked)
        for _, name in ipairs({ "inputplumber-touchpad", "inputplumber-mouse", "extest-fake-device-1" }) do
            hl.device({ name = name, enabled = not blocked })
        end
        if blocked then hl.dispatch(hl.dsp.layout("pan-cancel")) end
    end
    local function radial_ipc(action, value)
        hl.exec_cmd(string.format("%spalette-shell-ipc radial %s %d ''", SCRIPTS, action, value or 0))
    end
    local function close_radial(action)
        if not radial_open then return end
        cancel_radial_release()
        set_radial_pointer_blocked(false)
        radial_ipc(action, 0)
        radial_open, radial_kind = false, nil
        radial_held = { false, false, false, false }
        apps_held = { false, false, false, false }
    end
    local function start_deck_dictation()
        if deck_dictation_active then return end
        close_radial("cancel")
        deck_dictation_active = true
        hl.exec_cmd("dbus-send --session --type=method_call --dest=com.openwhispr.App /com/openwhispr/App com.openwhispr.App.PttDown")
    end
    local function stick_direction(held)
        local x = (held[4] and 1 or 0) - (held[1] and 1 or 0)
        local y = (held[2] and 1 or 0) - (held[3] and 1 or 0)
        local directions = {["0,-1"]=0,["1,-1"]=1,["1,0"]=2,["1,1"]=3,["0,1"]=4,["-1,1"]=5,["-1,0"]=6,["-1,-1"]=7}
        return directions[x .. "," .. y]
    end
    local function update_radial_direction(held)
        local direction = stick_direction(held)
        if direction ~= nil then
            radial_last_direction = direction
            if radial_open then radial_ipc("direction", direction) end
        end
        return radial_last_direction
    end
    local function schedule_radial_release(held)
        cancel_radial_release()
        radial_release_timer = hl.timer(function()
            radial_release_timer = nil
            if radial_open and stick_direction(held) ~= nil then update_radial_direction(held) end
        end, { timeout = 25, type = "oneshot" })
    end
    local function radial_press(index)
        if deck_dictation_active or radial_kind == "apps" then return end
        cancel_radial_release()
        radial_held[index] = true
        if radial_open then
            if radial_kind == "browser" then update_radial_direction(radial_held) end
            return
        end
        local direction = update_radial_direction(radial_held)
        local window = hl.get_active_window()
        if window and (window.class == "browser-personal" or window.class == "browser-work") then
            radial_open, radial_kind = true, "browser"
            set_radial_pointer_blocked(true)
            hl.exec_cmd(string.format("%spalette-toggle %d", SCRIPTS, direction + (radial_outer and 8 or 0)))
        end
    end
    local function apps_radial_press(index)
        if deck_dictation_active then return end
        cancel_radial_release()
        apps_held[index] = true
        if radial_open and radial_kind == "browser" then
            if index == 1 then radial_ipc("step", -1)
            elseif index == 4 then radial_ipc("step", 1) end
            return
        end
        local direction = update_radial_direction(apps_held)
        if not radial_open then
            radial_open, radial_kind = true, "apps"
            set_radial_pointer_blocked(true)
            hl.exec_cmd(string.format("%spalette-toggle %d", SCRIPTS, 16 + direction + (radial_outer and 8 or 0)))
        end
    end
    for index, key in ipairs({ "F1", "F2", "F3", "F4" }) do
        hl.bind(key, function()
            if radial_open or not radial_outer or (key ~= "F1" and key ~= "F4") then return end
            local window = hl.get_active_window()
            if window and (window.class == "browser-personal" or window.class == "browser-work") then
                hl.dispatch(hl.dsp.send_shortcut({ mods = "ALT", key = key == "F1" and "Left" or "Right" }))
            end
        end)
        hl.bind("SUPER + " .. key, function() radial_press(index) end)
    end
    local function radial_outer_press()
        radial_outer = true
        if radial_open then radial_ipc("outer", 1) end
    end
    hl.bind("F11", radial_outer_press)
    hl.bind("SUPER + F11", radial_outer_press)
    hl.on("input.keyboard.key", function(keycode, _, key_state)
        if key_state == 0 then
            if keycode == 75 then deck_dictation_f9_down = false end
            if keycode == 75 or keycode == 133 then stop_deck_dictation() end
        end
        if keycode >= 67 and keycode <= 70 and key_state == 0 then
            radial_held[keycode - 66] = false
            if radial_kind == "browser" then schedule_radial_release(radial_held) end
        elseif keycode >= 191 and keycode <= 194 and key_state == 0 then
            apps_held[keycode - 190] = false
            if radial_kind == "apps" then schedule_radial_release(apps_held) end
        elseif keycode == 95 and key_state == 0 then
            radial_outer = false
            if radial_open then radial_ipc("outer", 0) end
        elseif keycode == 133 and key_state == 0 and radial_open then
            close_radial((radial_kind == "apps" or radial_outer) and "activate" or "finish")
        end
    end)
    local deck_directions = {
        F13 = "h",
        F14 = "j",
        F15 = "k",
        F16 = "l",
    }
    local deck_arrows = { h = "Left", j = "Down", k = "Up", l = "Right" }
    for key, direction in pairs(deck_directions) do
        hl.bind(key, function()
            if radial_open then
                if key == "F13" then radial_ipc("step", -1)
                elseif key == "F16" then radial_ipc("step", 1) end
                return
            end
            for _, layer in ipairs(hl.get_layers({ namespace = "qs-rounded-bar" })) do
                if layer.keyboard_interactivity ~= 0 then
                    hl.dispatch(hl.dsp.send_key_state({ mods = "", key = deck_arrows[direction], state = "down" }))
                    hl.dispatch(hl.dsp.send_key_state({ mods = "", key = deck_arrows[direction], state = "up" }))
                    return
                end
            end
            hl.dispatch(hl.dsp.layout("focus " .. direction))
        end, { repeating = true })
        local apps_index = ({ F13 = 1, F14 = 2, F15 = 3, F16 = 4 })[key]
        hl.bind("SUPER + " .. key, function() apps_radial_press(apps_index) end, { repeating = true })
        hl.bind("SHIFT + " .. key, hl.dsp.layout("move " .. direction), { repeating = true })
        hl.bind("CTRL + " .. key, hl.dsp.layout("resize " .. direction), { repeating = true })
    end
    for _, axis in ipairs({ "mouse_up", "mouse_down", "mouse_left", "mouse_right" }) do
        hl.bind("SUPER + " .. axis, function()
            if not radial_open then return { pass_event = true } end
        end)
    end
    hl.bind("F21", function()
        if radial_open then radial_ipc("delete", 0)
        else hl.dispatch(hl.dsp.layout("overview")) end
    end)
    hl.bind("F22", hl.dsp.exec_cmd("deck-osk-toggle"))
    hl.bind("Escape", function()
        for _, layer in ipairs(hl.get_layers({ namespace = "wvkbd" })) do
            if layer.mapped then
                hl.dispatch(hl.dsp.exec_cmd("pkill -USR1 -x wvkbd-mobintl"))
                return
            end
        end
        return { pass_event = true }
    end)
    hl.bind("F24", hl.dsp.exec_cmd("qs ipc call -- launcher toggle"))
    hl.bind("F10", hl.dsp.exec_cmd("qs ipc call -- controlCenter toggle"))
    hl.bind("SUPER + mouse:272", hl.dsp.exec_cmd("qs ipc call -- launcher toggle"))
    hl.bind("SUPER + F21", function()
        if radial_open then radial_ipc("delete", 0)
        elseif radial_outer then hl.dispatch(hl.dsp.layout("move k")) end
    end)
    hl.bind("SUPER + Escape", function()
        if radial_open then close_radial("cancel")
        elseif radial_outer then hl.dispatch(hl.dsp.layout("move l"))
        else hl.dispatch(hl.dsp.layout("resize l")) end
    end)
    hl.bind("SUPER + F22", function()
        if radial_open then return
        elseif radial_outer then hl.dispatch(hl.dsp.layout("move h"))
        else hl.dispatch(hl.dsp.layout("resize h")) end
    end, { repeating = true })
    hl.bind("F9", function()
        deck_dictation_f9_down = true
    end)
    hl.bind("SUPER + F9", function()
        deck_dictation_f9_down = true
        start_deck_dictation()
    end)
    hl.bind("code:133", function()
        if deck_dictation_f9_down then start_deck_dictation() end
    end, { ignore_mods = true })
    hl.bind("F12", function() end)
    hl.bind("SUPER + F12", function()
        if not radial_open and radial_outer then hl.dispatch(hl.dsp.window.close()) end
    end)
    hl.bind("SUPER + SPACE", hl.dsp.exec_cmd("qs ipc call -- launcher toggle"))
    hl.bind("SUPER + RETURN", function()
        if radial_open then close_radial("activate")
        elseif radial_outer then hl.dispatch(hl.dsp.layout("move j"))
        else hl.exec_cmd("qs ipc call -- launcher toggle") end
    end)
    hl.bind("XF86PowerOff", hl.dsp.exec_cmd("systemctl suspend"), { locked = true })
end

if REAL_MODE and not DECK_MODE then
    local scripts = SCRIPTS
    local function picker(name)
        return hl.dsp.exec_cmd("qs ipc call -- " .. name .. " toggle")
    end
    local function launch(command)
        return scripts .. "desktop-launch " .. command
    end
    local function bind_exec(key, command, options)
        hl.bind(key, hl.dsp.exec_cmd(command), options)
    end
    local function jump(selector, command, here)
        local flag = here and "--here " or ""
        return hl.dsp.exec_cmd(string.format("%sjump-or-exec %s%q %q", scripts, flag, selector, command))
    end

    hl.bind("SUPER + q", hl.dsp.exec_cmd(launch(scripts .. "browser-personal")))
    hl.bind("SUPER + w", hl.dsp.exec_cmd(launch(scripts .. "browser-work")))
    hl.bind("SUPER + SHIFT + q", hl.dsp.exec_cmd(launch(scripts .. "chromium-launch")))
    hl.bind("SUPER + SHIFT + w", hl.dsp.exec_cmd(launch(scripts .. "browser-work-new")))
    hl.bind("SUPER + c", jump("title:dsqrd", scripts .. "launch-discord-client"))
    hl.bind("SUPER + s", jump("Slack", "slack"))
    hl.bind("SUPER + SHIFT + s", jump("Slack", "slack"))
    hl.bind("SUPER + a", jump("spotify_player", "kitty --class spotify_player " .. scripts .. "spotify-player-launch"))
    hl.bind("SUPER + m", jump("title:mlqs", scripts .. "launch-mail-client", true))
    hl.bind("SUPER + SHIFT + g", jump("title:qstns", "/home/daphen/personal/qstns/run.sh", true))
    hl.bind("SUPER + g", jump("cockpit-nvim", "true"))
    hl.bind("SUPER + i", hl.dsp.exec_cmd(scripts .. "inbox-jump"))
    hl.bind("SUPER + v", hl.dsp.exec_cmd("dbus-send --session --type=method_call --dest=com.openwhispr.App /com/openwhispr/App com.openwhispr.App.PttDown"))
    hl.bind("SUPER + v", hl.dsp.exec_cmd("dbus-send --session --type=method_call --dest=com.openwhispr.App /com/openwhispr/App com.openwhispr.App.PttUp"), { release = true })
    hl.bind("SUPER + t", hl.dsp.exec_cmd(scripts .. "cockpit-rail-roster"))
    hl.bind("SUPER + y", hl.dsp.exec_cmd(scripts .. "agent-ask-or-cockpit"))
    hl.bind("SUPER + SHIFT + y", hl.dsp.exec_cmd(launch(scripts .. "cockpit-new")))
    hl.bind("SUPER + CTRL + y", hl.dsp.exec_cmd("notify-send -t 3000 'Orchestrator' 'handover starting…'; out=$($HOME/.local/bin/cockpit-handover 2>&1 | tail -3); notify-send -t 8000 'Orchestrator' \"$out\""))
    hl.bind("SUPER + o", hl.dsp.exec_cmd(scripts .. "cockpit-toggle"))
    hl.bind("SUPER + CTRL + g", hl.dsp.exec_cmd(launch("kitty --class lovable_picker " .. scripts .. "spawn-claude-session-picker")))
    hl.bind("SUPER + e", hl.dsp.exec_cmd(launch(scripts .. "spawn-terminal-with-yazi")))
    hl.bind("SUPER + b", jump("btop", "kitty --class btop btop", true))
    hl.bind("SUPER + SPACE", picker("launcher"))
    hl.bind("SUPER + RETURN", picker("launcher"))
    hl.bind("SUPER + r", picker("review-create"))
    hl.bind("SUPER + f", hl.dsp.exec_cmd(scripts .. "palette-toggle"))
    hl.bind("SUPER + CTRL + t", picker("cockpit"))
    hl.bind("SUPER + n", picker("notes"))
    hl.bind("SUPER + CTRL + v", picker("clipboard"))
    hl.bind("SUPER + CTRL + i", picker("timers"))
    hl.bind("SUPER + CTRL + b", picker("bluetooth"))
    hl.bind("SUPER + CTRL + n", picker("network"))
    hl.bind("SUPER + CTRL + p", picker("asus-profile"))
    hl.bind("SUPER + escape", hl.dsp.exec_cmd("qs ipc call -- notifications dismissAll"))
    hl.bind("F8", picker("emoji"), { locked = true })

    bind_exec("SUPER + p", launch("opqs-client"))
    bind_exec("SUPER + SHIFT + p", scripts .. "jump-or-exec 1password 1password")
    bind_exec("SUPER + CTRL + q", scripts .. "force-kill-focused")
    if not DECK_MODE then
        bind_exec("SUPER + CTRL + SHIFT + q", "swaylock")
    end
    bind_exec("SUPER + ALT + s", "pkill orca || exec orca", { locked = true })
    bind_exec("SUPER + SHIFT + m", "palette-ipc add-quickmark")
    bind_exec("SUPER + CTRL + SHIFT + t", "qs ipc call -- todos toggle")
    bind_exec("SUPER + SHIFT + n", "/home/daphen/.config/quickshell/scripts/notes-capture note")
    bind_exec("SUPER + CTRL + SHIFT + c", "qs ipc call -- color-format toggle")
    bind_exec("SUPER + CTRL + SHIFT + d", "f=$HOME/.config/quickshell/dnd; if [ -e \"$f\" ]; then rm -f \"$f\"; else mkdir -p \"$(dirname \"$f\")\" && touch \"$f\"; fi")
    bind_exec("SUPER + CTRL + SHIFT + b", scripts .. "waybar-theme --cycle")
    bind_exec("SUPER + CTRL + a", scripts .. "toggle-headphones")
    bind_exec("SUPER + SHIFT + r", scripts .. "record-toggle region")
    bind_exec("SUPER + CTRL + c", scripts .. "pick-color")
    bind_exec("SUPER + CTRL + SHIFT + e", scripts .. "screenshot-to-clipboard")
    bind_exec("SUPER + SHIFT + e", "f=\"$HOME/Pictures/Screenshots/Screenshot from $(date +'%Y-%m-%d %H-%M-%S').png\"; id=$(hyprctl -j activewindow | jq -er '.stableId') && grim -T \"$id\" - | tee \"$f\" | wl-copy && [ -s \"$f\" ] && notify-send -a Screenshot Screenshot 'Copied to clipboard'")
    bind_exec("SUPER + CTRL + e", "o=$(hyprctl -j monitors | jq -r '.[] | select(.focused).name'); grim -o \"$o\" - | tee \"$HOME/Pictures/Screenshots/Screenshot from $(date +'%Y-%m-%d %H-%M-%S').png\" | wl-copy")

    bind_exec("XF86AudioRaiseVolume", "wpctl set-mute @DEFAULT_AUDIO_SINK@ 0 && wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+", { locked = true, repeating = true })
    bind_exec("XF86AudioLowerVolume", "wpctl set-mute @DEFAULT_AUDIO_SINK@ 0 && wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-", { locked = true, repeating = true })
    bind_exec("XF86AudioMute", "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle", { locked = true })
    bind_exec("XF86AudioMicMute", scripts .. "toggle-mic", { locked = true })
    bind_exec("XF86WebCam", scripts .. "toggle-camera", { locked = true })
    bind_exec("XF86MonBrightnessUp", scripts .. "brightness-throttled 5%+", { locked = true, repeating = true })
    bind_exec("XF86MonBrightnessDown", scripts .. "brightness-throttled 5%-", { locked = true, repeating = true })
    bind_exec("XF86KbdBrightnessUp", "asusctl leds next", { locked = true })
    bind_exec("XF86KbdBrightnessDown", "asusctl leds prev", { locked = true })
    bind_exec("XF86KbdLightOnOff", "asusctl leds next", { locked = true })
    bind_exec("F1", "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle", { locked = true })
    bind_exec("F2", "wpctl set-mute @DEFAULT_AUDIO_SINK@ 0 && wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-", { locked = true, repeating = true })
    bind_exec("F3", "wpctl set-mute @DEFAULT_AUDIO_SINK@ 0 && wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+", { locked = true, repeating = true })
    bind_exec("F4", "brightnessctl --device='*kbd_backlight' set 33%+", { locked = true, repeating = true })
    bind_exec("F5", scripts .. "brightness-throttled 5%-", { locked = true, repeating = true })
    bind_exec("F6", scripts .. "brightness-throttled 5%+", { locked = true, repeating = true })
    bind_exec("F9", scripts .. "toggle-mic", { locked = true })
    bind_exec("F10", scripts .. "toggle-camera", { locked = true })
    bind_exec("XF86AudioPlay", "playerctl play-pause", { locked = true })
    bind_exec("XF86AudioPause", "playerctl play-pause", { locked = true })
    bind_exec("XF86AudioNext", "playerctl next", { locked = true })
    bind_exec("XF86AudioPrev", "playerctl previous", { locked = true })
end

hl.bind("Super_L", function()
    hl.dispatch(hl.dsp.layout("pan-end"))
end, { release = true, ignore_mods = true })
hl.bind("Super_R", hl.dsp.layout("pan-end"), { release = true, ignore_mods = true })

local overview_timer
hl.gesture({
    fingers = 3,
    direction = "swipe",
    action = {
        start = function()
            hl.dispatch(hl.dsp.layout("pan-begin"))
            overview_timer = hl.timer(function()
                overview_timer = nil
                hl.dispatch(hl.dsp.layout("pan-overview"))
            end, { timeout = 350, type = "oneshot" })
        end,
        update = function(e)
            hl.dispatch(hl.dsp.layout(string.format("pan %.6f %.6f", e.delta.x * PAN_GAIN, e.delta.y * PAN_GAIN)))
        end,
        finish = function()
            if overview_timer then
                overview_timer:set_enabled(false)
                overview_timer = nil
            end
            hl.dispatch(hl.dsp.layout("pan-end"))
        end,
    },
})

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
            hl.dispatch(hl.dsp.cursor.move({ x = target.x + target.mode.width / 2, y = target.y + target.mode.height / 2 }))
        end
        local startup = {
            "sh -c 'dbus-update-activation-environment --systemd WAYLAND_DISPLAY DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE && systemctl --user start nixos-fake-graphical-session.target'",
            SCRIPTS .. "start-quickshell-desktop >> /tmp/hyprland-quickshell-main.log 2>&1",
            "mutagen daemon start",
            "bash /home/daphen/.config/kanata/start-kanata.sh",
            "wl-clip-persist --clipboard regular",
            "systemd-run --user --collect --unit=clipse-image-session --property=Restart=always --property=RestartSec=1 wl-paste --type image/png --watch clipse --wl-store",
            "systemd-run --user --collect --unit=clipse-text-session --property=Restart=always --property=RestartSec=1 wl-paste --type text --watch clipse --wl-store",
            "swayidle -w timeout 300 " .. SCRIPTS .. "set-presence idle resume " .. SCRIPTS .. "set-presence active",
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
            hl.exec_cmd(string.format("kitty --class=hypr-canvas-fixture --title='%s' sh -c 'exec sleep infinity'", title))
        end
    end
end)
if not DECK_MODE then
    pcall(require, "/home/daphen/.config/hypr/openwhispr-binds.lua")
end
