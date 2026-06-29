--[[
plan — manage plan-ticket artifacts (.plans/<ticket>.md) inside nvim.

The agent spits out the full plan; this is where you MANAGE it without going back
to the agent: jump to the files it names, resolve decision points, and approve
(flip draft -> planned, which unlocks `--go`).

Parsing is deliberately loose — it keys off the template's markdown markers
(`> Status:`, `### D`, `**Your call:**`, table rows), so reworded sections don't
break it. Watches .plans/ with its own fs_event because the gitignored dir never
reaches the file-watcher's git-derived watch set.
]]

local M = {}

local ns = vim.api.nvim_create_namespace("plan_steps")

local state = {
	root = nil,
	plan_path = nil,
	status = nil,
	progress = nil,
	watcher = nil,
	file_watchers = {},
	steps_buf = nil,
	steps_win = nil,
	steps_prev_win = nil,
	steps_paths = {},
}

-- Assigned lower down; forward-declared so watch()'s closure captures the upvalue.
local arm_surface_watches, render_steps

local function git_root()
	local out = vim.fn.systemlist({ "git", "-C", vim.fn.getcwd(), "rev-parse", "--show-toplevel" })
	if vim.v.shell_error ~= 0 or #out == 0 then return nil end
	return out[1]
end

-- Vault when present (durable, synced by notes-cli, searchable via notes-memory);
-- else the worktree's .plans/ (lovbox sandboxes have no vault). Surface-area paths
-- still resolve against the cwd's git root, so goto_file works wherever the plan lives.
local function plans_dir(root)
	if vim.fn.isdirectory(vim.fn.expand("~/personal/notes/storage")) == 1 then
		return vim.fn.expand("~/personal/notes/storage/plans")
	end
	return (root or state.root or git_root() or vim.fn.getcwd()) .. "/.plans"
end

local function list_plans(root)
	local res = {}
	local ok, entries = pcall(vim.fn.readdir, plans_dir(root))
	if not ok then return res end
	for _, name in ipairs(entries) do
		if name:match("%.md$") then table.insert(res, plans_dir(root) .. "/" .. name) end
	end
	table.sort(res, function(a, b)
		local sa, sb = vim.uv.fs_stat(a), vim.uv.fs_stat(b)
		return (sa and sa.mtime.sec or 0) > (sb and sb.mtime.sec or 0)
	end)
	return res
end

local function read_status()
	if not state.plan_path then return end
	local ok, lines = pcall(vim.fn.readfile, state.plan_path)
	if not ok then return end
	for _, line in ipairs(lines) do
		local s = line:match("^> Status:%s*`([%w]+)`")
		if s then state.status = s; return end
	end
end

-- progress.json is the agent's live feed during --go/--reconcile: per-file status
-- (pending|touched|done), an optional `note` (what it actually did / why skipped),
-- and the phase. Read alongside the plan; drives the statusline and the panel.
local function read_progress()
	state.progress = nil
	if not state.plan_path then return end
	local pj = state.plan_path:gsub("%.md$", ".progress.json")
	local ok, content = pcall(vim.fn.readfile, pj)
	if not ok then return end
	local ok2, data = pcall(vim.json.decode, table.concat(content, "\n"))
	if ok2 and type(data) == "table" then state.progress = data end
end

-- lualine component: require("plan-nvim").statusline()
function M.statusline()
	local p = state.progress
	if p and (p.phase == "implementing" or p.phase == "reconciled") then
		-- A planned file is "resolved" when it's done OR deliberately skipped (left
		-- pending with a note explaining no change was needed). The count is resolved/
		-- total so a finished plan reads N/N even when some files needed no change —
		-- not a misleading "6/8" next to the ✓.
		local total, resolved, touched = 0, 0, 0
		for _, f in ipairs(p.planned or {}) do
			total = total + 1
			if f.status == "done" then resolved = resolved + 1
			elseif f.status == "touched" then touched = touched + 1
			elseif f.note and f.note ~= "" then resolved = resolved + 1 end
		end
		local mark
		if p.phase == "reconciled" then mark = "✓"
		elseif total > 0 and resolved == total then mark = "●"
		elseif resolved + touched > 0 then mark = "◐"
		else mark = "○" end
		return string.format(" %s %s %d/%d", p.ticket or "plan", mark, resolved, total)
	end
	if not state.status then return "" end
	local icon = state.status == "planned" and "" or "" -- planned vs draft
	return icon .. " plan:" .. state.status
end

-- own fs_event on .plans/ so status (and a future review overlay) refresh when
-- the agent rewrites the sidecars during --go / --reconcile.
local function watch()
	if state.watcher then pcall(function() state.watcher:close() end) end
	local h = vim.uv.new_fs_event()
	if not h then return end
	state.watcher = h
	pcall(function()
		h:start(plans_dir(), {}, vim.schedule_wrap(function(err)
			if err then return end
			read_status()
			read_progress()
			pcall(vim.cmd, "checktime") -- reload the plan buffer when the agent rewrites it (answers, --finalize)
			if state.progress and state.progress.phase == "implementing" then
				arm_surface_watches(state.root) -- surface area can grow (unplanned files)
			end
			if state.steps_buf and vim.api.nvim_buf_is_valid(state.steps_buf)
				and state.steps_win and vim.api.nvim_win_is_valid(state.steps_win) then
				render_steps(state.steps_buf)
			end
			pcall(function() require("plan-nvim.review").refresh() end)
		end))
	end)
end

local function open_path(path)
	state.root = git_root()
	state.plan_path = path
	vim.cmd("edit " .. vim.fn.fnameescape(path))
end

function M.open(ticket)
	local root = git_root()
	if not root then vim.notify("plan: not in a git repo", vim.log.levels.WARN); return end
	state.root = root
	local plans = list_plans(root)
	if #plans == 0 then vim.notify("plan: no .plans/*.md found", vim.log.levels.WARN); return end
	if ticket and ticket ~= "" then
		for _, p in ipairs(plans) do
			if p:lower():find(ticket:lower(), 1, true) then open_path(p); return end
		end
		vim.notify("plan: no plan matching " .. ticket, vim.log.levels.WARN)
	elseif #plans == 1 then
		open_path(plans[1])
	else
		vim.ui.select(plans, {
			prompt = "Open plan:",
			format_item = function(p) return vim.fn.fnamemodify(p, ":t") end,
		}, function(choice) if choice then open_path(choice) end end)
	end
end

-- A surface-area table row carries the full repo-relative path in its first cell.
local function path_on_line(line)
	if line:match("^%s*|") then
		local cell = line:match("^%s*|%s*([^|]-)%s*|")
		if cell then
			cell = cell:gsub("`", "")
			if cell:match("/") or cell:match("%.%w+$") then return cell end
		end
		return nil
	end
	return line:match("([%w%._%-/]+%.[%w]+)")
end

function M.goto_file()
	local rel = path_on_line(vim.api.nvim_get_current_line())
	if not rel then vim.notify("plan: no file path on this line", vim.log.levels.INFO); return end
	local root = state.root or git_root() or vim.fn.getcwd()
	local abs = rel:match("^/") and rel or (root .. "/" .. rel)
	local tag = vim.uv.fs_stat(abs) and "" or "  (new — planned)"
	vim.notify("plan: " .. rel .. tag)
	vim.cmd("vsplit " .. vim.fn.fnameescape(abs))
end

-- Resolve the decision block enclosing the cursor: pick an option (or custom)
-- and write it into the block's "Your call:" line.
function M.resolve_decision()
	local buf = vim.api.nvim_get_current_buf()
	local cur = vim.api.nvim_win_get_cursor(0)[1]
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

	local start_ln
	for i = cur, 1, -1 do
		if lines[i]:match("^### D") then start_ln = i; break end
		if lines[i]:match("^## ") then break end
	end
	if not start_ln then vim.notify("plan: cursor is not in a decision block", vim.log.levels.INFO); return end

	local end_ln = #lines
	for i = start_ln + 1, #lines do
		if lines[i]:match("^#") then end_ln = i - 1; break end
	end

	local options, call_ln = {}, nil
	for i = start_ln, end_ln do
		local letter, desc = lines[i]:match("^%-%s*%*%*(%w)%*%*%s*(.*)")
		if letter then table.insert(options, { letter = letter, label = letter .. " — " .. (desc or "") }) end
		if lines[i]:match("%*%*Your call:%*%*") then call_ln = i end
	end
	if not call_ln then vim.notify("plan: no 'Your call:' line in this block", vim.log.levels.INFO); return end

	local choices = {}
	for _, o in ipairs(options) do table.insert(choices, o.label) end
	table.insert(choices, "Custom…")
	vim.ui.select(choices, { prompt = "Resolve decision:" }, function(choice, idx)
		if not choice then return end
		local value
		if idx and idx <= #options then
			value = options[idx].letter
		else
			value = vim.fn.input("Your call: ")
			if value == "" then return end
		end
		vim.api.nvim_buf_set_lines(buf, call_ln - 1, call_ln, false, { "- **Your call:** " .. value })
		vim.cmd("silent write")
	end)
end

local function flip_progress_phase(phase)
	if not state.plan_path then return end
	local pj = state.plan_path:gsub("%.md$", ".progress.json")
	if not vim.uv.fs_stat(pj) then return end
	local ok, content = pcall(vim.fn.readfile, pj)
	if not ok then return end
	local txt = table.concat(content, "\n")
	txt = txt:gsub('("phase"%s*:%s*")[%w]+(")', "%1" .. phase .. "%2", 1)
	vim.fn.writefile(vim.split(txt, "\n"), pj)
end

-- Gate: refuse to approve while any decision is unresolved; jump to the first.
function M.approve()
	local buf = vim.api.nvim_get_current_buf()
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	for i, l in ipairs(lines) do
		if l:match("%*%*Your call:%*%*") and l:match("_%(unresolved%)_") then
			vim.api.nvim_win_set_cursor(0, { i, 0 })
			vim.notify("plan: decision still unresolved (line " .. i .. ")", vim.log.levels.WARN)
			return
		end
	end
	for i, l in ipairs(lines) do
		if l:match("^> Status:%s*`draft`") then
			vim.api.nvim_buf_set_lines(buf, i - 1, i, false, { (l:gsub("`draft`", "`planned`", 1)) })
			break
		end
	end
	vim.cmd("silent write")
	state.status = "planned"
	flip_progress_phase("planned")
	vim.notify("plan: approved — status planned. `--go` is unlocked.")
end

-- Multi-line compose float (styled). on_submit(text) fires on send; cancel
-- discards. Type in insert; <C-s> sends; <Esc> to normal then <CR> sends, q cancels.
local function compose(title, on_submit)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "markdown"
	local width = math.min(76, vim.o.columns - 8)
	local height = 5
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.floor((vim.o.lines - height) / 2 - 1),
		col = math.floor((vim.o.columns - width) / 2),
		style = "minimal",
		border = "rounded",
		title = " " .. title .. "  ·  ⏎ send · q cancel ",
		title_pos = "center",
	})
	vim.wo[win].wrap = true
	vim.cmd("startinsert")
	local done = false
	local function finish(submit)
		if done then return end
		done = true
		local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
		text = text:gsub("^%s+", ""):gsub("%s+$", "")
		if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
		if submit and text ~= "" then on_submit(text) end
	end
	local o = { buffer = buf, nowait = true, silent = true }
	vim.keymap.set("n", "<CR>", function() finish(true) end, o)
	vim.keymap.set("i", "<C-s>", function() finish(true) end, o)
	vim.keymap.set("n", "q", function() finish(false) end, o)
	vim.keymap.set("n", "<Esc>", function() finish(false) end, o)
end

-- Render multi-line text as a markdown blockquote tagged with an emoji on line 1.
local function quote_block(emoji, text)
	local out = {}
	for i, line in ipairs(vim.split(text, "\n", { plain = true })) do
		out[#out + 1] = "> " .. (i == 1 and (emoji .. " ") or "") .. line
	end
	return out
end

-- A blockquote inserted inside a table or fenced code block breaks it. If `row`
-- lands in one, advance to the line after that block so the note/question sits
-- below it instead of splitting it.
local function safe_anchor(row)
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	if (lines[row] or ""):match("^%s*|") then
		while lines[row + 1] and lines[row + 1]:match("^%s*|") do row = row + 1 end
		return row
	end
	local fenced = false
	for i = 1, row do
		if (lines[i] or ""):match("^%s*```") then fenced = not fenced end
	end
	if fenced then
		for i = row + 1, #lines do
			if (lines[i] or ""):match("^%s*```") then return i end
		end
	end
	return row
end

local function insert_after(row, lines)
	row = safe_anchor(row)
	local block = { "" }
	vim.list_extend(block, lines)
	vim.api.nvim_buf_set_lines(0, row, row, false, block)
	vim.cmd("silent write")
end

-- The worktree bound to this plan, read from its `worktree: <branch>` header — NOT
-- the nvim cwd (plans live in the vault, so cwd is usually not a worktree). Strips
-- the daphen/ branch prefix to the wt-send short name; nil for non-worktree branches.
local function plan_worktree()
	-- Join the header region first: mdformat (--wrap) can split `worktree:` from
	-- its `value` across lines, which a per-line match would miss. Strip blockquote
	-- markers so the wrapped pieces sit adjacent, then match.
	local hdr = table.concat(vim.api.nvim_buf_get_lines(0, 0, 12, false), " "):gsub(">%s*", " ")
	local b = hdr:match("worktree:%s*`([^`]+)`")
	if not b then return nil end
	return b:match("^daphen/(.+)") or b
end

-- Ask the plan's worktree claude to answer the open questions inline. wt-send types
-- + submits into that running TUI; answers land back in the file (watcher reloads).
local function dispatch_questions()
	local name = plan_worktree()
	if not name or name == "main" then
		vim.notify("plan: question saved — no worktree session bound to this plan", vim.log.levels.INFO)
		return
	end
	local msg = ("Answer the open `> ❓` questions in %s — write each answer inline "
		.. "directly below its question as `> 💬 <answer>`, reading the repo as needed. "
		.. "Don't change code."):format(state.plan_path or "the open plan")
	vim.system({ "wt-send", "--wait", "8", name, msg })
	vim.notify("plan: dispatched to the " .. name .. " session — answers land inline")
end

-- emoji ❓ dispatches to the plan's worktree agent, 📝 is a local note. The block is
-- anchored after `anchor` — for visual variants that's the selection end, so it sits
-- right under the lines it's about (position carries the context; no quoting needed).
local function annotate(title, emoji, anchor, dispatch)
	compose(title, function(text)
		insert_after(anchor, quote_block(emoji, text))
		if dispatch then dispatch_questions() end
	end)
end

function M.add_note()
	annotate("📝 note", "📝", vim.api.nvim_win_get_cursor(0)[1], false)
end

function M.ask()
	annotate("❓ ask the agent", "❓", vim.api.nvim_win_get_cursor(0)[1], true)
end

-- Visual variants: the x-mode maps press <Esc> first, so '> holds the selection end.
function M.add_note_visual()
	annotate("📝 note on selection", "📝", vim.fn.line("'>"), false)
end

function M.ask_visual()
	annotate("❓ ask about selection", "❓", vim.fn.line("'>"), true)
end

-- Dispatch /plan-ticket --finalize to the plan's worktree claude: bake resolved
-- decisions into directives, fold notes, strip the Q&A. The cleaned plan reloads
-- via the watcher (checktime).
function M.finalize()
	for _, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
		if l:match("%*%*Your call:%*%*") and l:match("_%(unresolved%)_") then
			vim.notify("plan: resolve all decisions before finalizing", vim.log.levels.WARN)
			return
		end
	end
	local name = plan_worktree()
	if not name or name == "main" then
		vim.notify("plan: no worktree session bound — run /plan-ticket --finalize there", vim.log.levels.INFO)
		return
	end
	local ticket = vim.fn.fnamemodify(state.plan_path or "", ":t:r")
	vim.system({ "wt-send", "--wait", "8", name, "/plan-ticket --finalize " .. ticket })
	vim.notify("plan: dispatched --finalize to the " .. name .. " session")
end

-- The plugin's own fs_event watches the vault (where plan + progress.json live).
-- During --go the *code* changes in the worktree, which that watcher never sees, so
-- arm a second set of watches on the surface-area files' parent dirs — bounded to the
-- containment boundary — firing checktime so open code buffers reload as the agent
-- writes them. Parent dirs (not files) so newly-created files are caught too.
arm_surface_watches = function(root)
	for _, h in ipairs(state.file_watchers) do pcall(function() h:close() end) end
	state.file_watchers = {}
	if not root or not state.progress then return end
	local dirs, seen = {}, {}
	local function add(file)
		local dir = vim.fn.fnamemodify(root .. "/" .. file, ":h")
		if not seen[dir] and vim.fn.isdirectory(dir) == 1 then
			seen[dir] = true
			table.insert(dirs, dir)
		end
	end
	for _, f in ipairs(state.progress.planned or {}) do add(f.file) end
	for _, f in ipairs(state.progress.unplanned or {}) do add(f.file) end
	for _, dir in ipairs(dirs) do
		local h = vim.uv.new_fs_event()
		if h then
			pcall(function()
				h:start(dir, {}, vim.schedule_wrap(function(err)
					if not err then pcall(vim.cmd, "checktime") end
				end))
			end)
			table.insert(state.file_watchers, h)
		end
	end
end

-- Pull the human-language scaffolding from the plan markdown: the ◆ flow steps (the
-- narrative of the work) and the surface-area "why" per file. Read from the file, not
-- the buffer — the panel can be opened from a code buffer, not just the plan.
local function parse_plan()
	local res = { flow = {}, why = {} }
	if not state.plan_path then return res end
	local ok, lines = pcall(vim.fn.readfile, state.plan_path)
	if not ok then return res end
	local in_flow, cur = false, nil
	local function flush()
		if cur and cur:find("◆") then
			local s = cur:gsub("%*%*", ""):gsub("^%s*%d+%.%s*", "")
			local title = s:match("◆%s*(.-)%s*—") or s:match("◆%s*(.-)%s*_%(files") or s:match("◆%s*(.+)")
			if title then
				title = title:gsub("%s+$", "")
				if #title > 100 then -- break on a space so we never split a word or multibyte glyph
					title = (title:sub(1, 100):match("^(.*)%s%S*$") or title:sub(1, 99)) .. "…"
				end
				table.insert(res.flow, title)
			end
		end
		cur = nil
	end
	for _, l in ipairs(lines) do
		if l:match("^## ") then
			if in_flow then flush() end
			in_flow = l:match("^##%s+The flow") ~= nil
		elseif in_flow then
			if l:match("^%s*%d+%.") then
				flush()
				cur = l
			elseif cur and l:match("%S") then
				cur = cur .. " " .. l:gsub("^%s+", "")
			end
		end
		if l:match("^%s*|") then
			local cells = vim.split(l, "|")
			if #cells >= 4 then
				local file = (vim.trim(cells[2]):gsub("`", ""))
				if (file:match("/") or file:match("%.%w+$")) and file ~= "File" then
					res.why[file] = vim.trim(cells[4])
				end
			end
		end
	end
	if in_flow then flush() end
	return res
end

-- Hard-wrap to `width` columns on word boundaries (never mid-word): the first line
-- gets `lead`, continuation lines `indent`, so wrapped text hangs under lead's text.
-- Done here rather than via 'breakindent' because the float doesn't honor it.
local function wrap(text, lead, indent, width)
	local out, line, prefix = {}, "", lead
	local cap = function(pfx) return math.max(20, width - vim.fn.strdisplaywidth(pfx)) end
	local avail = cap(lead)
	for word in text:gmatch("%S+") do
		if line == "" then
			line = word
		elseif vim.fn.strdisplaywidth(line .. " " .. word) <= avail then
			line = line .. " " .. word
		else
			out[#out + 1] = prefix .. line
			prefix, avail = indent, cap(indent)
			line = word
		end
	end
	if line ~= "" then out[#out + 1] = prefix .. line end
	if #out == 0 then out[1] = lead end
	return out
end

-- Action icons (Nerd Font): plus = new file · pencil = changed · feather = light
-- touch. Built via nr2char so the source stays plain ASCII.
local function action_icon(a)
	if a == "create" then return vim.fn.nr2char(0xf067) end
	if a == "touch" then return vim.fn.nr2char(0xf52d) end
	return vim.fn.nr2char(0xf040)
end

local function action_hl(a)
	if a == "create" then return "PlanActionCreate" end -- green
	if a == "touch" then return "PlanActionTouch" end   -- yellow
	return "PlanActionModify"                            -- orange
end

-- Action-icon colors pulled from the active theme's exported palette
-- (vim.g.theme_palette, set by the generated colorscheme) so they track light/dark
-- switches. The dark-palette values are a fallback for before it's exported.
local function set_action_hl()
	local pal = vim.g.theme_palette or {}
	vim.api.nvim_set_hl(0, "PlanActionCreate", { fg = pal.green or "#97B5A6" })
	vim.api.nvim_set_hl(0, "PlanActionModify", { fg = pal.orange or "#FF570D" })
	vim.api.nvim_set_hl(0, "PlanActionTouch", { fg = pal.yellow or "#ff8a31" })
	vim.api.nvim_set_hl(0, "PlanActionDrift", { fg = pal.red or "#FF7B72" })
end

-- ○ pending · ◐ touched · ● done · – deliberately skipped (pending but with a note
-- explaining no change was needed) · ⚠ unplanned. Full text per item, hard-wrapped
-- with a hanging indent. Extmarks carry the hierarchy — bold headers, dim details,
-- status-colored glyphs — instead of markdown syntax highlighting.
render_steps = function(buf)
	local p = state.progress or {}
	local plan = parse_plan()
	local width = state.steps_width or 88

	local total, done, skipped = 0, 0, 0
	for _, f in ipairs(p.planned or {}) do
		total = total + 1
		if f.status == "done" then done = done + 1
		elseif f.status ~= "touched" and f.note and f.note ~= "" then skipped = skipped + 1 end
	end

	local lines, hls = {}, {}
	local function add(text)
		table.insert(lines, text)
		return #lines - 1 -- 0-based line index for extmarks
	end
	local function hl(line0, c0, c1, group) table.insert(hls, { line0, c0, c1, group }) end
	local function detail_lines(text)
		for _, dl in ipairs(wrap(text, "            ", "            ", width)) do
			hl(add(dl), 0, -1, "Comment")
		end
	end

	add("") -- top padding
	hl(add(string.format("  %s · %s · %d/%d done%s", p.ticket or "plan", p.phase or "?", done, total,
		skipped > 0 and string.format(" · %d skipped", skipped) or "")), 0, -1, "Title")
	add("")
	if #plan.flow > 0 then
		hl(add("  THE WORK"), 0, -1, "Title")
		for _, s in ipairs(plan.flow) do
			for i, dl in ipairs(wrap(s, "   ◆ ", "     ", width)) do
				local li = add(dl)
				if i == 1 then hl(li, 3, 6, "Special") end
			end
		end
		add("")
	end

	state.steps_paths = {}
	hl(add("  FILES"), 0, -1, "Title")
	-- One colored action icon per file (no status bullet — the icon is enough);
	-- create/modify/touch carry their theme color, files shown in plan order.
	local first = true
	local function emit(icon, igroup, file, detail)
		if not first then add("") end -- blank line between items
		first = false
		local li = add("   " .. icon .. " " .. file)
		hl(li, 3, 3 + #icon, igroup)
		state.steps_paths[li + 1] = file -- cursor line is 1-based
		if detail and detail ~= "" then detail_lines(detail) end
	end
	for _, f in ipairs(p.planned or {}) do
		local detail = (f.note and f.note ~= "") and f.note or plan.why[f.file]
		emit(action_icon(f.action), action_hl(f.action), f.file, detail)
	end
	for _, f in ipairs(p.unplanned or {}) do
		emit(vim.fn.nr2char(0xf071), "PlanActionDrift", f.file, f.why) -- ⚠ outside the plan
	end
	add("")
	hl(add(string.format("  %s new · %s modify · %s touch",
		action_icon("create"), action_icon("modify"), action_icon("touch"))), 0, -1, "Comment")
	hl(add("  ⏎ open · a amend · r refresh · q close"), 0, -1, "Comment")
	add("") -- bottom padding

	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	for _, m in ipairs(hls) do
		pcall(vim.api.nvim_buf_add_highlight, buf, ns, m[4], m[1], m[2], m[3])
	end
end

-- The plan binds to the nvim session when a plan buffer opens (autostart, :PlanOpen).
-- For an ordinary nvim that never opened it, resolve it on demand from the worktree's
-- branch — the same EVERY-<num> derivation autostart uses — so <C-p> works anywhere in
-- the worktree, not just the --plan stack pane.
local function resolve_plan_path()
	if state.plan_path and vim.uv.fs_stat(state.plan_path) then return state.plan_path end
	local root = state.root or git_root()
	if not root then return nil end
	local branch = (vim.fn.systemlist({ "git", "-C", root, "branch", "--show-current" })[1]) or ""
	local num = branch:match("(%d%d+)") or root:match("(%d%d+)")
	if not num then return nil end
	local target = plans_dir(root) .. "/EVERY-" .. num .. ".md"
	if vim.uv.fs_stat(target) then
		state.root = root
		state.plan_path = target
		return target
	end
	return nil
end

-- Read panel for implementation progress: the ◆ work, then every surface-area file
-- with its live status + the agent's note (or the plan's why). <CR> opens the file
-- under the cursor in the window the panel was opened from (panel keeps focus, so you
-- can keep jumping). Refreshes live while open as the agent ticks progress.json.
function M.steps()
	if not resolve_plan_path() then
		vim.notify("plan: no plan found for this worktree", vim.log.levels.INFO)
		return
	end
	read_progress()
	if not state.progress then
		vim.notify("plan: plan found but no progress.json yet", vim.log.levels.INFO)
		return
	end
	state.steps_prev_win = vim.api.nvim_get_current_win()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	local width = math.min(110, vim.o.columns - 6)
	state.steps_width = width - 4 -- wrap text short of the right edge for padding
	render_steps(buf)
	local n = #vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local height = math.min(n, vim.o.lines - 4)
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.floor((vim.o.lines - height) / 2 - 1),
		col = math.floor((vim.o.columns - width) / 2),
		style = "minimal",
		border = "rounded",
		title = " plan progress ",
		title_pos = "center",
	})
	vim.wo[win].wrap = false
	vim.wo[win].cursorline = true
	state.steps_buf, state.steps_win = buf, win
	local function close()
		if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
		state.steps_buf, state.steps_win = nil, nil
	end
	local o = { buffer = buf, nowait = true, silent = true }
	vim.keymap.set("n", "q", close, o)
	vim.keymap.set("n", "<Esc>", close, o)
	vim.keymap.set("n", "r", function() read_progress(); render_steps(buf) end, o)
	vim.keymap.set("n", "a", function() close(); M.amend() end, o)
	vim.keymap.set("n", "<CR>", function()
		local rel = state.steps_paths[vim.api.nvim_win_get_cursor(win)[1]]
		if not rel then return end
		local root = state.root or git_root() or vim.fn.getcwd()
		local abs = rel:match("^/") and rel or (root .. "/" .. rel)
		if state.steps_prev_win and vim.api.nvim_win_is_valid(state.steps_prev_win) then
			vim.api.nvim_win_call(state.steps_prev_win, function()
				vim.cmd("edit " .. vim.fn.fnameescape(abs))
			end)
		else
			close()
			vim.cmd("edit " .. vim.fn.fnameescape(abs))
		end
	end, o)
end

-- Dispatch /plan-ticket --go to the plan's worktree claude. Confirms first — this
-- one writes code.
function M.go()
	local name = plan_worktree()
	if not name or name == "main" then
		vim.notify("plan: no worktree session bound — run /plan-ticket --go there", vim.log.levels.INFO)
		return
	end
	if vim.fn.confirm("Dispatch /plan-ticket --go? The agent will implement the plan.", "&Yes\n&No", 2) ~= 1 then
		return
	end
	local ticket = vim.fn.fnamemodify(state.plan_path or "", ":t:r")
	-- Move into the worktree so progress paths resolve and code buffers open there,
	-- then watch the surface-area dirs so the agent's edits reload live.
	local wt = vim.fn.expand("~/work/lovable.daphen-" .. name)
	if vim.fn.isdirectory(wt) == 1 then
		vim.fn.chdir(wt)
		state.root = wt
	end
	vim.o.autoread = true
	read_progress()
	arm_surface_watches(state.root)
	vim.system({ "wt-send", "--wait", "8", name, "/plan-ticket --go " .. ticket })
	vim.notify("plan: dispatched --go to " .. name .. " — implementing", vim.log.levels.WARN)
end

-- The wt-send target for this plan's worktree, from the bound root's branch — works
-- from any buffer (unlike plan_worktree, which reads the plan buffer's header).
local function worktree_name()
	local root = state.root or git_root()
	if not root then return nil end
	local branch = (vim.fn.systemlist({ "git", "-C", root, "branch", "--show-current" })[1]) or ""
	local short = branch:match("^daphen/(.+)") or branch
	if short == "" or short == "main" then return nil end
	return short
end

-- Fold new scope into the plan mid-ticket. By --go time you've usually navigated off to
-- the code (cwd is the worktree), so this works from any buffer: composes what to add,
-- dispatches --amend, and re-opens the plan by its absolute vault path — cwd stays on
-- the worktree so code keeps live-reloading — for you to review and re-approve.
function M.amend()
	if not resolve_plan_path() then
		vim.notify("plan: no plan found for this worktree", vim.log.levels.INFO)
		return
	end
	local name = worktree_name()
	if not name then
		vim.notify("plan: no worktree session bound — run /plan-ticket --amend there", vim.log.levels.INFO)
		return
	end
	local ticket = vim.fn.fnamemodify(state.plan_path, ":t:r")
	compose("▲ amend — what to add to the plan", function(text)
		vim.system({ "wt-send", "--wait", "8", name, "/plan-ticket --amend " .. ticket .. "\n\n" .. text })
		vim.cmd("edit " .. vim.fn.fnameescape(state.plan_path)) -- bring the plan up to review/re-approve
		vim.notify("plan: amend dispatched — the plan reloads here with the additions; review & re-approve")
	end)
end

-- Is the cursor inside a `### D#` decision block (vs past it under a later heading)?
local function in_decision()
	local cur = vim.api.nvim_win_get_cursor(0)[1]
	local lines = vim.api.nvim_buf_get_lines(0, 0, cur, false)
	for i = #lines, 1, -1 do
		if lines[i]:match("^### D") then return true end
		if lines[i]:match("^#") then return false end
	end
	return false
end

-- Context-aware primary action (<CR>): do the obvious thing for the object the
-- cursor is on — open a file, answer a question, approve, or resolve a decision.
function M.act()
	local line = vim.api.nvim_get_current_line()
	if line:match("^%s*|") and path_on_line(line) then return M.goto_file() end
	if line:match("^>%s*❓") then return dispatch_questions() end
	if line:match("^> Status:") then
		-- the Status line is the "advance the plan" control: draft → approve,
		-- planned → finalize, finalized → ready (don't auto-run --go).
		if state.status == "planned" then return M.finalize() end
		if state.status == "finalized" then
			return vim.notify("plan: finalized — run /plan-ticket --go in the worktree", vim.log.levels.INFO)
		end
		return M.approve()
	end
	if in_decision() then return M.resolve_decision() end
	vim.notify("plan: nothing to act on here — <C-p>q ask · <C-p>n note", vim.log.levels.INFO)
end

-- Worktree-stack entry: wait for the agent's /plan-ticket to write THIS ticket's
-- plan, then open it. Plans live in a shared vault, so we must target the
-- worktree's own ticket (from its branch/dir name) — "newest plan" would grab
-- whatever ticket was touched last. Bounded poll so it works whether the plan
-- lands in 2s or two minutes.
function M.autostart()
	state.root = git_root()
	if not state.root then return end
	local branch = (vim.fn.systemlist({ "git", "-C", state.root, "branch", "--show-current" })[1]) or ""
	local num = branch:match("(%d%d+)") or state.root:match("(%d%d+)")
	if not num then return end
	local target = plans_dir() .. "/EVERY-" .. num .. ".md"
	local function try_open()
		if vim.uv.fs_stat(target) then open_path(target); return true end
		return false
	end
	if try_open() then return end
	local timer = vim.uv.new_timer()
	local attempts = 0
	timer:start(2000, 2000, vim.schedule_wrap(function()
		attempts = attempts + 1
		if try_open() or attempts > 600 then
			timer:stop(); timer:close()
		end
	end))
end

-- Silently bind the session to the worktree's plan WITHOUT opening it — reads status
-- + progress and starts the watcher — so the lualine component and <C-p> work in an
-- ordinary code-editing nvim, not just the --plan stack pane. No-op outside a worktree
-- that has a matching plan.
function M.bind()
	if state.plan_path or not resolve_plan_path() then return end
	read_status()
	read_progress()
	watch()
end

-- Re-assert the buffer-local plan maps (deferred so they win over obsidian's
-- <CR>, which obsidian re-binds whenever it re-attaches — e.g. when a picker
-- float closes and BufEnter fires). Idempotent; safe to call on every entry.
local function apply_buffer_maps(buf)
	vim.schedule(function()
		if not vim.api.nvim_buf_is_valid(buf) then return end
		local map = function(lhs, fn, desc)
			vim.keymap.set("n", lhs, fn, { buffer = buf, desc = desc })
		end
		map("<CR>", M.act, "plan: act on object under cursor")
		map("<C-p>q", M.ask, "plan: ask the agent")
		map("<C-p>n", M.add_note, "plan: add a note")
		map("<C-p>f", M.finalize, "plan: finalize → execution spec")
		map("<C-p>g", M.go, "plan: implement (--go)")
		map("<C-p>a", M.amend, "plan: amend (add scope)")
		map("<C-p>s", M.steps, "plan: progress panel")
		-- In a plan buffer <C-p> stays the action prefix; a bare press is a no-op
		-- (not the global progress panel — you're already looking at the plan).
		map("<C-p>", function() end, "plan: (prefix)")
		vim.keymap.set("x", "<C-p>q", "<Esc><cmd>lua require('plan-nvim').ask_visual()<CR>",
			{ buffer = buf, desc = "plan: ask about selection" })
		vim.keymap.set("x", "<C-p>n", "<Esc><cmd>lua require('plan-nvim').add_note_visual()<CR>",
			{ buffer = buf, desc = "plan: note on selection" })
	end)
end

function M.setup()
	set_action_hl()
	vim.api.nvim_create_autocmd("ColorScheme", { callback = set_action_hl })

	vim.api.nvim_create_user_command("PlanOpen", function(o) M.open(o.args) end, { nargs = "?" })
	vim.api.nvim_create_user_command("PlanGoto", M.goto_file, {})
	vim.api.nvim_create_user_command("PlanDecide", M.resolve_decision, {})
	vim.api.nvim_create_user_command("PlanApprove", M.approve, {})
	vim.api.nvim_create_user_command("PlanReload", function() read_status() end, {})
	vim.api.nvim_create_user_command("PlanAsk", M.ask, {})
	vim.api.nvim_create_user_command("PlanNote", M.add_note, {})
	vim.api.nvim_create_user_command("PlanFinalize", M.finalize, {})
	vim.api.nvim_create_user_command("PlanGo", M.go, {})
	vim.api.nvim_create_user_command("PlanAmend", M.amend, {})
	vim.api.nvim_create_user_command("PlanSteps", M.steps, {})

	-- Bare <C-p> opens the progress panel from any ordinary buffer (e.g. while
	-- reading the code the agent is touching). Plan buffers shadow this with their
	-- own <C-p> prefix, so the panel there is <C-p>s.
	vim.keymap.set("n", "<C-p>", M.steps, { desc = "plan: progress panel" })

	-- Buffer-local maps only inside a plan file, so they never clobber normal
	-- markdown editing elsewhere. Set on open AND re-assert on every BufEnter,
	-- because obsidian re-binds <CR> when it re-attaches (e.g. after a picker
	-- float closes), which would otherwise win.
	local plan_patterns = { "*/.plans/*.md", "*/personal/notes/storage/plans/*.md" }
	vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
		pattern = plan_patterns,
		callback = function(ev)
			state.plan_path = vim.api.nvim_buf_get_name(ev.buf)
			state.root = git_root()
			read_status()
			read_progress()
			watch()
			apply_buffer_maps(ev.buf)
		end,
	})
	vim.api.nvim_create_autocmd("BufEnter", {
		pattern = plan_patterns,
		callback = function(ev)
			state.plan_path = vim.api.nvim_buf_get_name(ev.buf)
			state.root = git_root()
			read_status()
			read_progress()
			apply_buffer_maps(ev.buf)
		end,
	})

	-- Set by ws-createwt on the worktree's nvim pane only, so ordinary nvim
	-- sessions never auto-open a plan. Defer past VimEnter: opening the plan
	-- mid-init races plugin attach (markview, treesitter), leaving the buffer
	-- unrendered with <CR> unbound. The defer puts the open in the same
	-- post-init regime as a manual :e.
	vim.api.nvim_create_autocmd("VimEnter", {
		once = true,
		callback = function()
			vim.defer_fn(function()
				M.bind() -- silently bind so the statusline + <C-p> work in any worktree nvim
				if vim.env.PLAN_NVIM_OPEN == "1" then M.autostart() end
			end, 150)
		end,
	})
end

return M
