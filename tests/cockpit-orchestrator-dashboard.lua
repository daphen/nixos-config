local api, fn = vim.api, vim.fn
local home = assert(vim.env.HOME)
assert(home:find("/tmp/cockpit-orchestrator-", 1, true), "isolated HOME required")
fn.mkdir(home .. "/.local/state/lovable", "p")
fn.writefile({vim.json.encode({cycle={name="Test cycle",done=0,total=1},tickets={{id="EVERY-42",title="Existing cycle ticket",state="Todo"}}})}, home .. "/.local/state/lovable/cycle.json")
vim.g.mapleader = " "
local cockpit = require("cockpit")
cockpit.setup({autostart=false})
local remote = "/remote-test-host/src/lovable"
assert(fn.isdirectory(remote) == 0)
local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end
cockpit.workspace("work", "conductor", remote, "", "", "", "lovable-orchestrator")
local snapshot = cockpit.dashboard_snapshot()
check(snapshot.active and snapshot.model.kind == "home", "remote orchestrator did not open the home dashboard")
check(snapshot.model.cwd == remote, "dashboard falsified the session's remote cwd")
local body = vim.json.encode(snapshot.model.cards)
check(body:find("Existing cycle ticket",1,true) ~= nil, "orchestrator dashboard lost cycle tickets")
check(not body:find("no local mirror",1,true), "orchestrator requested a code mirror")
check(fn.isdirectory(remote) == 0, "dashboard created a local checkout")
api.nvim_feedkeys(api.nvim_replace_termcodes("<Space>D",true,false,true),"xt",false)
check(cockpit.dashboard_snapshot().model.kind == "home", "returning to dashboard lost the orchestrator role")
cockpit.workspace("work", "orchestrator", remote, "", "dashboard", "", "lovable-worker")
check(vim.json.encode(cockpit.dashboard_snapshot().model.cards):find("no local mirror",1,true) ~= nil, "worker was misclassified by its name")
cockpit.workspace("work", "every-42", remote .. "-every-42", "", "dashboard", "", "lovable-worker")
check(vim.json.encode(cockpit.dashboard_snapshot().model.cards):find("no local mirror",1,true) ~= nil, "missing ticket mirror warning was removed")
print("orchestrator dashboard: " .. checks .. " passed")
vim.cmd("qa!")
