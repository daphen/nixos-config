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

	-- Reset the tracked trunk; only the merge-base path (3) sets it, so the
	-- other bases (override / LoL root / HEAD) don't get a stale trunk-move check.
	state.trunk = nil

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
		state.trunk = trunk -- remember it so current_base can watch it move
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
	-- Cheap trunk-move check (one rev-parse, like HEAD): re-resolve when the trunk
	-- advances too — e.g. a mid-session `git fetch origin main`. Without it the base
	-- stays pinned to the trunk sha from when the buffer first opened, so the diff
	-- balloons to every commit merged into trunk since (the review "128 files" bug).
	local trunk_now
	if state.trunk then
		local t = git_exec({ "git", "-C", state.repo_root, "rev-parse", state.trunk })
		trunk_now = t and t[1]
	end
	local head_moved = head and head ~= state.head_sha
	local trunk_moved = state.trunk and trunk_now and trunk_now ~= state.trunk_sha
	if head_moved or trunk_moved or not state.base_sha then
		if head then state.head_sha = head end
		state.base_sha = M.resolve_base(state.repo_root)
		-- resolve_base re-picks the trunk; capture its sha for the next comparison.
		if state.trunk then
			local t = git_exec({ "git", "-C", state.repo_root, "rev-parse", state.trunk })
			state.trunk_sha = t and t[1]
		else
			state.trunk_sha = nil
		end
	end
	return state.base_sha
end

-- Base for an ARBITRARY worktree root, cached per-root. current_base() is keyed to
-- one global repo (the focused buffer's) — wrong for the statusline, which diffs
-- getcwd's worktree while the focused buffer may be a rail pane (agent-composer) or
-- a file in another repo, yielding a base from the wrong repo. This resolves + caches
-- per root, with the same cheap head/trunk-move re-resolution as current_base.
function M.base_for(repo_root)
	if not repo_root or repo_root == "" then return "HEAD" end
	state.bases = state.bases or {}
	local c = state.bases[repo_root]
	if not c then c = {}; state.bases[repo_root] = c end
	local head = git_exec({ "git", "-C", repo_root, "rev-parse", "HEAD" })
	head = head and head[1]
	local trunk_now
	if c.trunk then
		local t = git_exec({ "git", "-C", repo_root, "rev-parse", c.trunk })
		trunk_now = t and t[1]
	end
	if (head and head ~= c.head_sha) or (c.trunk and trunk_now and trunk_now ~= c.trunk_sha) or not c.base then
		if head then c.head_sha = head end
		c.base = M.resolve_base(repo_root)
		c.trunk = state.trunk -- resolve_base records which trunk it used
		if c.trunk then
			local t = git_exec({ "git", "-C", repo_root, "rev-parse", c.trunk })
			c.trunk_sha = t and t[1]
		else
			c.trunk_sha = nil
		end
	end
	return c.base
end

local function fetch_diff(root, base, relpath)
	if not (root and base) then return nil end
	local lines = vim.fn.systemlist({
		"git", "-C", root, "diff", "--no-color",
		base, "--", relpath,
	})
	if vim.v.shell_error ~= 0 then return nil end
	if #lines == 0 then
		-- Untracked files never appear in `git diff <base>`; render them
		-- fully-added so the gutter matches the changed-files picker, which
		-- lists them. --no-index exits 1 on difference, which is expected.
		local tracked = vim.fn.systemlist({
			"git", "-C", root, "ls-files", "--", relpath,
		})
		if vim.v.shell_error == 0 and #tracked == 0 then
			lines = vim.fn.systemlist({
				"git", "-C", root, "diff", "--no-color",
				"--no-index", "--", "/dev/null", relpath,
			})
		end
	end
	return table.concat(lines, "\n")
end

-- Line-level diff of two blocks via LCS (exact-match). Returns an ordered op
-- list: {op="equal"|"add"|"del", ln=<new line>, text=<old text>}. Powers a
-- GitHub-style view: unchanged lines are plain, added lines get a sign, removed
-- lines become ghosts — no pairing guesswork, no "change" state.
local function diff_lines(old, new)
	local m, n = #old, #new
	local dp = {}
	for a = 0, m do dp[a] = {} for b = 0, n do dp[a][b] = 0 end end
	for a = 1, m do for b = 1, n do
		if old[a] == new[b].text then dp[a][b] = dp[a-1][b-1] + 1
		else dp[a][b] = math.max(dp[a-1][b], dp[a][b-1]) end
	end end
	local ops, a, b = {}, m, n
	while a > 0 or b > 0 do
		if a > 0 and b > 0 and old[a] == new[b].text then
			table.insert(ops, 1, { op = "equal", ln = new[b].ln }); a = a - 1; b = b - 1
		elseif b > 0 and (a == 0 or dp[a][b-1] >= dp[a-1][b]) then
			table.insert(ops, 1, { op = "add", ln = new[b].ln }); b = b - 1
		else
			table.insert(ops, 1, { op = "del", text = old[a] }); a = a - 1
		end
	end
	return ops
end

-- Parse a unified diff patch. Returns:
--   marks  = {[new_line_n] = "add"|"delete_below"|"topdelete"}
--   ghosts = {[new_line_n] = {lines = {"old", ...}, above = bool}}  -- removed
--            content shown inline as ghost lines at the position it was removed
local function parse_patch(patch)
	local marks, ghosts = {}, {}
	if not patch or patch == "" then return marks, ghosts end
	local current_new = nil
	local dels = {}   -- old-text of deletions in the current change block
	local adds = {}   -- {ln, text} of additions in the current change block

	-- Resolve one change block by aligning its deletes against its adds: matched
	-- lines stay plain, unmatched adds get an "add" sign, unmatched deletes are
	-- ghosted at their position (above the next real line, or below the last one).
	local function resolve()
		if #dels == 0 and #adds == 0 then return end
		local ops = diff_lines(dels, adds)
		local pending, last_ln = {}, nil
		for _, op in ipairs(ops) do
			if op.op == "del" then
				table.insert(pending, op.text)
			else
				if #pending > 0 then
					ghosts[op.ln] = { lines = pending, above = true }
					pending = {}
				end
				if op.op == "add" then marks[op.ln] = "add" end
				last_ln = op.ln
			end
		end
		if #pending > 0 then
			if last_ln then
				ghosts[last_ln] = { lines = pending, above = false }
				marks[last_ln] = marks[last_ln] or "delete_below"
			else
				local prev = (current_new or 1) - 1
				if prev >= 1 then
					ghosts[prev] = { lines = pending, above = false }
					marks[prev] = marks[prev] or "delete_below"
				else
					ghosts[current_new] = { lines = pending, above = true }
					marks[current_new] = "topdelete"
				end
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
				table.insert(adds, { ln = current_new, text = line:sub(2) })
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
	return marks, ghosts
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

local function draw(bufnr, marks, ghosts)
	vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	local seen = {}
	for ln in pairs(marks) do seen[ln] = true end
	for ln in pairs(ghosts) do seen[ln] = true end
	for ln in pairs(seen) do
		if ln >= 1 and ln <= line_count then
			local opts = { invalidate = true }
			local kind = marks[ln]
			if kind then
				local sign, sign_hl = kind_to_sign(kind)
				opts.sign_text = sign
				opts.sign_hl_group = sign_hl
				opts.line_hl_group = M.config.linehl and kind_to_linehl(kind) or nil
			end
			local g = ghosts[ln]
			if M.config.deleted_virt_lines and g and #g.lines > 0 then
				local virt = {}
				for _, dl in ipairs(g.lines) do
					table.insert(virt, { { dl, "GitSignsDeleteVirtLn" } })
				end
				opts.virt_lines = virt
				opts.virt_lines_above = g.above
			end
			pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, ln - 1, 0, opts)
		end
	end
end

-- Resolve the buffer's OWN repo root, not a single global one fixed at setup.
-- The cockpit runs one nvim across many worktrees (contexts) — a file in any
-- worktree other than the startup cwd would otherwise fail to match state.repo_root
-- and get no signs. Mirrors lualine's per-root base_for; cached one rev-parse deep.
local function buf_repo(bufnr)
	local abs = vim.api.nvim_buf_get_name(bufnr)
	if abs == "" then return nil end
	local dir = vim.fn.fnamemodify(abs, ":h")
	local out = git_exec({ "git", "-C", dir, "rev-parse", "--show-toplevel" })
	if not out or #out == 0 then return nil end
	return out[1], abs
end

function M.refresh(bufnr)
	if not state.enabled then return end
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not vim.api.nvim_buf_is_loaded(bufnr) then return end
	local root, abs = buf_repo(bufnr)
	if not root then return end
	local prefix = root .. "/"
	if abs:sub(1, #prefix) ~= prefix then return end
	local relpath = abs:sub(#prefix + 1)
	local base = M.base_for(root)
	local patch = fetch_diff(root, base, relpath)
	if not patch then
		vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
		return
	end
	local marks, ghosts = parse_patch(patch)
	draw(bufnr, marks, ghosts)
end

local function debounced_refresh(bufnr)
	local t = state.debounce_timers[bufnr]
	if t then t:stop() end
	state.debounce_timers[bufnr] = vim.defer_fn(function()
		state.debounce_timers[bufnr] = nil
		M.refresh(bufnr)
	end, M.config.debounce_ms)
end

-- On native external reloads, refresh the cached base if HEAD moved and repaint every visible buffer.
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
	vim.api.nvim_create_autocmd("FileChangedShellPost", {
		group = group,
		callback = on_external_change,
	})

	vim.api.nvim_create_user_command("HunkSignsRefresh", function() M.refresh() end, {})
	vim.api.nvim_create_user_command("HunkSignsToggleLinehl", function() M.toggle_linehl() end, {})
	vim.api.nvim_create_user_command("HunkSignsToggleDeleted", function() M.toggle_deleted() end, {})


	debounced_refresh(vim.api.nvim_get_current_buf())
end

return M
