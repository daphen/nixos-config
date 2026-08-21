-- Chin bridge: push statusline state out of nvim so the cockpit's QML chin can
-- render it. Push-only over a watched file (the CockpitState pattern) — never
-- polled; a --remote-expr pull would spawn a client process per query.
local M = {}

local scope = vim.env.COCKPIT_SCOPE or vim.env.HEIDR_SCOPE or "personal"
local dir = vim.fn.expand("~/.local/state/cockpit")
local path = dir .. "/chin-" .. scope .. ".json"

local MODES = {
	n = "NORMAL", no = "O-PEND", i = "INSERT", v = "VISUAL", V = "V-LINE",
	["\22"] = "V-BLOCK", c = "COMMAND", R = "REPLACE", t = "TERMINAL", s = "SELECT",
}

local function gather()
	local buf = vim.api.nvim_get_current_buf()
	local name = vim.api.nvim_buf_get_name(buf)
	local home = vim.env.HOME or ""
	if home ~= "" and name:sub(1, #home) == home then name = "~" .. name:sub(#home + 1) end
	local m = vim.api.nvim_get_mode().mode
	local diag = vim.diagnostic.count(buf)
	local gs = vim.b[buf].gitsigns_status_dict or {}
	local plan = ""
	pcall(function() plan = require("plan-nvim").statusline() or "" end)
	return {
		mode = MODES[m] or MODES[m:sub(1, 1)] or m:upper(),
		path = name ~= "" and name or "[No Name]",
		ft = vim.bo[buf].filetype or "",
		branch = vim.b[buf].gitsigns_head or "",
		add = gs.added or 0, chg = gs.changed or 0, del = gs.removed or 0,
		err = diag[vim.diagnostic.severity.ERROR] or 0,
		warn = diag[vim.diagnostic.severity.WARN] or 0,
		plan = vim.trim(plan),
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

function M.setup()
	local grp = vim.api.nvim_create_augroup("cockpit_chin", { clear = true })
	vim.api.nvim_create_autocmd(
		{ "ModeChanged", "BufEnter", "BufWritePost", "DiagnosticChanged", "VimEnter", "DirChanged" },
		{ group = grp, callback = schedule })
	vim.api.nvim_create_autocmd("User", { group = grp, pattern = "GitSignsUpdate", callback = schedule })
	schedule()
end

return M
