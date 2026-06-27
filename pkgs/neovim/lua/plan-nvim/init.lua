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

local state = {
	root = nil,
	plan_path = nil,
	status = nil,
	watcher = nil,
}

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

-- lualine component: require("plan-nvim").statusline()
function M.statusline()
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

local function insert_after_cursor(lines)
	local buf = vim.api.nvim_get_current_buf()
	local row = vim.api.nvim_win_get_cursor(0)[1]
	local block = { "" }
	vim.list_extend(block, lines)
	vim.api.nvim_buf_set_lines(buf, row, row, false, block)
	vim.cmd("silent write")
end

-- Best-effort: if the cwd is a worktree, ask that worktree's claude to answer the
-- plan's open questions inline. wt-send types + submits into the running TUI.
local function dispatch_questions()
	local name = vim.fn.getcwd():match("/work/lovable%.daphen%-([^/]+)")
	if not name then
		vim.notify("plan: question saved (no worktree claude to dispatch to from here)", vim.log.levels.INFO)
		return
	end
	local msg = ("Answer the open `> ❓` questions in %s — write each answer inline "
		.. "directly below its question as `> 💬 <answer>`, reading the repo as needed. "
		.. "Don't change code."):format(state.plan_path or "the open plan")
	vim.system({ "wt-send", "--wait", "8", name, msg })
	vim.notify("plan: dispatched to the " .. name .. " session — answers land inline")
end

function M.add_note()
	compose("📝 note", function(text) insert_after_cursor(quote_block("📝", text)) end)
end

function M.ask()
	compose("❓ ask the agent", function(text)
		insert_after_cursor(quote_block("❓", text))
		dispatch_questions()
	end)
end

-- Worktree-stack entry: wait for the agent's /plan-ticket to write the plan, then
-- open it. Bounded poll (readdir is cheap, .plans/ may not exist yet at startup),
-- so it works whether the plan lands in 2s or two minutes.
function M.autostart()
	state.root = git_root()
	if not state.root then return end
	local function try_open()
		local plans = list_plans(state.root)
		if #plans > 0 then open_path(plans[1]); return true end
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

function M.setup()
	vim.api.nvim_create_user_command("PlanOpen", function(o) M.open(o.args) end, { nargs = "?" })
	vim.api.nvim_create_user_command("PlanGoto", M.goto_file, {})
	vim.api.nvim_create_user_command("PlanDecide", M.resolve_decision, {})
	vim.api.nvim_create_user_command("PlanApprove", M.approve, {})
	vim.api.nvim_create_user_command("PlanReload", function() read_status() end, {})
	vim.api.nvim_create_user_command("PlanAsk", M.ask, {})
	vim.api.nvim_create_user_command("PlanNote", M.add_note, {})

	-- Buffer-local maps only inside a plan file, so they never clobber normal
	-- markdown editing elsewhere.
	vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
		pattern = { "*/.plans/*.md", "*/personal/notes/storage/plans/*.md" },
		callback = function(ev)
			state.plan_path = vim.api.nvim_buf_get_name(ev.buf)
			state.root = git_root()
			read_status()
			watch()
			local map = function(lhs, fn, desc)
				vim.keymap.set("n", lhs, fn, { buffer = ev.buf, desc = desc })
			end
			map("<CR>", M.goto_file, "plan: open file under cursor")
			map("<leader>pd", M.resolve_decision, "plan: resolve decision")
			map("<leader>pa", M.approve, "plan: approve (draft→planned)")
			map("<leader>pq", M.ask, "plan: ask the agent (inline)")
			map("<leader>pn", M.add_note, "plan: add a note")
		end,
	})

	-- Set by ws-createwt on the worktree's nvim pane only, so ordinary nvim
	-- sessions never auto-open a plan.
	if vim.env.PLAN_NVIM_OPEN == "1" then
		vim.api.nvim_create_autocmd("VimEnter", { once = true, callback = function() M.autostart() end })
	end
end

return M
