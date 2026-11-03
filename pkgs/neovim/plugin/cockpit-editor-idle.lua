if vim.env.COCKPIT_EDITOR_IDLE_EXIT ~= "1" then return end

-- A VM editor outlives its Cockpit window; quit once no window has attached for a while,
-- but never with unsaved file edits.
local grace_ms = 10 * 60 * 1000
local timer = vim.uv.new_timer()

local function quit_if_idle()
	if #vim.api.nvim_list_uis() > 0 then return end
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.bo[b].buftype == "" and vim.bo[b].modified then return end
	end
	vim.cmd("qa!")
end

local function arm()
	timer:stop()
	if #vim.api.nvim_list_uis() == 0 then timer:start(grace_ms, 0, vim.schedule_wrap(quit_if_idle)) end
end

vim.api.nvim_create_autocmd({ "UIEnter", "UILeave" }, { callback = function() vim.schedule(arm) end })
arm()
