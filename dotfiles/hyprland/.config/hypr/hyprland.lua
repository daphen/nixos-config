---@diagnostic disable-next-line: undefined-global
local hl = hl

local REAL_MODE = os.getenv("HYPR_CANVAS_REAL") == "1"
local PROFILE = os.getenv("HYPR_CANVAS_PROFILE") or "workstation"
local DECK_MODE = PROFILE == "deck"
local SCRIPTS = os.getenv("HYPR_SCRIPTS") or "/home/daphen/.config/hypr/scripts/"
local ROW_COUNT = 3
local OUTER_GAP = 24
local INNER_GAP = 64
local TILE_WIDTH = 0.9
local PAN_GAIN = 8.0

local checkpoint = require("canvas-state")
local states = checkpoint.read()
local state

local function select_workspace(workspace)
	if not workspace then
		return false
	end
	local key = workspace.addressable_name
	if not states[key] then
		states[key] = {
			camera = { x = 0, y = 0 },
			rows = { {}, {}, {} },
			row_offsets = { 0, 0, 0 },
			sizes = {},
			fullscreen = {},
			widened = {},
		}
	end
	state = states[key]
	state.windows = state.windows or {}
	return true
end

local function forget(saved, id)
	for _, row in ipairs(saved.rows) do
		for i = #row, 1, -1 do
			if row[i] == id then
				table.remove(row, i)
			end
		end
	end
	saved.sizes[id], saved.fullscreen[id], saved.widened[id] = nil, nil, nil
	if saved.windows then
		saved.windows[id] = nil
	end
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
			if live[id] ~= key then
				forget(saved, id)
			end
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
	return (ctx.area.h - OUTER_GAP * 2) / ctx.area.h
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

	if
		class:match("^(kitty|claude|lovable_deps|lovable_devenv|browser%-work|spotify_player|vesktop|Slack)$")
		or (class == "org.quickshell" and title:match("^(slqs|dsqrd)$"))
	then
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
		for _, id in ipairs(row) do
			present[id] = nil
		end
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
			width = width + INNER_GAP
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
	local y = ctx.area.y + OUTER_GAP - state.camera.y - (state.keyboard_offset or 0) + (row - 1) * (ctx.area.h - OUTER_GAP * 2 + INNER_GAP)
	if state.fullscreen[id] then
		y = y - ctx.area.y + state.fullscreen[id].viewport.y
	end
	if state.focused_row and state.focused_row > 1 and row >= state.focused_row and state.viewport then
		y = y + math.max(0, ctx.area.y - state.viewport.y)
	end
	for previous = 1, column - 1 do
		local previous_id = state.rows[row][previous]
		x = x + ctx.area.w * canvas_size(ctx, previous_id).w + INNER_GAP
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
			if targets[id] then
				targets[id]:set_box(geometry(ctx, row, column, id))
			end
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
			state.rows[row][column], state.rows[row][next_column] =
				state.rows[row][next_column], state.rows[row][column]
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
		size.w = (ctx.area.w - OUTER_GAP * 2) / ctx.area.w
	end
	align_rows(ctx)
	center(ctx, id)
end

hl.layout.register("canvas", {
	recalculate = recalculate,
	layout_msg = function(ctx, message)
		prune_closed_windows()
		local window = ctx.targets[1] and ctx.targets[1].window
		if not select_workspace(window and window.workspace) then
			return true
		end
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
						if targets[target_id] then
							targets[target_id]:set_box(geometry(ctx, row, column, target_id))
						end
					end
				end
			end
		elseif command == "recalculate" then
			recalculate(ctx)
		elseif command == "widen" then
			toggle_widen(ctx)
		elseif command == "keyboard" then
			local targets = sync(ctx)
			state.keyboard_offset = (state.keyboard_offset or 0) == 0 and 280 or 0
			for row, items in ipairs(state.rows) do
				for column, id in ipairs(items) do
					if targets[id] then
						targets[id]:set_box(geometry(ctx, row, column, id))
					end
				end
			end
		elseif command == "reset" then
			state.camera.x = 0
			state.camera.y = 0
		else
			return "canvas: expected focus, move, move-row, resize, center, recalculate, widen, keyboard, or reset"
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
	if not window or not select_workspace(window.workspace) then
		return
	end
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

local module_context = {
	hl = hl,
	REAL_MODE = REAL_MODE,
	DECK_MODE = DECK_MODE,
	SCRIPTS = SCRIPTS,
	ROW_COUNT = ROW_COUNT,
	PAN_GAIN = PAN_GAIN,
	is_canvas_workspace = is_canvas_workspace,
}

for _, name in ipairs({
	"monitors",
	"input",
	"appearance",
	"windowrules",
	"animations",
	"binds",
	"autostart",
}) do
	require("modules." .. name)(module_context)
end
