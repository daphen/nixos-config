local api, fn, uv = vim.api, vim.fn, vim.uv
local root = fn.tempname()
local slow, current = root .. "/slow", root .. "/current"
local function git(dir, ...)
  local args = { "git", "-C", dir }
  vim.list_extend(args, { ... })
  local out = fn.systemlist(args)
  assert(vim.v.shell_error == 0, table.concat(out, "\n"))
end
local function fixture(dir)
  fn.mkdir(dir, "p")
  git(dir, "init", "-b", "main")
  git(dir, "config", "user.name", "Test")
  git(dir, "config", "user.email", "test@example.com")
  fn.writefile({ "old" }, dir .. "/tracked.txt")
  fn.writefile({ "gone" }, dir .. "/gone.txt")
  git(dir, "add", ".")
  git(dir, "commit", "-m", "base")
  fn.writefile({ "new" }, dir .. "/tracked.txt")
  fn.delete(dir .. "/gone.txt")
end
fixture(slow)
fixture(current)
for i = 1, 2499 do fn.writefile({ "one", "two" }, string.format("%s/u-%04d.txt", slow, i)) end
local capped = {}
for i = 1, 700 do capped[i] = tostring(i) end
fn.writefile(capped, slow .. "/u-capped.txt")
fn.mkdir(slow .. "/agents", "p")
fn.writefile({ "ignored" }, slow .. "/agents/ignored.txt")

vim.env.HOME = root
vim.env.COCKPIT_INSTANCE = "dashboard-latency-test"
local cockpit = require("cockpit")
cockpit.setup({ autostart = false })
local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end
local ticks = 0
local timer = uv.new_timer()
timer:start(0, 2, function() ticks = ticks + 1 end)
local started = uv.hrtime()
cockpit.workspace("work", "slow", slow, "", "dashboard", "")
local dispatch_ms = (uv.hrtime() - started) / 1e6
check(dispatch_ms < 100, "dashboard dispatch is non-blocking")
cockpit.workspace("work", "current", current, "", "dashboard", "")
check(vim.wait(10000, function() return cockpit.git_summary(slow) ~= nil end, 5), "thousands of untracked files finish")
timer:stop(); timer:close()
local summary = assert(cockpit.git_summary(slow))
check(ticks >= 10, "event loop heartbeat runs during collection")
check(summary.add == 5499 and summary.del == 2, "final tracked, deleted, untracked, and capped stats are complete")
local dash = cockpit.dashboard_snapshot()
check(dash.active and dash.model.cwd == current, "late result cannot replace the selected dashboard")
check(vim.tbl_contains(dash.model.tabs or {}, "changes"), "dashboard retains Changes navigation")

local chin = root .. "/.local/state/cockpit/chin-dashboard-latency-test.json"
local function chip(folder, expected)
  local dir = root .. "/" .. folder
  fn.mkdir(dir .. "/app", "p")
  fn.writefile({ "{}" }, dir .. "/package.json")
  fn.writefile({ "return true" }, dir .. "/app/file.lua")
  vim.cmd.edit(fn.fnameescape(dir .. "/app/file.lua"))
  require("cockpit.chin").refresh()
  check(vim.wait(2000, function()
    if fn.filereadable(chin) == 0 then return false end
    local payload = vim.json.decode(table.concat(fn.readfile(chin), "\n"))
    return payload.root == expected
  end, 10), folder .. " uses chip " .. expected)
end
chip(".davidkarlsson-every-2739-mirror", "EVERY-2739")
chip("lovable.daphen-EVERY-2742", "EVERY-2742")
chip("lovable.review-123", "review-123")

print("dashboard latency: " .. checks .. " passed; dispatch=" .. math.floor(dispatch_ms) .. "ms ticks=" .. ticks)
fn.delete(root, "rf")
vim.cmd("qa!")
