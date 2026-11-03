local cockpit = vim.env.COCKPIT_EDITOR_IDLE_EXIT
if not cockpit or cockpit == "" then return end

-- A VM editor outlives its Cockpit window; quit once no window has attached for a while and
-- Cockpit's forwarded socket stops answering (private mode detaches but keeps it), never with unsaved edits.
local grace_ms = 10 * 60 * 1000
local timer = vim.uv.new_timer()
local arm

local function quit_if_idle()
	if #vim.api.nvim_list_uis() > 0 then return end
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.bo[b].buftype == "" and vim.bo[b].modified then return end
	end
	local pipe = vim.uv.new_pipe()
	pipe:connect(cockpit, function(err)
		pipe:close()
		vim.schedule(function()
			if err then vim.cmd("qa!") else arm() end
		end)
	end)
end

function arm()
	timer:stop()
	if #vim.api.nvim_list_uis() == 0 then timer:start(grace_ms, 0, vim.schedule_wrap(quit_if_idle)) end
end

vim.api.nvim_create_autocmd({ "UIEnter", "UILeave" }, { callback = function() vim.schedule(arm) end })
arm()
