local api, fn, uv = vim.api, vim.fn, vim.uv
local root = fn.tempname()
fn.mkdir(root .. "/bin", "p")
local git_bin = fn.exepath("git")
local function git(...)
  local args = { git_bin, "-C", root }
  vim.list_extend(args, { ... })
  local out = fn.systemlist(args)
  assert(vim.v.shell_error == 0, table.concat(out, "\n"))
end
git("init", "-b", "main")
git("config", "user.name", "Test")
git("config", "user.email", "test@example.com")
fn.writefile({ "old" }, root .. "/tracked.txt")
fn.writefile({ "deleted" }, root .. "/gone.txt")
fn.writefile({ "space old" }, root .. "/with space.txt")
fn.writefile({ "bin/" }, root .. "/.gitignore")
git("add", ".")
git("commit", "-m", "base")
git("checkout", "-b", "ticket")
fn.writefile({ "committed" }, root .. "/tracked.txt")
git("rm", "gone.txt")
git("commit", "-am", "implementation")
fn.writefile({ "staged" }, root .. "/with space.txt")
git("add", "with space.txt")
fn.writefile({ "new file" }, root .. "/new ü.txt")
fn.mkdir(root .. "/.heidr-pastes", "p")
fn.mkdir(root .. "/.cockpit-pastes", "p")
fn.writefile({ "paste" }, root .. "/.heidr-pastes/img.png")
fn.writefile({ "paste" }, root .. "/.cockpit-pastes/img.png")
fn.writefile({ "#!/bin/sh", 'case " $* " in *" diff "*) sleep 0.6;; esac', 'exec ' .. fn.shellescape(git_bin) .. ' "$@"' }, root .. "/bin/git")
fn.setfperm(root .. "/bin/git", "rwxr-xr-x")
vim.cmd.cd(fn.fnameescape(root))
local path = vim.env.PATH
vim.env.PATH = root .. "/bin:" .. path
local checks = 0
local function check(ok, text) assert(ok, text); checks = checks + 1 end
local function wait(test) return vim.wait(5000, test, 10) end
local function open()
  vim.cmd.CockpitChanges()
  return assert(Snacks.picker.get()[1])
end
local start = uv.hrtime()
local picker = open()
local open_ms = (uv.hrtime() - start) / 1e6
check(vim.bo.filetype == "snacks_picker_input" and open_ms < 300, "picker must open before slow Git completes")
local ticks = 0
local timer = uv.new_timer()
timer:start(0, 20, function() ticks = ticks + 1 end)
check(wait(function() return #picker:items() == 4 end), "committed, staged, deleted, and untracked paths arrive; pastes excluded")
timer:stop(); timer:close()
check(ticks >= 10, "event loop stays responsive during slow diff")
local files = vim.tbl_map(function(item) return item.file end, picker:items())
check(vim.tbl_contains(files, root .. "/new ü.txt") and vim.tbl_contains(files, root .. "/with space.txt"), "Git paths are decoded without quotes")
local function select(file)
  picker:action("list_top")
  for _ = 1, #picker:items() do
    if picker:current().file == root .. "/" .. file then return end
    picker:action("list_down")
  end
  error("no row: " .. file)
end
local function preview()
  local buf = picker.preview.win.buf
  return buf and api.nvim_buf_is_valid(buf) and table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n") or ""
end
select("tracked.txt")
check(wait(function() return preview():find("+committed", 1, true) ~= nil end), "tracked preview shows diff")
select("gone.txt")
vim.wait(100)
select("new ü.txt")
check(wait(function() return preview():find("new file", 1, true) ~= nil end), "untracked preview shows file contents")
vim.wait(800)
check(preview():find("new file", 1, true) ~= nil and not preview():find("-deleted", 1, true), "late preview cannot replace current row")
fn.writefile({ "old" }, root .. "/tracked.txt")
select("tracked.txt")
check(wait(function() return preview() == "old" end), "empty tracked diff falls back to contents")
picker:close()
picker = open()
picker:close()
vim.wait(1000)
check(#Snacks.picker.get() == 0, "closing during Git lookup cannot reopen picker")
vim.env.PATH = path
print("picker: " .. checks .. " passed; open=" .. math.floor(open_ms) .. "ms with 600ms Git delay")
fn.delete(root, "rf")
vim.cmd("qa!")
