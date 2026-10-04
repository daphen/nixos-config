local api, fn, uv = vim.api, vim.fn, vim.uv
local home, runtime = assert(vim.env.HOME), assert(vim.env.XDG_RUNTIME_DIR)
assert(home:find("/tmp/cockpit-ownership-", 1, true), "isolated HOME required")
local main, worker = home .. "/work/lovable", home .. "/work/lovable.daphen-every-3595"
fn.mkdir(main, "p"); fn.mkdir(worker, "p")
fn.mkdir(home .. "/.local/state/cockpit", "p")
fn.writefile({ "main" }, home .. "/.local/state/cockpit/active")
fn.writefile({ "work" }, home .. "/.local/state/cockpit/mode-main")
local server = uv.new_pipe(false)
assert(server:bind(runtime .. "/agentd-lovable.sock"))
local clients = {}
local roster = vim.json.encode({ type = "roster", sessions = {
  { id = "orchestrator", name = "orchestrator", cwd = main, profile = "lovable-orchestrator", status = "idle" },
  { id = "every-3595", name = "every-3595", cwd = worker, profile = "lovable-worker", status = "idle" },
} }) .. "\n"
server:listen(8, function(err)
  assert(not err, err)
  local client = uv.new_pipe(false)
  server:accept(client); clients[#clients + 1] = client
  client:write(roster)
  client:read_start(function() end)
end)
vim.env.COCKPIT_COCKPIT = "1"
vim.env.COCKPIT_TITLE = "ownership-test"
local cockpit = require("cockpit")
local function check_binding()
  local d = cockpit.dashboard_snapshot()
  assert(d.active and d.model.kind ~= "home" and d.model.cwd == worker, "root context displaced the ticket dashboard: " .. vim.inspect(d.model))
  assert(d.model.identity:lower():find("3595", 1, true), "dashboard lost the ticket identity")
end
cockpit.setup({ scope = "work", autostart = false })
cockpit.workspace("work", "every-3595", worker, "", "dashboard", "", "lovable-worker", "work", "/vm/lovable-every-3595")
api.nvim_exec_autocmds("VimEnter", {})
vim.wait(200)
check_binding()
cockpit.open()
cockpit.workspace("work", "every-3595", worker, "", "dashboard", "", "lovable-worker", "work", "/vm/lovable-every-3595")
vim.wait(200)
assert(#clients == 0, "shell-driven editor must leave roster transport to the shell")
check_binding()
fn.writefile({ "main" }, home .. "/.local/state/cockpit/active")
for _, client in ipairs(clients) do client:write(roster) end
vim.wait(200)
check_binding()
print("workspace ownership: startup, shell-owned transport, and legacy context preserve the rail-bound ticket")
server:close()
for _, client in ipairs(clients) do client:close() end
vim.cmd("qa!")
