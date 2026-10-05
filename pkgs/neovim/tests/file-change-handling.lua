local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":h:h")
dofile(root .. "/lua/core/options.lua")

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local dirty_path = dir .. "/dirty.txt"
local clean_path = dir .. "/clean.txt"

local function write(path, lines)
	assert(vim.fn.writefile(lines, path) == 0)
end

local function external_write(path, content)
	local result = vim.system({ "tee", path }, { stdin = table.concat(content, "\n") .. "\n" }):wait()
	assert(result.code == 0, result.stderr)
end

local function lines()
	return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

local conflicts = 0
vim.api.nvim_create_autocmd("FileChangedShell", {
	callback = function()
		if vim.v.fcs_reason == "conflict" then
			conflicts = conflicts + 1
		end
	end,
})

write(dirty_path, { "disk-original" })
vim.cmd.edit(vim.fn.fnameescape(dirty_path))
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved-user-edit" })
external_write(dirty_path, { "external-agent-edit", "on-disk-only" })
vim.cmd.checktime()
vim.cmd.checktime()
assert(vim.deep_equal(lines(), { "unsaved-user-edit" }), "dirty buffer was reloaded")
assert(vim.bo.modified, "dirty buffer lost its modified state")
assert(vim.deep_equal(vim.fn.readfile(dirty_path), { "external-agent-edit", "on-disk-only" }))
assert(conflicts == 1, "dirty external write did not take the conflict path")
local dirty_messages = vim.api.nvim_exec2("messages", { output = true }).output
assert(not dirty_messages:find("W12:", 1, true), "W12 prompt was shown")
assert(not dirty_messages:find("Buffer reloaded", 1, true), "dirty buffer was reported as reloaded")

vim.cmd("bwipeout!")
write(clean_path, { "clean-original" })
vim.cmd.edit(vim.fn.fnameescape(clean_path))
external_write(clean_path, { "clean-external-update", "second-line" })
vim.cmd.checktime()
assert(vim.deep_equal(lines(), { "clean-external-update", "second-line" }), "clean buffer was not reloaded")
assert(not vim.bo.modified, "clean reload marked the buffer modified")

vim.fn.delete(dir, "rf")
vim.cmd("qa!")
