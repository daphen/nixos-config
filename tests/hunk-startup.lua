local api, fn = vim.api, vim.fn
local root = fn.tempname()
local repo = root .. "/checkout"
fn.mkdir(repo, "p")
local function git(...)
  local argv = { "git", "-C", repo }
  vim.list_extend(argv, { ... })
  local result = fn.systemlist(argv)
  assert(vim.v.shell_error == 0, table.concat(result, "\n"))
end
git("init", "-b", "main")
git("config", "user.name", "Test")
git("config", "user.email", "test@example.com")
local lines = {}
for i = 1, 20 do lines[i] = "line " .. i end
fn.writefile(lines, repo .. "/file.txt")
git("add", "file.txt")
git("commit", "-qm", "fixture")
table.insert(lines, 4, "first addition")
table.insert(lines, 14, "second addition")
fn.writefile(lines, repo .. "/file.txt")
vim.cmd.cd(root)
local signs = require("hunk-nvim.signs")
signs.setup({ debounce_ms = 10 })
assert(fn.exists("#HunkSigns#BufEnter") == 1, "startup outside Git disabled the gutter")
vim.cmd.edit(repo .. "/file.txt")
local ns = api.nvim_get_namespaces()["hunk-signs"]
assert(vim.wait(2000, function()
  return #api.nvim_buf_get_extmarks(0, ns, 0, -1, {}) == 2
end, 10), "opening a checkout after startup did not draw its Git changes")
api.nvim_win_set_cursor(0, { 1, 0 })
signs.next_hunk(); assert(api.nvim_win_get_cursor(0)[1] == 4, "next hunk missed first addition")
signs.next_hunk(); assert(api.nvim_win_get_cursor(0)[1] == 14, "next hunk missed second addition")
signs.prev_hunk(); assert(api.nvim_win_get_cursor(0)[1] == 4, "previous hunk missed first addition")
print("hunk startup: nongit startup, buffer attachment, gutter and hunk navigation passed")
fn.delete(root, "rf")
vim.cmd("qa!")
