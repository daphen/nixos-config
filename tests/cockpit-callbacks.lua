local fn, uv = vim.fn, vim.uv
local home = assert(vim.env.HOME)
assert(home:find("/tmp/cockpit-callbacks-", 1, true), "isolated HOME required")
local root, bin = home .. "/repo", home .. "/bin"
fn.mkdir(root, "p"); fn.mkdir(bin, "p")
local git, python = fn.exepath("git"), fn.exepath("python3")
local function run(...)
  local args = { git, "-C", root }; vim.list_extend(args, { ... })
  local out = fn.systemlist(args); assert(vim.v.shell_error == 0, table.concat(out, "\n")); return out
end
run("init", "-b", "main"); run("config", "user.name", "Test"); run("config", "user.email", "test@example.com")
fn.writefile({ "old" }, root .. "/code.txt")
run("add", "."); run("commit", "-m", "base")
fn.writefile({ "new" }, root .. "/code.txt")
fn.writefile({
  "import sys,time",
  "sys.stdout.write('diff --git a/code.txt b/code.txt\\n--- a/code.txt\\n+++ b/code.txt\\n@@ -1');sys.stdout.flush()",
  "time.sleep(.08)",
  "sys.stdout.write(' +1 @@\\n-old\\n+new\\n');sys.stdout.flush()",
}, home .. "/fragment.py")
fn.writefile({ "#!/bin/sh", 'case "$*" in *"diff --no-color --no-ext-diff"*) exec ' .. fn.shellescape(python) .. ' "$HOME/fragment.py";; esac', "exec " .. fn.shellescape(git) .. ' "$@"' }, bin .. "/git")
fn.writefile({ "#!/bin/sh", 'printf "notification\\n" >> "$HOME/notified"' }, bin .. "/notify-send")
fn.setfperm(bin .. "/git", "rwxr-xr-x"); fn.setfperm(bin .. "/notify-send", "rwxr-xr-x")
vim.env.PATH = bin .. ":" .. vim.env.PATH
vim.cmd.cd(root)
local cockpit = require("cockpit")
cockpit.setup({ autostart = false })
local errors, original_notify = {}, vim.notify
vim.notify = function(message, level, opts)
  if level == vim.log.levels.ERROR then errors[#errors + 1] = tostring(message) end
  original_notify(message, level, opts)
end
local checks = 0
local function check(value, message) assert(value, message); checks = checks + 1 end
local server, client = uv.new_pipe(false), nil
assert(server:bind(vim.env.XDG_RUNTIME_DIR .. "/agentd-personal.sock"))
server:listen(1, function()
  client = uv.new_pipe(false); server:accept(client)
  client:read_start(function() end)
end)
vim.cmd.CockpitReconnect()
check(vim.wait(1000, function() return client ~= nil end, 10), "native client connected")
local marker = vim.env.XDG_RUNTIME_DIR .. "/agent-rail-focused"
local cases = { "missing", "empty", "invalid", "live" }
for _, case in ipairs(cases) do
  if case == "missing" then fn.delete(marker)
  elseif case == "empty" then fn.writefile({}, marker)
  elseif case == "invalid" then fn.writefile({ "not-a-pid" }, marker)
  else fn.writefile({ tostring(fn.getpid()) }, marker) end
  local before = fn.filereadable(home .. "/notified") == 1 and #fn.readfile(home .. "/notified") or 0
  client:write(vim.json.encode({ type = "extension_ui_request", session = "background-" .. case, method = "confirm", id = case, title = "Question" }) .. "\n")
  if case == "live" then
    vim.wait(100)
    check(#fn.readfile(home .. "/notified") == before, "focused live rail suppresses desktop notification")
  else
    check(vim.wait(1000, function() return fn.filereadable(home .. "/notified") == 1 and #fn.readfile(home .. "/notified") > before end, 10), case .. " marker permits notification without callback error")
  end
end
cockpit.git_summary(root)
check(vim.wait(3000, function() local s = cockpit.git_summary(root); return s and s.add == 1 and s.del == 1 end, 10), "split Git hunk header preserves exact addition/deletion counts")
check(#errors == 0, "scheduled callback errors: " .. table.concat(errors, "\n"))
client:read_stop(); client:close(); server:close()
print("cockpit callbacks: " .. checks .. " passed")
vim.cmd("qa!")
