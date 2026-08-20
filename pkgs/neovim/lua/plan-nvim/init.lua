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
	poller = nil,
	poll_stamp = "",
	file_watchers = {},
	following = false, -- --go follow mode: open files as the agent touches them
	follow_win = nil,
	follow_cur = nil,
	follow_seen = {},
	follow_user_off = false, -- explicit :PlanFollow off wins over auto-arm
	last_phase = nil,
}

-- Assigned lower down; forward-declared so earlier closures capture the upvalue.
local arm_surface_watches, follow_step, resolve_next_decision

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
	-- one pass: the status line + the count of still-unresolved decisions, so the
	-- statusline can show the next action without re-parsing the file on every redraw.
	local status, dunres = nil, 0
	for _, line in ipairs(lines) do
		if not status then
			local s = line:match("^> Status:%s*`([%w]+)`")
			if s then status = s end
		end
		if line:match("%*%*Your call:%*%*") and line:match("_%(unresolved%)_") then
			dunres = dunres + 1
		end
	end
	if status then state.status = status end
	state.dunres = dunres
end

-- progress.json is the agent's live feed during --go/--reconcile: per-file status
-- (pending|touched|done), an optional `note` (what it actually did / why skipped),
-- and the phase. Read alongside the plan; drives the statusline and the menu.
local function read_progress()
	state.progress = nil
	if not state.plan_path then return end
	local pj = state.plan_path:gsub("%.md$", ".progress.json")
	local ok, content = pcall(vim.fn.readfile, pj)
	if not ok then return end
	local ok2, data = pcall(vim.json.decode, table.concat(content, "\n"))
	if ok2 and type(data) == "table" then state.progress = data end
end

-- review.json (from --reconcile): verification items with pass/fail/pending results.
-- The pending, command-less ones are the manual steps left to run.
local function read_review()
	if not state.plan_path then return nil end
	local rj = state.plan_path:gsub("%.md$", ".review.json")
	local ok, content = pcall(vim.fn.readfile, rj)
	if not ok then return nil end
	local ok2, data = pcall(vim.json.decode, table.concat(content, "\n"))
	if ok2 and type(data) == "table" then return data end
	return nil
end

-- Headline progress = conceptual work, not file count. Prefer first-class steps
-- (progress.flow[]: one entry per ◆ step, status pending|active|done); a step is
-- done when its status says so. Fall back to resolved surface-area files (done or
-- deliberately skipped-with-note) for plans written before step tracking existed.
-- Returns done, total, active, axis ("steps"|"files"|"none").
local function step_progress()
	local p = state.progress
	if not p then return 0, 0, 0, "none" end
	if type(p.flow) == "table" and #p.flow > 0 then
		local done, active = 0, 0
		for _, s in ipairs(p.flow) do
			if s.status == "done" then done = done + 1
			elseif s.status == "active" then active = active + 1 end
		end
		return done, #p.flow, active, "steps"
	end
	local total, resolved, touched = 0, 0, 0
	for _, f in ipairs(p.planned or {}) do
		total = total + 1
		if f.status == "done" then resolved = resolved + 1
		elseif f.status == "touched" then touched = touched + 1
		elseif f.note and f.note ~= "" then resolved = resolved + 1 end
	end
	return resolved, total, touched, "files"
end

-- The single next action to take given the plan's state, as (label, keybind). Shown
-- in the lualine statusline so it is glanceable without
-- opening the plan. key is nil when there is nothing to press (mid-implement / done).
-- Reads cached state (state.dunres from read_status) — cheap enough for the statusline.
local function next_step()
	local p = state.progress or {}
	-- decisions gate everything before they're resolved
	if (state.dunres or 0) > 0 then
		local n = state.dunres
		return string.format("resolve %d decision%s", n, n > 1 and "s" or ""), "d"
	end
	-- once work starts, progress.json phase is the current signal (the .md status line
	-- lags at "finalized" through implementation) — check it before the review status
	if p.phase == "reconciled" then return "done ✓", nil end
	if p.phase == "implementing" then
		local done, total = step_progress()
		if total > 0 and done == total then return "reconcile", "r" end
		return "implementing…", nil
	end
	-- pre-implementation: drive off the plan's review status
	local st = state.status
	if st == "finalized" then return "implement", "g" end
	if st == "planned" or st == "amended" then return "finalize", "f" end
	if st == "draft" then return "review & approve", "v" end
	return nil, nil
end


-- lualine component: require("plan-nvim").statusline()
function M.statusline()
	local p = state.progress
	if not p and not state.status then return "" end
	local hint, key = next_step()
	local nexttxt = key and (" → " .. key .. " " .. hint) or ""
	if p and (p.phase == "implementing" or p.phase == "reconciled") then
		local done, total, active = step_progress()
		local mark
		if p.phase == "reconciled" then mark = "✓"
		elseif total > 0 and done == total then mark = "●"
		elseif done + active > 0 then mark = "◐"
		else mark = "○" end
		return string.format(" %s %s %d/%d%s", p.ticket or "plan", mark, done, total, nexttxt)
	end
	local icon = state.status == "planned" and "" or "" -- planned vs draft
	return string.format("%s %s · %s%s", icon, (p and p.ticket) or "plan", state.status or "draft", nexttxt)
end

-- Shared refresh: re-read the artifacts and update every surface. Driven by
-- BOTH the fs_event watcher and a 2s mtime poll — fs_event alone proved
-- capable of failing silently (a whole implement cycle went unnoticed).
local function refresh_from_artifacts()
	read_status()
	read_progress()
	pcall(vim.cmd, "checktime") -- reload the plan buffer when the agent rewrites it (answers, --finalize)
	-- An amend (from nvim OR the agent TUI) bumps amended_at; bring the plan up
	-- so you review the additions and re-approve, even from a code buffer.
	local amended = state.progress and state.progress.amended_at
	local signal = (amended and amended ~= state.last_amended)
		or (state.status == "amended" and state.last_status ~= "amended")
	if signal then
		state.last_amended = amended
		if state.plan_path and vim.api.nvim_buf_get_name(0) ~= state.plan_path then
			if pcall(vim.cmd, "edit " .. vim.fn.fnameescape(state.plan_path)) then
				vim.notify("plan: amended — review the additions & re-approve")
			else
				vim.notify("plan: amended — :PlanOpen to review", vim.log.levels.WARN)
			end
		end
	end
	state.last_status = state.status
	local phase = state.progress and state.progress.phase
	if phase == "implementing" then
		if not state.following and not state.follow_user_off and state.last_phase ~= "implementing" then
			-- --go can arrive outside :PlanGo (agent TUI, orchestrator relay);
			-- arm follow on the observed transition so nvim tracks it anyway.
			state.following = true
			state.follow_win = nil -- follow_step re-acquires a window
			state.follow_cur = nil
			state.follow_seen = {}
			for _, f in ipairs((state.progress or {}).planned or {}) do state.follow_seen[f.file] = f.status end
			vim.notify("plan: --go detected — follow mode on")
		end
		arm_surface_watches(state.root) -- surface area can grow (unplanned files)
		follow_step() -- open the file the agent is currently touching
	elseif phase == "reconciled" then
		state.following = false -- implementation done; stop following
	end
	state.last_phase = phase
	pcall(function() require("plan-nvim.review").refresh() end)
end

local function artifact_stamp()
	if not state.plan_path then return "" end
	local base = state.plan_path:gsub("%.md$", "")
	local parts = {}
	for _, f in ipairs({ state.plan_path, base .. ".progress.json", base .. ".review.json" }) do
		local st = vim.uv.fs_stat(f)
		parts[#parts + 1] = st and (st.mtime.sec .. ":" .. st.mtime.nsec) or "x"
	end
	return table.concat(parts, "|")
end

local function start_poll()
	if state.poller then pcall(function() state.poller:stop(); state.poller:close() end) end
	local t = vim.uv.new_timer()
	if not t then return end
	state.poller = t
	state.poll_stamp = artifact_stamp()
	t:start(2000, 2000, vim.schedule_wrap(function()
		local stamp = artifact_stamp()
		if stamp ~= state.poll_stamp then
			state.poll_stamp = stamp
			refresh_from_artifacts()
		end
	end))
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
			refresh_from_artifacts()
		end))
	end)
	start_poll()
end

-- An nvim that should auto-open plans: the old worktree stack set PLAN_NVIM_OPEN;
-- the agent cockpit's nvim exports HEIDR_SCOPE; and, as a fallback for an nvim
-- relaunched in the cockpit tab without those, being on the `lovable` niri
-- workspace (same signal the rail uses). Cached — computed once per session.
local _auto_open = nil
local function want_auto_open()
	-- The agent-rail owns the editor's default view (its per-session dashboard shows
	-- plan status + a `p` shortcut), so it disables plan auto-open by setting this
	-- global. Not cached: the rail sets it during setup, which may land either side
	-- of the first call.
	if vim.g.plan_nvim_no_autoopen then return false end
	if _auto_open ~= nil then return _auto_open end
	_auto_open = vim.env.PLAN_NVIM_OPEN == "1"
		or (vim.env.HEIDR_SCOPE ~= nil and vim.env.HEIDR_SCOPE ~= "")
	if not _auto_open then
		local ok, out = pcall(vim.fn.system, { "niri", "msg", "--json", "workspaces" })
		if ok and type(out) == "string" and out ~= "" then
			local dok, wss = pcall(vim.json.decode, out)
			if dok and type(wss) == "table" then
				for _, w in ipairs(wss) do
					if w.is_focused and w.name == "lovable" then
						_auto_open = true
						break
					end
				end
			end
		end
	end
	return _auto_open
end

-- The worktree bound to this plan, resolved from its `worktree: <branch>` header —
-- NOT the nvim cwd (plans live in the vault, so cwd is usually not a worktree, and
-- git_root() would bind the wrong repo → --go chdir's wrong and follow never fires).
-- The value wraps onto its own line, so scan from the "worktree:" line for the first
-- backtick-wrapped daphen/<branch>; map it to the cockpit worktree path. nil when
-- absent or the dir is missing (caller falls back to git_root()).
local function plan_worktree_root()
	if not state.plan_path then return nil end
	local ok, lines = pcall(vim.fn.readfile, state.plan_path, "", 40)
	if not ok then return nil end
	local hit = false
	for _, l in ipairs(lines) do
		if l:match("worktree:") then hit = true end
		if hit then
			local name = l:match("`daphen/([^`]+)`")
			if name then
				local path = vim.fn.expand("~/work/lovable.daphen-" .. name)
				return vim.fn.isdirectory(path) == 1 and path or nil
			end
		end
	end
	return nil
end

-- keep_focus: open the plan in the editor window WITHOUT moving focus there (used
-- by autostart so the agent rail stays active by default); otherwise switch to it.
local function open_path(path, keep_focus)
	state.plan_path = path
	state.root = plan_worktree_root() or git_root()
	-- Open in the editor window — never the agent rail, a float, or a special
	-- buffer. The editor window is any non-float, non-agent-* pane; DON'T require
	-- buftype=="" — the rail's dashboard is a `nofile` scratch, and excluding it
	-- left target=nil so the fall-through `:edit` clobbered whatever was current
	-- (the roster) with the plan. Match the pane regardless of its buftype.
	local target
	for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		local b = vim.api.nvim_win_get_buf(w)
		if vim.api.nvim_win_get_config(w).relative == ""
			and not vim.api.nvim_buf_get_name(b):match("agent%-") then
			target = w
			break
		end
	end
	local edit = "edit " .. vim.fn.fnameescape(path)
	if target then
		if keep_focus then
			vim.api.nvim_win_call(target, function() vim.cmd(edit) end)
		else
			if target ~= vim.api.nvim_get_current_win() then pcall(vim.api.nvim_set_current_win, target) end
			vim.cmd(edit)
		end
		return
	end
	-- No editor window at all (rail-only layout): make one rather than clobber a
	-- rail pane with the plan.
	if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(0)):match("agent%-") then
		vim.cmd("leftabove vsplit")
	end
	vim.cmd(edit)
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
-- and write it into the block's "Your call:" line. then_fn (optional) runs after a
-- successful write — used to chain straight into the next unresolved decision.
function M.resolve_decision(then_fn)
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
		local line = lines[i]
		if line:match("%*%*Your call:%*%*") then
			call_ln = i
		elseif not line:match("%*%*Recommendation") then
			-- Option line — a single-letter label in bold, either form:
			--   - **A** — desc      (letter alone in bold)
			--   - **A — desc.**     (letter + desc bolded together)
			-- The delimiter after the letter (**, space+dash, ., :, )) is what
			-- distinguishes an option from "Recommendation"/"Your call".
			local letter = line:match("^%s*%-%s*%*%*%s*(%w)%s*[%-—%*%.:)]")
			if letter then
				local label = vim.trim((line:gsub("^%s*%-%s*", ""):gsub("%*%*", "")))
				table.insert(options, { letter = letter, label = label })
			end
		end
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
		if then_fn then vim.schedule(then_fn) end
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
		-- Short title (a long one overruns the 76-col float and center-truncates
		-- into "…k about selection"); the key hints live in the footer instead.
		title = " " .. title .. " ",
		title_pos = "center",
		footer = " ⏎ send · esc cancel ",
		footer_pos = "center",
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

-- Send a /plan-ticket prompt to the agent driving the plan's repo
-- (state.root) — repo-targeted via `agent send --cwd`, which routes to the pi rail
-- session kicked the plan off in, worktree or not. Prompt goes on stdin to avoid arg-quoting.
local function dispatch(prompt, wait, cwd)
	local root = cwd or state.root or git_root()
	if not root then
		vim.notify("plan: no repo bound — open the plan from inside its repo", vim.log.levels.WARN)
		return false
	end
	vim.system({ "agent", "send", "--cwd", root, "--wait", tostring(wait or 8) }, { stdin = prompt }, function(res)
		if res.code ~= 0 then
			vim.schedule(function()
				vim.notify("plan: no agent driving " .. root .. " — open the rail / start a session there",
					vim.log.levels.WARN)
			end)
		end
	end)
	return true
end

-- Ask the repo's agent to answer the open questions inline; answers land in the file
-- and the watcher reloads it.
local function dispatch_questions()
	local msg = ("Answer the open `> ❓` questions in %s — write each answer inline "
		.. "directly below its question as `> 💬 <answer>`, reading the repo as needed. "
		.. "Don't change code."):format(state.plan_path or "the open plan")
	if dispatch(msg) then vim.notify("plan: dispatched — answers land inline") end
end

-- ❓ ask: drop the question into the plan inline and dispatch it to the worktree agent,
-- which answers right below it (`> 💬`). Anchored after `anchor` — for the visual
-- variant that's the selection end, so it sits under the lines it's about. (To add a
-- directive/constraint, just edit the plan text directly — there's no separate note.)
local function ask_at(anchor, title)
	compose(title, function(text)
		insert_after(anchor, quote_block("❓", text))
		dispatch_questions()
	end)
end

function M.ask()
	ask_at(vim.api.nvim_win_get_cursor(0)[1], "ask the agent")
end

-- Visual variant: the x-mode map presses <Esc> first, so '> holds the selection end.
-- Visual Ctrl+P from ANY buffer: ask the repo's agent about the highlighted
-- text. Chat-only — the selection travels as context in the prompt, nothing
-- is inserted inline and the agent is told not to write anywhere.
function M.ask_visual()
	local l1, l2 = vim.fn.line("'<"), vim.fn.line("'>")
	local sel = table.concat(vim.api.nvim_buf_get_lines(0, l1 - 1, l2, false), "\n")
	local abs = vim.api.nvim_buf_get_name(0)
	-- Route to the active rail session ("the agent") whenever one is open, so
	-- <C-p> works from ANY buffer, not just a plan; fall back to the plan's repo.
	local target_cwd
	local ok, agent = pcall(require, "heidr")
	if ok and agent.active_session then
		local a = agent.active_session()
		if a then target_cwd = a.cwd end
	end
	local root = target_cwd or state.root or git_root()
	-- pretty ref: repo-relative under the routed cwd, else just the filename
	local ref = (root and abs:sub(1, #root) == root) and abs:sub(#root + 2)
		or vim.fn.fnamemodify(abs, ":t")
	-- the "don't edit the plan" guard only applies when asking ABOUT a plan;
	-- for ordinary code selections it's just an answer-in-chat question.
	local from_plan = state.plan_path and abs == state.plan_path
	compose("ask about selection", function(text)
		-- Render clean in the rail chat: an inline-code ref + the selection in a
		-- fenced code block (markview shows it literally on a card background — no
		-- blockquote > markers, no rendered list bullets). Strip a leading list
		-- marker so the highlighted text reads as plain content. The selection
		-- travels inline, so the agent needs no file read.
		local block = table.concat(
			vim.tbl_map(function(x) return (x:gsub("^%s*[-*+]%s+", "")) end,
				vim.split(sel, "\n", { plain = true })), "\n")
		local guard = from_plan and "_(answer in chat — don't edit the plan)_"
			or "_(answer in chat)_"
		local prompt = ("`%s:%d-%d`\n```\n%s\n```\n\n%s\n\n%s")
			:format(ref, l1, l2, block, text, guard)
		if dispatch(prompt, nil, target_cwd) then
			vim.notify("plan: question sent — answer in the agent chat")
		end
	end)
end

-- Dispatch /plan-ticket --finalize to the repo's agent: bake resolved decisions into
-- directives, strip the Q&A. The cleaned plan reloads via the watcher (checktime).
function M.finalize()
	if not state.plan_path then
		vim.notify("plan: no plan open", vim.log.levels.INFO)
		return
	end
	read_status() -- refresh status + unresolved-decision count from the file, not buffer 0
	if (state.dunres or 0) > 0 then
		vim.notify("plan: resolve all decisions before finalizing", vim.log.levels.WARN)
		return
	end
	local ticket = vim.fn.fnamemodify(state.plan_path, ":t:r")
	if dispatch("/plan-ticket --finalize " .. ticket) then vim.notify("plan: dispatched --finalize") end
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

-- --go follow mode: as progress.json flips files, open the one the agent is currently
-- touching (or just finished) in the follow window — so nvim tracks the agent even for
-- files you never opened (checktime only reloads already-open buffers; this opens them).
-- Opened via win_call so it never steals focus from where you're working.
-- A REAL editor window — never the agent rail (agent-* buffers), a float, or a
-- special buffer. Editing a file into the rail's composer/chat clobbers it (files
-- bleeding into the chat input).
local function is_editor_win(w)
	if not (w and vim.api.nvim_win_is_valid(w)) then return false end
	local b = vim.api.nvim_win_get_buf(w)
	return vim.api.nvim_win_get_config(w).relative == ""
		and vim.bo[b].buftype == ""
		and not vim.api.nvim_buf_get_name(b):match("agent%-")
end

local function pick_follow_win()
	local cur = vim.api.nvim_get_current_win()
	if is_editor_win(cur) then return cur end
	for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if is_editor_win(w) then return w end
	end
	return nil
end

follow_step = function()
	if not state.following then return end
	local win = state.follow_win
	-- Re-acquire if the bound window is gone OR is a rail pane. state.follow_win is
	-- whatever was focused when --go ran, so if that was the composer/chat, a
	-- followed file :e would dump straight into the input. Only ever a real editor.
	if not is_editor_win(win) then
		win = pick_follow_win()
		if not win then return end
		state.follow_win = win
		state.follow_cur = nil
		-- silent: re-acquiring a real editor window (the bound one was a rail pane or
		-- died to layout churn) is routine now, not worth a toast on every --go.
	end
	local p = state.progress
	if not p then return end
	local active, fallback
	for _, f in ipairs(p.planned or {}) do
		if f.status ~= state.follow_seen[f.file] then
			if f.status == "touched" then active = f.file
			elseif f.status == "done" then fallback = f.file end
		end
		state.follow_seen[f.file] = f.status
	end
	local target = active or fallback -- prefer the in-progress file over a just-finished one
	if target and target ~= state.follow_cur then
		state.follow_cur = target
		local root = state.root or git_root() or vim.fn.getcwd()
		local abs = target:match("^/") and target or (root .. "/" .. target)
		if vim.uv.fs_stat(abs) then
			pcall(vim.api.nvim_win_call, win, function()
				vim.cmd("edit " .. vim.fn.fnameescape(abs))
			end)
		end
	end
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

local function hex2rgb(h) return tonumber(h:sub(2, 3), 16) / 255, tonumber(h:sub(4, 5), 16) / 255, tonumber(h:sub(6, 7), 16) / 255 end
local function rgb2hex(r, g, b) return string.format("#%02x%02x%02x", math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5)) end
local function rgb2hsl(r, g, b)
	local mx, mn = math.max(r, g, b), math.min(r, g, b)
	local h, s, l, d = 0, 0, (mx + mn) / 2, mx - mn
	if d > 0 then
		s = l > 0.5 and d / (2 - mx - mn) or d / (mx + mn)
		if mx == r then h = (g - b) / d + (g < b and 6 or 0)
		elseif mx == g then h = (b - r) / d + 2
		else h = (r - g) / d + 4 end
		h = h / 6
	end
	return h, s, l
end
local function hue2rgb(p, q, t)
	if t < 0 then t = t + 1 elseif t > 1 then t = t - 1 end
	if t < 1 / 6 then return p + (q - p) * 6 * t end
	if t < 1 / 2 then return q end
	if t < 2 / 3 then return p + (q - p) * (2 / 3 - t) * 6 end
	return p
end
local function hsl2rgb(h, s, l)
	if s == 0 then return l, l, l end
	local q = l < 0.5 and l * (1 + s) or l + s - l * s
	local p = 2 * l - q
	return hue2rgb(p, q, h + 1 / 3), hue2rgb(p, q, h), hue2rgb(p, q, h - 1 / 3)
end
-- A vivid version of the theme's own green: keep its hue, boost saturation, and set a
-- lightness that reads on the current background. Derived (not hardcoded), so it tracks
-- the theme per light/dark — the palette's green is a desaturated sage that reads dull.
local function vivid(hex, dark)
	local h, s, l = rgb2hsl(hex2rgb(hex))
	return rgb2hex(hsl2rgb(h, math.max(s, 0.6), dark and 0.62 or 0.38))
end

-- Action-icon colors from the active theme's palette (vim.g.theme_palette), per mode.
-- Green is boosted to a vivid shade of the theme's green so "done"/"create" pop.
local function set_action_hl()
	local pal = vim.g.theme_palette or {}
	local dark = vim.o.background == "dark"
	vim.api.nvim_set_hl(0, "PlanActionCreate", { fg = vivid(pal.green or (dark and "#97B5A6" or "#5E7270"), dark) })
	vim.api.nvim_set_hl(0, "PlanActionModify", { fg = pal.orange or "#FF570D" })
	vim.api.nvim_set_hl(0, "PlanActionTouch", { fg = pal.yellow or "#ff8a31" })
	vim.api.nvim_set_hl(0, "PlanActionDrift", { fg = pal.red or "#FF7B72" })
end


-- FOLDER-based binding, the primary key: a session spawned in this folder with a
-- bound plan slug (agentd persist, one file per scope). Plans belong to the folder
-- a session lives in, not to a git branch — a main-checkout or non-repo folder has
-- no usable branch at all.
local function bound_key(dir)
	local base = vim.fn.expand("~/.local/state/agentd")
	for _, f in ipairs(vim.fn.glob(base .. "/*-sessions.json", false, true)) do
		local ok, data = pcall(function() return vim.json.decode(table.concat(vim.fn.readfile(f), "\n")) end)
		if ok and type(data) == "table" then
			for _, s in ipairs(data) do
				if s.cwd == dir and s.plan and s.plan ~= "" then return s.plan end
			end
		end
	end
end

-- The artifact key for a folder's plan: the folder's session binding first; else
-- from the branch — a Linear branch (carries a ticket number) keys as `EVERY-<num>`;
-- an ad-hoc branch (`daphen/refactor-foo`) keys as its short name (`refactor-foo`) —
-- so own-work plans need no ticket. nil for main/master with no binding.
local function plan_key(root)
	root = root or state.root or git_root() or vim.fn.getcwd()
	if not root then return nil end
	local bound = bound_key(root)
	if bound then return bound end
	local branch = (vim.fn.systemlist({ "git", "-C", root, "branch", "--show-current" })[1]) or ""
	local name = branch:match("^daphen/(.+)")
		or (branch ~= "" and branch)
		or (vim.fn.fnamemodify(root, ":t"):gsub("^lovable%.daphen%-", ""))
	if not name or name == "" or name == "main" or name == "master" then return nil end
	local num = name:match("(%d%d+)")
	return num and ("EVERY-" .. num) or name
end

-- The plan binds to the nvim session when a plan buffer opens (autostart, :PlanOpen).
-- For an ordinary nvim that never opened it, resolve it on demand from the folder
-- binding or the worktree's branch (via plan_key) — so <C-p> works anywhere.
local function resolve_plan_path()
	if state.plan_path and vim.uv.fs_stat(state.plan_path) then return state.plan_path end
	local root = state.root or git_root() or vim.fn.getcwd()
	if not root then return nil end
	local key = plan_key(root)
	if not key then return nil end
	local target = plans_dir(root) .. "/" .. key .. ".md"
	if vim.uv.fs_stat(target) then
		state.root = root
		state.plan_path = target
		return target
	end
	return nil
end


-- Dispatch /plan-ticket --go to the repo's agent. Confirms first — this one writes
-- code. cwd is moved to the repo root so progress paths resolve and the surface-area
-- watcher catches the agent's edits.
function M.go()
	if not resolve_plan_path() then
		vim.notify("plan: no plan found for this repo", vim.log.levels.INFO)
		return
	end
	if vim.fn.confirm("Dispatch /plan-ticket --go? The agent will implement the plan.", "&Yes\n&No", 2) ~= 1 then
		return
	end
	local ticket = vim.fn.fnamemodify(state.plan_path, ":t:r")
	-- Re-resolve here too: the plan may have been opened before its worktree existed,
	-- or state.root drifted to the vault. The header is authoritative.
	state.root = plan_worktree_root() or state.root or git_root()
	if state.root then vim.fn.chdir(state.root) end
	vim.o.autoread = true
	read_progress()
	arm_surface_watches(state.root)
	-- follow the agent: this window now tracks whatever file it's editing. Baseline the
	-- current statuses so only flips after --go open a file.
	state.following = true
	state.follow_win = vim.api.nvim_get_current_win()
	state.follow_cur = nil
	state.follow_seen = {}
	for _, f in ipairs((state.progress or {}).planned or {}) do state.follow_seen[f.file] = f.status end
	if dispatch("/plan-ticket --go " .. ticket) then
		vim.notify("plan: dispatched --go — implementing (this window follows the agent)", vim.log.levels.WARN)
	end
end

-- Fold new scope into the plan mid-ticket. Works from any buffer: composes what to add,
-- dispatches --amend to the repo's agent, and re-opens the plan (absolute vault path,
-- cwd left on the repo) for you to review and re-approve.
function M.amend()
	if not resolve_plan_path() then
		vim.notify("plan: no plan found for this repo", vim.log.levels.INFO)
		return
	end
	local ticket = vim.fn.fnamemodify(state.plan_path, ":t:r")
	compose("▲ amend — what to add to the plan", function(text)
		if dispatch("/plan-ticket --amend " .. ticket .. "\n\n" .. text) then
			vim.cmd("edit " .. vim.fn.fnameescape(state.plan_path)) -- bring the plan up to review/re-approve
			vim.notify("plan: amend dispatched — the plan reloads here; review & re-approve")
		end
	end)
end

-- The final step: dispatch /plan-ticket --reconcile to check plan vs outcome — maps
-- changes to ◆ steps, flags drift + missing steps, runs the verification commands, and
-- writes review.json + the Reconciliation section. Works from any buffer.
function M.reconcile()
	if not resolve_plan_path() then
		vim.notify("plan: no plan found for this repo", vim.log.levels.INFO)
		return
	end
	local ticket = vim.fn.fnamemodify(state.plan_path, ":t:r")
	if dispatch("/plan-ticket --reconcile " .. ticket) then
		vim.notify("plan: dispatched --reconcile — checking plan vs outcome")
	end
end

-- <C-p>: the plan menu — ordered lifecycle picker. Each step shows its state
-- (✓ done · → next · locked with the reason), so --go can't be run before
-- --finalize by accident. This picker is the plugin's ONE interface.
function M.menu()
	if not resolve_plan_path() then
		vim.notify("plan: no plan found for this repo", vim.log.levels.INFO)
		return
	end
	-- read_status needs the plan buffer text; read from disk when not loaded
	local plan_lines = {}
	local bufnr = vim.fn.bufnr(state.plan_path)
	if bufnr > 0 and vim.api.nvim_buf_is_loaded(bufnr) then
		plan_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	else
		plan_lines = vim.fn.readfile(state.plan_path)
	end
	local status, unres = "draft", 0
	for _, line in ipairs(plan_lines) do
		local s = line:match("^> Status:%s*`([%w]+)`")
		if s then status = s end
		if line:match("%*%*Your call:%*%*") and line:match("_%(unresolved%)_") then
			unres = unres + 1
		end
	end
	read_progress()
	local phase = (state.progress or {}).phase
	local finalized = status == "finalized" or phase == "implementing" or phase == "reconciled"
	local implemented = phase == "implementing" or phase == "reconciled"

	local function open_plan()
		vim.cmd("edit " .. vim.fn.fnameescape(state.plan_path))
	end
	local key = vim.fn.fnamemodify(state.plan_path, ":t:r")

	-- lifecycle in canonical order; state derived, never reordered
	local entries = {
		{
			label = ("Resolve decisions%s"):format(unres > 0 and (" — " .. unres .. " open") or ""),
			done = unres == 0,
			next_ = unres > 0,
			run = function()
				open_plan()
				resolve_next_decision()
			end,
		},
		{
			label = "Finalize — bake decisions",
			done = finalized,
			next_ = not finalized and unres == 0,
			lock = unres > 0 and ("resolve " .. unres .. " decision(s) first") or nil,
			run = M.finalize,
		},
		{
			label = "Implement (--go)",
			done = phase == "reconciled",
			next_ = finalized and not implemented,
			lock = not finalized and "finalize first" or nil,
			run = M.go,
		},
		{
			label = "Reconcile — verify code matches plan",
			done = phase == "reconciled",
			next_ = phase == "implementing",
			lock = not implemented and "implement first" or nil,
			run = M.reconcile,
		},
		{ label = "Amend — fold in new scope", run = M.amend },
		{ label = "Ask the agent a question", run = function() open_plan(); M.ask() end },
		{ label = "Open plan buffer", run = open_plan },
	}

	local labels = {}
	for _, e in ipairs(entries) do
		local mark = e.done and "✓ " or e.next_ and "→ " or e.lock and "· " or "  "
		labels[#labels + 1] = mark .. e.label .. (e.lock and ("   (" .. e.lock .. ")") or "")
	end
	vim.ui.select(labels, { prompt = "Plan · " .. key .. " · " .. (phase or status) }, function(_, idx)
		if not idx then return end
		local e = entries[idx]
		if e.lock then
			vim.notify("plan: " .. e.lock, vim.log.levels.WARN)
			return
		end
		e.run()
	end)
end

-- Jump to the first unresolved decision and open its resolve picker.
resolve_next_decision = function()
	for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
		if l:match("%*%*Your call:%*%*") and l:match("_%(unresolved%)_") then
			vim.api.nvim_win_set_cursor(0, { i, 0 })
			-- chain: after this one is written, prompt for the next until none remain
			M.resolve_decision(resolve_next_decision)
			return
		end
	end
	vim.notify("plan: all decisions resolved — v to approve", vim.log.levels.INFO)
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
	-- a surface-area item: legacy table row, or "- **action** `path`" bullet
	if (line:match("^%s*|") or line:match("^%s*%-%s*%*%*%w+%*%*%s*`")) and path_on_line(line) then
		return M.goto_file()
	end
	if line:match("^>%s*❓") then return dispatch_questions() end
	if line:match("^> Status:") then
		-- the Status line is the "advance the plan" control: draft → approve,
		-- planned/amended → finalize, finalized → ready (don't auto-run --go).
		if state.status == "planned" or state.status == "amended" then return M.finalize() end
		if state.status == "finalized" then
			return vim.notify("plan: finalized — run /plan-ticket --go in the worktree", vim.log.levels.INFO)
		end
		return M.approve()
	end
	if in_decision() then return M.resolve_decision() end
	vim.notify("plan: nothing to act on here — <C-p>q ask", vim.log.levels.INFO)
end

-- Worktree-stack entry: wait for the agent's /plan-ticket to write THIS ticket's
-- plan, then open it. Plans live in a shared vault, so we must target the
-- worktree's own ticket (from its branch/dir name) — "newest plan" would grab
-- whatever ticket was touched last. Bounded poll so it works whether the plan
-- lands in 2s or two minutes.
function M.autostart()
	state.root = git_root()
	if not state.root then return end
	local key = plan_key(state.root)
	if not key then return end
	local target = plans_dir() .. "/" .. key .. ".md"
	local function try_open()
		if vim.uv.fs_stat(target) then open_path(target, true); return true end
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

-- Watch the plans dir for THIS worktree's plan to appear, then bind + surface it —
-- covers an nvim already open on a worktree when an agent session runs /plan-ticket
-- there (plan-open sees this pane and defers to it, so nothing else would open it).
-- Opens the plan only from a scratch/dashboard buffer; otherwise just notifies, so it
-- never yanks you out of active editing. No PLAN_NVIM_OPEN needed, unlike autostart.
local function watch_for_plan(key)
	local target = plans_dir() .. "/" .. key .. ".md"
	if state.watcher then pcall(function() state.watcher:close() end) end
	local h = vim.uv.new_fs_event()
	if not h then return end
	state.watcher = h
	pcall(function()
		h:start(plans_dir(), {}, vim.schedule_wrap(function(err)
			if err or state.plan_path then return end
			if not vim.uv.fs_stat(target) then return end
			state.plan_path = target
			read_status()
			read_progress()
			state.last_amended = state.progress and state.progress.amended_at
			state.last_status = state.status
			local cur = vim.api.nvim_get_current_buf()
			local scratch = (vim.api.nvim_buf_get_name(cur) == "" and not vim.bo[cur].modified)
				or vim.bo[cur].filetype == "snacks_dashboard"
			if scratch or want_auto_open() then
				open_path(target, true) -- cockpit / plan pane: surface it in the editor window
			else
				vim.notify("plan: " .. key .. " ready — :PlanOpen to review")
			end
			watch() -- swap to the sidecar watcher now that a plan is bound
		end))
	end)
end

-- Silently bind the session to the worktree's plan so the lualine component and <C-p>
-- work in an ordinary code-editing nvim, not just the --plan stack pane. If the plan
-- exists, bind + watch now; if it doesn't yet (fresh worktree), watch for it to appear.
-- No-op outside a worktree with a derivable plan key.
function M.bind()
	if state.plan_path then return end
	if resolve_plan_path() then
		read_status()
		read_progress()
		state.last_amended = state.progress and state.progress.amended_at -- baselines; open only on a later change
		state.last_status = state.status
		watch()
		return
	end
	local key = plan_key(state.root or git_root())
	if key then watch_for_plan(key) end
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
		-- <C-p> opens the one command center (status + board + every action by hotkey),
		-- same as in code buffers; <CR> still does the smart thing under the cursor.
		map("<C-p>", function() M.menu() end, "plan: menu")
		vim.keymap.set("x", "<C-p>", "<Esc><cmd>lua require('plan-nvim').ask_visual()<CR>",
			{ buffer = buf, desc = "plan: ask about selection" })
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
	vim.api.nvim_create_user_command("PlanFinalize", M.finalize, {})
	vim.api.nvim_create_user_command("PlanGo", M.go, {})
	vim.api.nvim_create_user_command("PlanAmend", M.amend, {})
	vim.api.nvim_create_user_command("PlanReconcile", M.reconcile, {})
	vim.api.nvim_create_user_command("PlanFollow", function()
		state.following = not state.following
		state.follow_user_off = not state.following
		if state.following then
			state.follow_win = vim.api.nvim_get_current_win()
			state.follow_cur = nil
		end
		vim.notify("plan: follow mode " .. (state.following and "on (this window)" or "off"))
	end, {})

	-- Bare <C-p> opens the plan menu from any ordinary buffer (e.g. while
	-- reading the code the agent is touching).
	vim.keymap.set("n", "<C-p>", function() M.menu() end, { desc = "plan: menu" })
	-- Visual Ctrl+P anywhere: chat-only question about the selection.
	vim.keymap.set("x", "<C-p>", "<Esc><cmd>lua require('plan-nvim').ask_visual()<CR>",
		{ desc = "plan: ask about selection" })

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
			state.last_amended = state.progress and state.progress.amended_at
			state.last_status = state.status
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
			state.last_amended = state.progress and state.progress.amended_at
			state.last_status = state.status
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
				-- Only auto-open the plan on a bare launch (no file args). In the cockpit
				-- tab PLAN_NVIM_OPEN/HEIDR_SCOPE are EXPORTED, so `nvim <somefile>` there
				-- would otherwise fire autostart and replace your file with the lovable
				-- plan — opening a note yanked you "into the lovable repo". Honor explicit
				-- file args: bind silently, never clobber the buffer the user asked for.
				if vim.fn.argc() == 0 and want_auto_open() then M.autostart() end
			end, 150)
		end,
	})
end

return M
