local api, fn = vim.api, vim.fn
local dir = fn.tempname()
fn.mkdir(dir, "p")
local long = string.rep("A paragraph that needs eighty column wrapping. ", 9)
local function narrow(path)
  for _, line in ipairs(fn.readfile(path)) do if fn.strchars(line) > 80 then return false end end
  return true
end
local function check(ok, message) assert(ok, message) end
local path = dir .. "/visible.md"
fn.writefile({ long }, path)
vim.cmd.edit(fn.fnameescape(path))
api.nvim_exec_autocmds("VimEnter", { modeline = false })
check(vim.wait(5000, function() return narrow(path) and not vim.bo.modified end), "initial read was not formatted and saved")
local buf = api.nvim_get_current_buf()
fn.writefile({ long .. "Externally updated." }, path)
check(vim.wait(5000, function() return narrow(path) and table.concat(api.nvim_buf_get_lines(buf,0,-1,false), " "):find("Externally updated.",1,true) ~= nil end), "native autoread did not format external update")
local unopened = dir .. "/unopened.md"
fn.writefile({ long }, unopened)
vim.wait(200)
check(not narrow(unopened), "unopened file was rewritten")
api.nvim_buf_set_lines(buf,0,-1,false,{"unsaved draft"})
fn.writefile({long .. "Another external update."},path)
vim.wait(400)
check(api.nvim_buf_get_lines(buf,0,-1,false)[1] == "unsaved draft" and vim.bo[buf].modified, "unsaved text was changed")
check(not narrow(path), "dirty buffer's file was formatted")
local real = fn.exepath("mdformat")
local wrapper = dir .. "/mdformat"
fn.writefile({ "#!/bin/sh", "sleep 0.3", "exec " .. fn.shellescape(real) .. ' "$@"' },wrapper)
fn.setfperm(wrapper,"rwxr-xr-x")
local old_path = vim.env.PATH
vim.env.PATH = dir .. ":" .. old_path
local racing=dir.."/typing.md"
fn.writefile({long},racing)
vim.cmd.edit(fn.fnameescape(racing))
vim.wait(50)
api.nvim_buf_set_lines(0,0,-1,false,{"typed during formatting"})
vim.wait(800)
check(api.nvim_get_current_line()=="typed during formatting" and vim.bo.modified,"async format overwrote typing")
check(not narrow(racing),"async format saved over typing")
vim.env.PATH = old_path
print("Markdown read formatting: 7 checks passed")
fn.delete(dir,"rf")
vim.cmd("qa!")
