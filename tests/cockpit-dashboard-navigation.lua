local api, fn = vim.api, vim.fn
vim.cmd("packadd snacks.nvim")
_G.Snacks = require("snacks")
require("plugins.snacks").after()
local cockpit = require("cockpit")
cockpit.setup({ autostart = false })
local root = fn.tempname()
fn.mkdir(root, "p")
local function git(...)
  local args = { "git", "-C", root }
  vim.list_extend(args, { ... })
  local out = fn.systemlist(args)
  assert(vim.v.shell_error == 0, table.concat(out, "\n"))
end
git("init", "-b", "main")
git("config", "user.name", "Test")
git("config", "user.email", "test@example.com")
fn.writefile({ "before" }, root .. "/requested.txt")
git("add", ".")
git("commit", "-m", "base")
git("checkout", "-b", "EVERY-3293")
fn.writefile({ "after" }, root .. "/requested.txt")
git("commit", "-am", "change requested file")
local original_path, git_bin = vim.env.PATH, fn.exepath("git")
fn.mkdir(root .. "/bin", "p")
fn.writefile({ "#!/bin/sh", "printf '%s\\n' \"$*\" >> " .. fn.shellescape(root .. "/git.log"),
  "exec " .. fn.shellescape(git_bin) .. " \"$@\"" }, root .. "/bin/git")
fn.setfperm(root .. "/bin/git", "rwxr-xr-x")
vim.env.PATH = root .. "/bin:" .. original_path
local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end
cockpit.workspace("work", "every-3293", root, "", "dashboard", "")
check(cockpit.dashboard_snapshot().active, "workspace starts on QML-backed dashboard state")
cockpit.workspace("work", "every-3293", root, "", "cycle", "")
check(vim.wait(3000, function() return #Snacks.picker.get() == 1 end, 10), "cycle from dashboard opens changed-file picker")
local picker = Snacks.picker.get()[1]
check(vim.bo.filetype == "snacks_picker_input", "picker receives Neovim keyboard focus")
check(vim.wait(5000, function() return not picker.finder:running() and #picker:items() > 0 end, 10), "changed rows arrive")
for _ = 1, #picker:items() do
  if picker:current().file == root .. "/requested.txt" then break end
  picker:action("list_down")
end
check(picker:current().file == root .. "/requested.txt", "requested changed file is selectable")
picker:action("confirm")
check(vim.wait(1000, function() return api.nvim_buf_get_name(0) == root .. "/requested.txt" end, 10), "Enter opens requested changed file")
local calls = fn.filereadable(root .. "/git.log") == 1 and fn.readfile(root .. "/git.log") or {}
check(not vim.iter(calls):any(function(call) return call:match("^fetch ") end), "view-only navigation does not fetch")
print("dashboard navigation: " .. checks .. " passed")
vim.env.PATH = original_path
fn.delete(root, "rf")
vim.cmd("qa!")
