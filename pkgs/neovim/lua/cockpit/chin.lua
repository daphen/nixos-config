-- Chin bridge: push statusline state out of nvim so the cockpit's QML chin can
-- render it. Push-only over a watched file (the CockpitState pattern) — never
-- polled; a --remote-expr pull would spawn a client process per query.
-- The payload mirrors the retired lualine layout: relative path + modified dot,
-- diagnostics, searchcount, macro pill, filetype, worktree-scoped diff, plan
-- chip, ticket/root chip, scrollbar position.
local M = {}

local scope = vim.env.COCKPIT_SCOPE or vim.env.HEIDR_SCOPE or "personal"
local dir = vim.fn.expand("~/.local/state/cockpit")
local path = dir .. "/chin-" .. scope .. ".json"

-- Worktree-scoped diff vs the hunk-nvim base (the same numbers the old lualine
-- bar showed) — async + cached; refreshed on the same events lualine used.
local diff_cache = { add = 0, del = 0 }
local diff_refreshing = false
local function refresh_diff(done)
	if diff_refreshing then return end
	diff_refreshing = true
	local cwd = vim.fn.getcwd()
	local file = vim.fn.expand("%:p")
	local editable = vim.bo.buftype == ""
	local root = vim.trim((vim.fn.systemlist({ "git", "-C", cwd, "rev-parse", "--show-toplevel" })[1]) or "")
	if root == "" then
		diff_cache = { add = 0, del = 0 }
		diff_refreshing = false
		if done then done() end
		return
	end
	local branch = vim.trim((vim.fn.systemlist({ "git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD" })[1]) or "")
	local base = "HEAD"
	if branch ~= "main" and branch ~= "master" then
		local ok, signs = pcall(require, "hunk-nvim.signs")
		if ok and signs.base_for then
			local b = signs.base_for(root)
			if b and b ~= "" then base = b end
		end
	end
	local in_worktree = editable and file ~= "" and file:sub(1, #root + 1) == root .. "/"
	local args = { "git", "-C", root, "diff", "--numstat", "--no-color", base }
	if in_worktree then args[#args + 1] = "--"; args[#args + 1] = file end
	vim.system(args, { text = true }, function(r)
		local add, del = 0, 0
		if r.code == 0 then
			for _, l in ipairs(vim.split(r.stdout or "", "\n", { plain = true })) do
				local a, d = l:match("^(%d+)%s+(%d+)")
				if a then add = add + tonumber(a); del = del + tonumber(d) end
			end
		end
		diff_cache = { add = add, del = del }
		diff_refreshing = false
		if done then vim.schedule(done) end
	end)
end

-- Ticket id / project-root chip (lualine's get_project_root, verbatim behavior):
-- nearest package.json ancestor; lovable worktrees shorten to their ticket.
local function root_chip()
	local function find_pkg(p)
		if vim.uv.fs_stat(p .. "/package.json") then return p end
		local parent = p:match("(.+)/[^/]+$")
		if parent and parent ~= p then return find_pkg(parent) end
	end
	local here = vim.fn.expand("%:p:h")
	if here == "" then return "" end
	local r = find_pkg(here)
	if not r then return "" end
	local folder = r:match("([^/]+)$") or ""
	local ticket = folder:match("^lovable%.daphen%-(%a+%-%d+)") or folder:match("^lovable%.(review%-%d+)")
	return ticket or folder
end

local function gather()
	local buf = vim.api.nvim_get_current_buf()
	local name = vim.api.nvim_buf_get_name(buf)
	local rel = name ~= "" and vim.fn.fnamemodify(name, ":.") or "[No Name]"
	if vim.bo[buf].modified then rel = rel .. " ●" end
	local diag = vim.diagnostic.count(buf)
	local search = ""
	if vim.v.hlsearch == 1 then
		local ok, sc = pcall(vim.fn.searchcount, { maxcount = 999, timeout = 50 })
		if ok and sc.total and sc.total > 0 then search = sc.current .. "/" .. sc.total end
	end
	local plan = ""
	pcall(function()
		local m = require("cockpit")
		plan = (m.plan_chip and m.plan_chip() or "")
	end)
	-- SESSION-scoped only: the plan-nvim statusline fallback reported the
	-- last-opened plan BUFFER regardless of session (inline-user-bash showing
	-- on the lovable orchestrator). No session plan -> no chip.
	-- The chin is a glance, not a coach: keep ticket + progress, drop the
	-- lifecycle hint ("→ g implement") and the status word.
	plan = plan:gsub("%s*→.*$", ""):gsub("%s*·%s*%a+%s*$", "")
	local fticon, fticolor = "", ""
	pcall(function()
		local di = require("nvim-web-devicons")
		local ic, color = di.get_icon_color_by_filetype(vim.bo[buf].filetype, { default = true })
		fticon, fticolor = ic or "", color or ""
	end)
	return {
		path = rel,
		fticon = fticon,
		fticolor = fticolor,
		err = diag[vim.diagnostic.severity.ERROR] or 0,
		warn = diag[vim.diagnostic.severity.WARN] or 0,
		info = diag[vim.diagnostic.severity.INFO] or 0,
		search = search,
		rec = vim.fn.reg_recording(),
		ft = vim.bo[buf].filetype or "",
		add = diff_cache.add, del = diff_cache.del,
		plan = vim.trim(plan),
		root = root_chip(),
		line = vim.api.nvim_win_get_cursor(0)[1],
		lines = vim.api.nvim_buf_line_count(buf),
	}
end

local timer
local function push()
	-- io in the main loop only — uv timer callbacks are a fast context.
	vim.schedule(function()
		local ok, payload = pcall(gather)
		if not ok then return end
		vim.fn.mkdir(dir, "p")
		local f = io.open(path, "w")
		if not f then return end
		f:write(vim.json.encode(payload))
		f:close()
	end)
end
local function schedule()
	if timer then timer:stop() else timer = vim.uv.new_timer() end
	timer:start(30, 0, push)
end
local function schedule_with_diff()
	refresh_diff(schedule)
	schedule()
end

function M.setup()
	local grp = vim.api.nvim_create_augroup("cockpit_chin", { clear = true })
	vim.api.nvim_create_autocmd(
		{ "ModeChanged", "CursorMoved", "CursorMovedI", "DiagnosticChanged", "RecordingEnter", "RecordingLeave" },
		{ group = grp, callback = schedule })
	-- diff scope follows the focused buffer/cwd, so refresh it where lualine did
	vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost", "DirChanged", "FocusGained", "VimEnter" },
		{ group = grp, callback = schedule_with_diff })
	vim.api.nvim_create_autocmd("User", { group = grp, pattern = "GitSignsUpdate", callback = schedule })
	schedule_with_diff()
end

return M
