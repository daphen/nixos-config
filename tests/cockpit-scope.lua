local api, fn, uv = vim.api, vim.fn, vim.uv
local home = assert(vim.env.HOME)
assert(home:find("/tmp/cockpit-scope-", 1, true), "run with an isolated HOME and runtime dir")
local state = home .. "/.local/state/cockpit"
fn.mkdir(state, "p")
fn.mkdir(home .. "/personal", "p")
fn.mkdir(home .. "/work/lovable", "p")
local instance = vim.env.COCKPIT_INSTANCE or "main"
local mode = state .. "/mode-" .. instance
fn.writefile({ "work" }, mode)
local servers, clients, connections, requests = {}, {}, {}, {}
for _, scope in ipairs({ "personal", "lovable" }) do
  local server = uv.new_pipe(false)
  assert(server:bind(vim.env.XDG_RUNTIME_DIR .. "/agentd-" .. scope .. ".sock"))
  server:listen(8, function(err)
    assert(not err, err)
    local client = uv.new_pipe(false)
    server:accept(client)
    clients[#clients + 1] = client
    connections[scope] = (connections[scope] or 0) + 1
    client:read_start(function(_, data)
      if data then requests[scope] = (requests[scope] or "") .. data end
    end)
    client:write(vim.json.encode({ type = "roster", sessions = {{ id = scope .. "-peer", name = scope .. "-peer", cwd = "/absent/" .. scope, status = "idle", plan = "scope-plan" }} }) .. "\n")
  end)
  servers[#servers + 1] = server
end
local cockpit = require("cockpit")
cockpit.setup({ autostart = false })
cockpit.dashboard(home .. "/work/lovable")
local checks = 0
local function check(value, message) assert(value, message); checks = checks + 1 end
local function wait(predicate, message)
  check(vim.wait(1000, predicate, 10), message)
end
local function dash(scope)
  local d = cockpit.dashboard_snapshot()
  return d.active and d.model.scope == scope and d.model.kind == "home"
end
local function chin(scope)
  local file = state .. "/chin-" .. instance .. ".json"
  if fn.filereadable(file) ~= 1 then return false end
  local ok, data = pcall(vim.json.decode, table.concat(fn.readfile(file), "\n"))
  return ok and data.dashboard.active and data.dashboard.model.scope == scope
end
check(dash("lovable"), "persisted work must override personal launch env")
check(cockpit.dashboard_snapshot().model.masthead == "lovable", "work must render lovable home")
vim.cmd.CockpitReconnect()
wait(function() return (requests.lovable or ""):find("list_sources", 1, true) end, "work must dial lovable socket, not launch address")
wait(function() return chin("lovable") end, "initial chin publishes work dashboard")
local work_connections = connections.lovable
fn.writefile({ "personal" }, mode .. ".tmp")
assert(uv.fs_rename(mode .. ".tmp", mode))
wait(function() return dash("personal") and chin("personal") end, "atomic toggle rerenders personal dashboard/chin within 1s")
wait(function() return requests.personal end, "toggle redials personal socket")
check(cockpit.dashboard_snapshot().model.masthead == "cockpit", "personal home masthead follows toggle")
local personal_connections = connections.personal
clients[#clients]:write('{"type":')
vim.wait(50)
fn.writefile({ "work" }, mode)
wait(function() return dash("lovable") and chin("lovable") end, "ordinary write toggles back without restart")
wait(function() return connections.lovable > work_connections end, "return to work reconnects lovable")
wait(function() return cockpit.session_for_plan("scope-plan") == "lovable-peer" end, "new roster is not contaminated by partial old-scope data")
vim.wait(250)
check(connections.personal == personal_connections, "old callbacks did not reconnect previous scope")
fn.writefile({}, mode)
vim.wait(100)
check(dash("lovable"), "transient empty write must not fall back to launch env")
fn.writefile({ "work" }, mode)
local file = home .. "/work/lovable/unsaved.txt"
fn.writefile({ "saved" }, file)
vim.cmd.edit(file)
api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved" })
local buf = api.nvim_get_current_buf()
fn.writefile({ "personal" }, mode)
wait(function() return connections.personal > personal_connections end, "scope changes while a real file is open")
check(api.nvim_get_current_buf() == buf and vim.bo[buf].modified, "toggle preserves the open modified buffer")
check(api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "unsaved", "toggle preserves unsaved text")
cockpit.workspace("work", "stale", home .. "/work/lovable", "", "dashboard", "")
check(api.nvim_get_current_buf() == buf, "stale old-scope workspace call cannot replace editor")
vim.cmd.CockpitDash()
wait(function() return dash("personal") and chin("personal") end, "return to dashboard uses the toggled scope")
fn.writefile({ "work" }, mode)
wait(function() return dash("lovable") end, "work before removal")
assert(uv.fs_unlink(mode))
wait(function() return dash("personal") end, "absent mode file restores launch default")
fn.writefile({ "work" }, mode)
wait(function() return dash("lovable") end, "work before retry-race check")
servers[1]:close()
fn.writefile({ "personal" }, mode)
wait(function() return dash("personal") end, "scope updates even while its socket is unavailable")
vim.wait(80)
local before = connections.lovable
fn.writefile({ "work" }, mode)
wait(function() return dash("lovable") and connections.lovable > before end, "switch escapes the previous scope's retry loop")
vim.wait(450)
check(connections.lovable == before + 1, "stale retry opened a duplicate connection")
for _, client in ipairs(clients) do client:read_stop(); client:close() end
for _, server in ipairs(servers) do if not server:is_closing() then server:close() end end
print("cockpit scope: " .. checks .. " passed")
vim.cmd("qa!")
