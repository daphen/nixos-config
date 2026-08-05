-- Event-driven tree watcher: follows files changed by external tools
-- (agents, formatters, anything). One inotify watch per git-known
-- directory — no polling, no plugin dependencies.

local M = {}

M.opts = {
	-- Extra lua patterns appended to the built-in ignore list.
	ignore_patterns = {},
	-- Suppress auto-jump for this long after a jump, so cascading tool
	-- reactions (gopls rewriting go.work.sum etc.) can't chain-yank focus.
	jump_cooldown_ms = 2000,
}

local state = {
	running = false,
	root = nil,
	-- Auto-navigate (jump the editor to a changed file) is OFF by default: the
	-- agent-rail's follow_edit is the canonical live-follow (rail-aware, no focus
	-- steal, targets the hunk line), and two followers racing the same window was
	-- a real bug. The watcher's OTHER jobs — reload changed buffers (checktime) and
	-- emit User FileWatcherChanged for hunk-nvim signs — still run unconditionally.
	-- :lua require('file-watcher').toggle_follow() re-enables the jump standalone.
	follow = false,
	handles = {},
	dir_count = 0,
	last_user_move = 0,
	last_jump = 0,
	last_skip = nil,
	pending_nav = nil,
	nav_timer = nil,
	defer_late = nil,
	content_sig = {},
	ignored_dirs = {},
	trace = {},
}

local function trace(msg)
	table.insert(state.trace, os.date("%H:%M:%S ") .. msg)
	if #state.trace > 100 then table.remove(state.trace, 1) end
end

local IGNORED_PATTERNS = {
	"%.tsbuildinfo$",
	"%.log$",
	"%.lock$",
	"%.min%.js$",
	"%.min%.css$",
	"%.gen%.",
	"go%.sum$",
	"go%.work%.sum$",
	"%-lock%.json$",
	"/pnpm%-lock%.yaml$",
	"/node_modules/",
	"/dist/",
	"/build/",
	"/%.next/",
	"/coverage/",
	"%.snap$",
	"/%.git/",
	"/%.wrangler/",
	-- inlang/paraglide regenerates esbuild plugin bundles here on every dev
	-- boot; static skip so it never depends on a git check winning the race.
	"%.inlang/cache/",
}

local function should_skip(path)
	for _, pat in ipairs(IGNORED_PATTERNS) do
		if path:match(pat) then return true end
	end
	for _, pat in ipairs(M.opts.ignore_patterns) do
		if path:match(pat) then return true end
	end
	return false
end

local function content_unchanged(path)
	local stat = vim.uv.fs_stat(path)
	if not stat or stat.size > 2 * 1024 * 1024 then return false end
	local f = io.open(path, "rb")
	if not f then return false end
	local data = f:read("*a") or ""
	f:close()
	-- NUL bytes turn the string into a Blob, which sha256() rejects.
	if data:find("\0", 1, true) then return false end
	local sig = vim.fn.sha256(data)
	if state.content_sig[path] == sig then return true end
	state.content_sig[path] = sig
	return false
end

local function repo_of(path)
	if not path or path == "" then return nil end
	local dir = vim.fn.fnamemodify(path, ":h")
	local r = vim.fn.systemlist({ "git", "-C", dir, "rev-parse", "--show-toplevel" })[1]
	if not r or r == "" then return nil end
	return r
end

local function pick_target_window()
	local ok, rail = pcall(require, "agent-nvim")
	local shared = ok and rail.editor_win and rail.editor_win()
	if shared then return shared end
	local function is_editor(w)
		local cfg = vim.api.nvim_win_get_config(w)
		if cfg.relative ~= "" then return false end
		local b = vim.api.nvim_win_get_buf(w)
		return vim.bo[b].buftype == ""
			and not vim.api.nvim_buf_get_name(b):match("agent%-")
	end
	local cur = vim.api.nvim_get_current_win()
	if is_editor(cur) then return cur end
	for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if is_editor(w) then return w end
	end
	return nil -- no editor window → caller skips rather than clobber a rail pane
end

local function git_first_changed_line(root, rel)
	local out = vim.fn.systemlist({ "git", "-C", root, "diff", "-U0", "HEAD", "--", rel })
	if vim.v.shell_error ~= 0 then return 1 end
	for _, l in ipairs(out) do
		local n = l:match("^@@ %-%d+,?%d* %+(%d+)")
		if n then return tonumber(n) end
	end
	return 1
end

local function navigate_to_path(path)
	if not state.follow then state.last_skip = "follow=OFF"; return end
	if should_skip(path) then state.last_skip = "ignored pattern"; return end
	if vim.api.nvim_get_mode().mode ~= "n" then
		state.last_skip = "mode=" .. vim.api.nvim_get_mode().mode
		return
	end
	if (vim.uv.now() - state.last_user_move) < 800 then
		state.last_skip = "user-active"
		return
	end
	local changed_repo = repo_of(path)
	if not changed_repo then state.last_skip = "no repo for " .. path; return end
	-- Follow anything under the watched worktree (state.root). The old guard compared
	-- the changed file's repo to the CURRENT BUFFER's repo, which broke follow in the
	-- cockpit: you view the vault plan (a different repo) while the agent edits the
	-- worktree, so every edit was skipped as "repo mismatch". The watcher only queues
	-- paths under state.root, so that is the correct boundary.
	if state.root and not (path == state.root or path:sub(1, #state.root + 1) == state.root .. "/") then
		state.last_skip = "outside watched root"
		return
	end
	if (vim.uv.now() - state.last_jump) < M.opts.jump_cooldown_ms then
		state.last_skip = "jump cooldown"
		return
	end
	-- Atomic-rename temp files (sedXXXXXX, editor swaps) are gone by the
	-- time the coalescer fires — never navigate to a dead path.
	if not vim.uv.fs_stat(path) then
		state.last_skip = "vanished"
		return
	end
	-- No-op rewrites (gopls touching go.work.sum, formatters) change
	-- mtime but not content — never worth a jump.
	if content_unchanged(path) then
		state.last_skip = "content unchanged"
		return
	end
	local rel = path:sub(#state.root + 2)
	-- Tracked and identical to HEAD/index = no-op write (boot-time codegen,
	-- tools rewriting committed output). git is the authority on "changed".
	local porcelain = vim.fn.systemlist({ "git", "-C", state.root, "status", "--porcelain", "--", rel })[1]
	if vim.v.shell_error == 0 and not porcelain then
		state.last_skip = "clean in git (no-op write)"
		return
	end
	state.last_skip = nil
	state.last_jump = vim.uv.now()
	-- Line lookup shells out to git — only pay after every guard passed.
	local line = git_first_changed_line(state.root, rel)
	local target = pick_target_window()
	if not target then state.last_skip = "no editor window"; return end -- never open into a rail pane
	pcall(vim.api.nvim_set_current_win, target)
	pcall(vim.cmd, "edit " .. vim.fn.fnameescape(path))
	pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
	pcall(vim.cmd, "normal! zz")
end

local function queue_nav(fullpath)
	-- Filter junk BEFORE coalescing — guards run on the pending slot, so an
	-- artifact event arriving after a real edit would displace and kill the
	-- good jump.
	if should_skip(fullpath) then
		trace("skip-pattern " .. fullpath)
		return
	end
	trace("queue " .. fullpath)
	-- Coalesce bursts: one navigation per quiet 150ms, newest change wins.
	state.pending_nav = fullpath
	state.nav_timer = state.nav_timer or vim.uv.new_timer()
	state.nav_timer:stop()
	state.nav_timer:start(150, 0, vim.schedule_wrap(function()
		local p = state.pending_nav
		state.pending_nav = nil
		if p then
			-- Reload buffers whose file changed on disk (agent edits, rebase, …) so
			-- the buffer text matches disk BEFORE hunk-nvim redraws its signs —
			-- otherwise a stale buffer shows no diff and the git-based signs land on
			-- the wrong lines. autoread (on) makes this reload unmodified buffers
			-- silently; a buffer with unsaved edits is left alone (no clobber).
			pcall(vim.cmd, "checktime")
			-- Decoupled from the nav gates below: subscribers (hunk-nvim) want
			-- the signal even when the cursor jump is suppressed.
			pcall(vim.api.nvim_exec_autocmds, "User",
				{ pattern = "FileWatcherChanged", data = { path = p, root = state.root } })
			navigate_to_path(p)
			trace((state.last_skip and ("skip: " .. state.last_skip) or "JUMP") .. " " .. p)
		end
	end))
end

local watch_dir

local function on_change(fullpath)
	local stat = vim.uv.fs_stat(fullpath)
	if stat and stat.type == "directory" then
		-- Walking an already-watched dir would cascade on every entry change.
		if state.handles[fullpath] then return end
		if should_skip(fullpath .. "/") then return end
		-- Never watch gitignored trees (wrangler tmp, build output): one
		-- new-dir event here once ballooned the watch set 5k → 30k dirs.
		if state.ignored_dirs[fullpath] == nil then
			vim.fn.system({ "git", "-C", state.root, "check-ignore", "-q", fullpath:sub(#state.root + 2) })
			state.ignored_dirs[fullpath] = (vim.v.shell_error == 0)
		end
		if state.ignored_dirs[fullpath] then return end
		watch_dir(fullpath)
		for name, t in vim.fs.dir(fullpath, { depth = 8 }) do
			local child = vim.fs.joinpath(fullpath, name)
			if t == "directory" then
				watch_dir(child)
			elseif t == "file" then
				queue_nav(child)
			end
		end
	elseif stat then
		queue_nav(fullpath)
	else
		local h = state.handles[fullpath]
		if h then
			-- Watched directory disappeared; drop its handle.
			pcall(function() h:close() end)
			state.handles[fullpath] = nil
			state.dir_count = state.dir_count - 1
		end
	end
end

watch_dir = function(dir)
	if state.handles[dir] then return end
	local h = vim.uv.new_fs_event()
	if not h then return end
	state.handles[dir] = h
	state.dir_count = state.dir_count + 1
	local ok = h:start(dir, {}, function(err, filename)
		if err or not filename then return end
		local fullpath = vim.fs.joinpath(dir, filename)
		vim.schedule(function() on_change(fullpath) end)
	end)
	if not ok then
		pcall(function() h:close() end)
		state.handles[dir] = nil
		state.dir_count = state.dir_count - 1
	end
end

-- Tear down every watch (used to re-root onto a new worktree on session switch).
function M.stop()
	for _, h in pairs(state.handles) do pcall(function() h:close() end) end
	state.handles = {}
	state.dir_count = 0
	state.running = false
	state.content_sig = {} -- root-scoped caches; drop so the new root re-derives clean
	state.ignored_dirs = {}
	state.pending_nav = nil
end

function M.start()
	local root = vim.fn.getcwd()
	-- Re-root on cwd change: a roster/session switch tcd's to that session's
	-- worktree, so follow must move with it. No-op if the root is unchanged; else
	-- tear down and rebuild on the new root (was pinned to nvim's first cwd forever).
	if state.running and state.root == root then return end
	if state.running then M.stop() end
	local t0 = vim.uv.hrtime()
	local files = vim.fn.systemlist({
		"git", "-C", root, "ls-files", "--cached", "--others", "--exclude-standard",
	})
	if vim.v.shell_error ~= 0 then
		vim.notify("file-watcher: not a git repo, not watching", vim.log.levels.WARN)
		return
	end
	local t_git = (vim.uv.hrtime() - t0) / 1e6
	state.running = true
	state.root = root
	local dir_set = { [root] = true }
	for _, f in ipairs(files) do
		local d = vim.fs.dirname(f)
		while d and d ~= "." and d ~= "/" do
			local abs = vim.fs.joinpath(root, d)
			if dir_set[abs] then break end
			dir_set[abs] = true
			d = vim.fs.dirname(d)
		end
	end
	for dir in pairs(dir_set) do
		watch_dir(dir)
	end
	local total = (vim.uv.hrtime() - t0) / 1e6
	vim.notify(("file-watcher: watching %s (%d dirs, git=%dms, total=%dms, late=%dms)")
		:format(root, state.dir_count, t_git, total, state.defer_late or -1), vim.log.levels.DEBUG)
end

function M.toggle_follow()
	state.follow = not state.follow
	vim.notify("file-watcher: follow " .. (state.follow and "ON" or "OFF"))
end

function M.setup(opts)
	M.opts = vim.tbl_deep_extend("force", M.opts, opts or {})
	if vim.env.KITTY_SCROLLBACK_NVIM == "true" then return end

	local group = vim.api.nvim_create_augroup("FileWatcher", { clear = true })
	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "InsertEnter" }, {
		group = group,
		callback = function() state.last_user_move = vim.uv.now() end,
	})

	vim.api.nvim_create_user_command("FileWatcherLog", function()
		vim.cmd("botright 15new")
		local b = vim.api.nvim_get_current_buf()
		vim.api.nvim_buf_set_lines(b, 0, -1, false, state.trace)
		vim.bo[b].buftype = "nofile"
		vim.bo[b].bufhidden = "wipe"
	end, {})

	vim.api.nvim_create_user_command("FileWatcherStatus", function()
		local msg = ("file-watcher: %s, follow=%s, dirs=%d"):format(
			state.running and ("watching " .. state.root) or "not running",
			state.follow and "ON" or "OFF", state.dir_count)
		if state.last_skip then msg = msg .. "\n  last skip: " .. state.last_skip end
		vim.notify(msg)
	end, {})

	-- Logs main-loop stalls >500ms to /tmp for postmortem.
	do
		local logfile = "/tmp/nvim-lag-" .. vim.fn.getpid() .. ".log"
		local hb = vim.uv.new_timer()
		local last = vim.uv.hrtime()
		hb:start(1000, 1000, function()
			local now = vim.uv.hrtime()
			local lag = (now - last) / 1e6 - 1000
			last = now
			if lag > 500 then
				local f = io.open(logfile, "a")
				if f then
					f:write(("%s lag=%dms\n"):format(os.date("%H:%M:%S"), lag))
					f:close()
				end
			end
		end)
	end

	vim.keymap.set("n", "<leader>fs", M.start, { desc = "file-watcher: start watching cwd" })
	vim.keymap.set("n", "<C-g>t", M.toggle_follow, { desc = "file-watcher: toggle follow" })

	-- No auto-start in notes windows or non-repos (watching $HOME freezes nvim).
	if vim.env.FS_MONITOR_DISABLED ~= "1" then
		local scheduled = vim.uv.hrtime()
		vim.defer_fn(function()
			state.defer_late = math.floor((vim.uv.hrtime() - scheduled) / 1e6 - 1500)
			local in_repo = vim.fn.systemlist({
				"git", "-C", vim.fn.getcwd(), "rev-parse", "--show-toplevel",
			})[1]
			if in_repo and in_repo ~= "" then M.start() end
		end, 1500)
	end
end

return M

