--[[
hunk-nvim/signs — inline diff overlay in nvim buffers driven by git diff
against the Lovable init commit (the `[skip lovable] Initialize Lovable
project` commit), independent of hunk's daemon entirely.

- Signs in the gutter: │ for add/change, _ for delete-below, ‾ for topdelete
- Whole-line linehl: green for adds, red-ish for changes (toggle: <C-g>o)
- virt_lines: ghost lines showing the deleted content right where it was
  removed, so deletions are visible inline (toggle: :HunkSignsToggleDeleted)
- ]h / [h: walk between hunks
- Self-gates on git repo + reachable base commit

Works even in the sandbox's broken/shallow history because we only need
two endpoints (base and working tree), no history traversal.
]]

local M = {}

M.config = {
	-- Default to signs-only (gutter + virt_lines for deletions). Whole-line
	-- bg tint can be turned on per-session with :HunkSignsToggleLinehl or
	-- permanently via vim.g.hunk_signs_linehl = true in user config.
	linehl = false,
	deleted_virt_lines = true,
	debounce_ms = 200,
}

local NS = vim.api.nvim_create_namespace("hunk-signs")

local state = {
	enabled = false,
	repo_root = nil,
	base_sha = nil,
	debounce_timers = {},
}

local function git_exec(args)
	local out = vim.fn.systemlist(args)
	if vim.v.shell_error ~= 0 then return nil end
	return out
end

-- Source-agnostic base resolution. Priority:
--   1. Explicit override via HUNK_SIGNS_BASE env var or vim.g.hunk_signs_base
--   2. Lovable user-project init commit (only when it's a true root — its
--      [skip lovable] subject appears in test fixtures inside the monorepo
--      itself, so we guard on parent-count to avoid false positives)
--   3. merge-base with auto-detected trunk (origin/HEAD → main → master)
--   4. HEAD — gitsigns-like "uncommitted changes only" as a last resort
--
-- Exposed as M.resolve_base so other callers (e.g. the snacks picker) can
-- use the same base and stay in sync with the inline overlay.
function M.resolve_base(repo_root)
	repo_root = repo_root or state.repo_root
	if not repo_root then
		local out = vim.fn.systemlist({ "git", "-C", vim.fn.getcwd(), "rev-parse", "--show-toplevel" })
		if vim.v.shell_error ~= 0 or #out == 0 then return nil end
		repo_root = out[1]
	end

	-- 1. Explicit override
	local override = vim.g.hunk_signs_base
	if override and override ~= "" then return override end
	local env = vim.fn.getenv("HUNK_SIGNS_BASE")
	if env and env ~= vim.NIL and env ~= "" then return env end

	-- 2. LoL true-root init commit. It is always a parentless root, so scan
	-- roots reachable from HEAD instead of grepping full history (~0.5s in a
	-- large repo vs ~30ms for roots). Restricting to roots also skips the same
	-- subject in monorepo test fixtures, which aren't roots.
	local roots = git_exec({ "git", "-C", repo_root, "rev-list", "--max-parents=0", "HEAD" })
	if roots then
		for _, root in ipairs(roots) do
			local subj = git_exec({ "git", "-C", repo_root, "log", "-1", "--format=%s", root })
			if subj and subj[1]
				and subj[1]:find("[skip lovable] Initialize Lovable project", 1, true) then
				return root
			end
		end
	end

	-- 3. Branch fork point
	local trunk
	local origin_head = git_exec({
		"git", "-C", repo_root,
		"symbolic-ref", "--short", "refs/remotes/origin/HEAD",
	})
	if origin_head and #origin_head > 0 then trunk = origin_head[1] end
	if not trunk then
		for _, candidate in ipairs({ "main", "master", "origin/main", "origin/master" }) do
			if git_exec({ "git", "-C", repo_root, "rev-parse", "--verify", "--quiet", candidate }) then
				trunk = candidate
				break
			end
		end
	end
	if trunk then
		local mb = git_exec({ "git", "-C", repo_root, "merge-base", "HEAD", trunk })
		if mb and #mb > 0 then return mb[1] end
	end

	-- 4. Fall back to HEAD (gitsigns-like uncommitted-only view)
	return "HEAD"
end

-- Cheap accessor for the cached base, shared by the gutter, the changed-files
-- picker, and diffview so all three read one identical value. resolve_base
-- scans history (~hundreds of ms in a large repo), so gate it behind a
-- rev-parse: only re-resolve when HEAD actually moved (rebase/commit/checkout).
function M.current_base()
	if not state.repo_root then return M.resolve_base() end
	local head = git_exec({ "git", "-C", state.repo_root, "rev-parse", "HEAD" })
	head = head and head[1]
	if head and head ~= state.head_sha then
		state.head_sha = head
		state.base_sha = M.resolve_base(state.repo_root)
	elseif not state.base_sha then
		state.base_sha = M.resolve_base(state.repo_root)
	end
	return state.base_sha
end

local function fetch_diff(relpath)
	if not state.base_sha then return nil end
	local lines = vim.fn.systemlist({
		"git", "-C", state.repo_root, "diff", "--no-color",
		state.base_sha, "--", relpath,
	})
	if vim.v.shell_error ~= 0 then return nil end
	if #lines == 0 then
		-- Untracked files never appear in `git diff <base>`; render them
		-- fully-added so the gutter matches the changed-files picker, which
		-- lists them. --no-index exits 1 on difference, which is expected.
		local tracked = vim.fn.systemlist({
			"git", "-C", state.repo_root, "ls-files", "--", relpath,
		})
		if vim.v.shell_error == 0 and #tracked == 0 then
			lines = vim.fn.systemlist({
				"git", "-C", state.repo_root, "diff", "--no-color",
				"--no-index", "--", "/dev/null", relpath,
			})
		end
	end
	return table.concat(lines, "\n")
end

-- Parse a unified diff patch. Returns:
--   marks       = {[new_line_n] = "add"|"change"|"delete_below"|"topdelete"}
--   deletes     = {[new_line_n] = {"deleted line content", ...}}  -- pure deletes
--   changes_old = {[new_line_n] = {"old line", ...}}                -- the deleted
--                        block, ghosted ONCE above the first changed line
local function parse_patch(patch)
	local marks, deletes, changes_old = {}, {}, {}
	if not patch or patch == "" then return marks, deletes, changes_old end
	local current_new = nil
	local dels = {}   -- old-text of deletions in the current change block
	local adds = {}   -- new-file line numbers of additions in the current block

	-- Resolve one change block (a run of -/+ lines).
	--  * Extra LEADING adds beyond the delete count are pure insertions (e.g.
	--    comments added above an edited line) -> "add", not "change".
	--  * The deleted lines are shown ONCE as a ghost block above the first
	--    changed line -> a multi-line rewrite reads as before/after blocks,
	--    never interleaved old/new/old/new.
	local function resolve()
		local D, A = #dels, #adds
		if A > 0 and D > 1 then
			-- Multi-line block rewrite: show the whole old block once, above the
			-- first new line, and mark the whole new block "change". Avoids the
			-- fragmented add / old-ghost / change split git produces when a
			-- reworded paragraph aligns some new lines as adds and some as changes.
			for i = 1, A do marks[adds[i]] = "change" end
			changes_old[adds[1]] = dels
		elseif A > 0 then
			-- Pure adds (D==0) or a single-line edit (D==1) possibly with lines
			-- inserted above it: leading adds stay insertions, the one deleted
			-- line ghosts above the add that actually replaced it.
			local paired = math.min(D, A)
			for i = 1, A - paired do
				if marks[adds[i]] == nil then marks[adds[i]] = "add" end
			end
			for i = 1, paired do
				marks[adds[A - paired + i]] = "change"
			end
			if paired > 0 and D > 0 then
				changes_old[adds[A - paired + 1]] = dels
			end
		elseif D > 0 then
			local prev = (current_new or 1) - 1
			if prev >= 1 then
				if marks[prev] == nil then marks[prev] = "delete_below" end
				deletes[prev] = dels
			else
				marks[current_new] = "topdelete"
				deletes[current_new] = dels
			end
		end
		dels, adds = {}, {}
	end

	for line in (patch .. "\n"):gmatch("([^\n]*)\n") do
		local n_start = line:match("^@@ %-%d+,?%d* %+(%d+)")
		if n_start then
			resolve()
			current_new = tonumber(n_start)
		elseif current_new then
			local first = line:sub(1, 1)
			if first == "+" and line:sub(1, 3) ~= "+++" then
				table.insert(adds, current_new)
				current_new = current_new + 1
			elseif first == "-" and line:sub(1, 3) ~= "---" then
				table.insert(dels, line:sub(2))
			elseif first == " " or first == "" then
				resolve()
				current_new = current_new + 1
			end
		end
	end
	resolve()
	return marks, deletes, changes_old
end
local function kind_to_sign(kind)
	if kind == "add" then return "▎", "GitSignsAdd" end
	if kind == "change" then return "▎", "GitSignsChange" end
	if kind == "delete_below" then return "▁", "GitSignsDelete" end
	if kind == "topdelete" then return "▔", "GitSignsDelete" end
end

local function kind_to_linehl(kind)
	if kind == "add" then return "GitSignsAddLn" end
	if kind == "change" then return "GitSignsChangeLn" end
end

local function draw(bufnr, marks, deletes, changes_old)
	vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	for ln, kind in pairs(marks) do
		if ln >= 1 and ln <= line_count then
			local sign, sign_hl = kind_to_sign(kind)
			local opts = {
				sign_text = sign,
				sign_hl_group = sign_hl,
				line_hl_group = M.config.linehl and kind_to_linehl(kind) or nil,
				invalidate = true,
			}
			if M.config.deleted_virt_lines then
				if kind == "change" and changes_old and changes_old[ln] then
					-- Show the whole deleted block as ghost lines above this
					-- (the first changed line). New lines stay below, so a
					-- multi-line rewrite reads as before-block / after-block.
					local virt = {}
					for _, dl in ipairs(changes_old[ln]) do
						table.insert(virt, { { dl, "GitSignsDeleteVirtLn" } })
					end
					opts.virt_lines = virt
					opts.virt_lines_above = true
				elseif deletes[ln] and #deletes[ln] > 0 then
					local virt = {}
					for _, dl in ipairs(deletes[ln]) do
						table.insert(virt, { { dl, "GitSignsDeleteVirtLn" } })
					end
					opts.virt_lines = virt
					opts.virt_lines_above = (kind == "topdelete")
				end
			end
			pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, ln - 1, 0, opts)
		end
	end
end

local function buf_relpath(bufnr)
	local abs = vim.api.nvim_buf_get_name(bufnr)
	if abs == "" or not state.repo_root then return nil end
	local prefix = state.repo_root .. "/"
	if abs:sub(1, #prefix) ~= prefix then return nil end
	return abs:sub(#prefix + 1)
end

function M.refresh(bufnr)
	if not state.enabled then return end
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not vim.api.nvim_buf_is_loaded(bufnr) then return end
	local relpath = buf_relpath(bufnr)
	if not relpath then return end
	local patch = fetch_diff(relpath)
	if not patch then
		vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
		return
	end
	local marks, deletes, changes_old = parse_patch(patch)
	draw(bufnr, marks, deletes, changes_old)
end

local function debounced_refresh(bufnr)
	local t = state.debounce_timers[bufnr]
	if t then t:stop() end
	state.debounce_timers[bufnr] = vim.defer_fn(function()
		state.debounce_timers[bufnr] = nil
		M.refresh(bufnr)
	end, M.config.debounce_ms)
end

-- On external changes (rebase, agent edits) signalled by file-watcher, refresh
-- the cached base if HEAD moved and repaint every visible buffer. No polling.
-- M.current_base gates the expensive resolve behind a rev-parse, so an ordinary
-- save pays ~3ms here, not the full history scan.
local function on_external_change()
	if not state.enabled then return end
	if state.external_timer then state.external_timer:stop() end
	state.external_timer = vim.defer_fn(function()
		state.external_timer = nil
		M.current_base()
		local seen = {}
		for _, win in ipairs(vim.api.nvim_list_wins()) do
			local b = vim.api.nvim_win_get_buf(win)
			if not seen[b] and vim.api.nvim_buf_is_loaded(b) then
				seen[b] = true
				M.refresh(b)
			end
		end
	end, M.config.debounce_ms)
end

local function get_hunk_starts(bufnr)
	local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, {})
	local lines = {}
	for _, m in ipairs(extmarks) do table.insert(lines, m[2] + 1) end
	table.sort(lines)
	local starts, last = {}, nil
	for _, ln in ipairs(lines) do
		if last == nil or ln > last + 1 then table.insert(starts, ln) end
		last = ln
	end
	return starts
end

function M.next_hunk()
	local cur = vim.api.nvim_win_get_cursor(0)[1]
	local starts = get_hunk_starts(vim.api.nvim_get_current_buf())
	for _, ln in ipairs(starts) do
		if ln > cur then vim.api.nvim_win_set_cursor(0, { ln, 0 }); return end
	end
	if #starts > 0 then vim.api.nvim_win_set_cursor(0, { starts[1], 0 }) end
end

function M.prev_hunk()
	local cur = vim.api.nvim_win_get_cursor(0)[1]
	local starts = get_hunk_starts(vim.api.nvim_get_current_buf())
	for i = #starts, 1, -1 do
		if starts[i] < cur then vim.api.nvim_win_set_cursor(0, { starts[i], 0 }); return end
	end
	if #starts > 0 then vim.api.nvim_win_set_cursor(0, { starts[#starts], 0 }) end
end

function M.toggle_linehl()
	M.config.linehl = not M.config.linehl
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(bufnr) then M.refresh(bufnr) end
	end
end

function M.toggle_deleted()
	M.config.deleted_virt_lines = not M.config.deleted_virt_lines
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(bufnr) then M.refresh(bufnr) end
	end
end

function M.setup(opts)
	if state.enabled then return end
	opts = opts or {}
	-- vim.g.hunk_signs_linehl / hunk_signs_deleted let users override defaults
	-- without passing opts (handy when our config dir is read-only / managed).
	if vim.g.hunk_signs_linehl ~= nil then opts.linehl = vim.g.hunk_signs_linehl end
	if vim.g.hunk_signs_deleted ~= nil then opts.deleted_virt_lines = vim.g.hunk_signs_deleted end
	M.config = vim.tbl_extend("force", M.config, opts)

	local out = git_exec({ "git", "-C", vim.fn.getcwd(), "rev-parse", "--show-toplevel" })
	if not out or #out == 0 then return end
	state.repo_root = out[1]

	state.head_sha = (git_exec({ "git", "-C", state.repo_root, "rev-parse", "HEAD" }) or {})[1]
	state.base_sha = M.resolve_base(state.repo_root)
	if not state.base_sha then return end
	state.enabled = true

	local group = vim.api.nvim_create_augroup("HunkSigns", { clear = true })
	vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost", "InsertLeave", "FocusGained" }, {
		group = group,
		callback = function(ev) debounced_refresh(ev.buf) end,
	})
	vim.api.nvim_create_autocmd("User", {
		group = group,
		pattern = "FileWatcherChanged",
		callback = on_external_change,
	})

	vim.api.nvim_create_user_command("HunkSignsRefresh", function() M.refresh() end, {})
	vim.api.nvim_create_user_command("HunkSignsToggleLinehl", function() M.toggle_linehl() end, {})
	vim.api.nvim_create_user_command("HunkSignsToggleDeleted", function() M.toggle_deleted() end, {})


	debounced_refresh(vim.api.nvim_get_current_buf())
end

return M
