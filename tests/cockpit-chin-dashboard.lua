local api, fn = vim.api, vim.fn
local home = assert(vim.env.HOME)
assert(home:find("/tmp/cockpit-chin-", 1, true), "isolated HOME required")
local repo = home .. "/repo"
fn.mkdir(repo, "p")
local function git(...)
  local args = {"git", "-C", repo}; vim.list_extend(args, {...})
  fn.system(args); assert(vim.v.shell_error == 0)
end
git("init", "-b", "main"); git("config", "user.name", "Test"); git("config", "user.email", "test@example.com")
fn.writefile({"original"}, repo .. "/file.txt"); git("add", "."); git("commit", "-m", "base")
fn.writefile({"original", "local modification"}, repo .. "/file.txt")
vim.cmd.cd(repo); vim.cmd.edit(repo .. "/file.txt")
local dashboard = {active=false,model={}}
local summary
package.loaded["cockpit"] = {dashboard_snapshot=function() return dashboard end,git_summary=function() return summary end}
local chin = require("cockpit.chin")
chin.setup()
local output = home .. "/.local/state/cockpit/chin-chin-test.json"
local function wait_counts(add, del)
  assert(vim.wait(1500, function()
    local ok, data = pcall(function() return vim.json.decode(table.concat(fn.readfile(output),"\n")) end)
    return ok and data.add == add and data.del == del
  end, 10), "wrong displayed diff: " .. table.concat(fn.readfile(output),"\n"))
end
wait_counts(1, 0)
dashboard = {active=true,model={kind="home",cwd="/remote-host/src/lovable"}}
api.nvim_set_current_buf(api.nvim_create_buf(false,true)); chin.refresh()
wait_counts(0, 0)
summary = {add=4,del=2}; dashboard.model = {kind="session",cwd=repo}; chin.refresh()
wait_counts(4, 2)
summary = nil; dashboard.active = false; vim.cmd.edit(repo .. "/file.txt"); chin.refresh()
wait_counts(1, 0)
print("chin dashboard: 4 passed — no cross-checkout fallback; local file and session diffs preserved")
vim.cmd("qa!")
