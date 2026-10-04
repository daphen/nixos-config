local api, fn, uv = vim.api, vim.fn, vim.uv
local runtime = assert(vim.env.XDG_RUNTIME_DIR)
local socket_path = runtime .. "/agentd-work.sock"
local server = uv.new_pipe(false)
assert(server:bind(socket_path))
local request
server:listen(8, function(err)
  assert(not err, err)
  local client = uv.new_pipe(false)
  server:accept(client)
  client:write(vim.json.encode({ type = "roster", sessions = {
    { id = "remote-id", name = "worker", cwd = "/vm/rebased", status = "idle" },
  } }) .. "\n")
  local pending = ""
  client:read_start(function(read_err, chunk)
    assert(not read_err, read_err)
    if not chunk then return end
    pending = pending .. chunk
    while pending:find("\n", 1, true) do
      local line
      line, pending = pending:match("^(.-)\n(.*)$")
      local obj = vim.json.decode(line)
      if obj.type == "get_changes" then request = obj end
      if obj.type == "get_changes" and obj.session ~= "hold" then
        local response = {
          type = "changes", id = obj.id, session = "remote-id", cwd = "/vm/rebased",
          head = "vm-head", base = "vm-base", branch = "ticket", diff = "VM only",
          files = {
            { path = "renamed.txt", oldPath = "old.txt", add = 7, del = 2, binary = false,
              untracked = false, patch = "diff --git a/old.txt b/renamed.txt\n--- a/old.txt\n+++ b/renamed.txt\n@@ -1 +1 @@\n-wrong\n+VM truth" },
            { path = "new.bin", add = 0, del = 0, binary = true, untracked = true, patch = "" },
          },
        }
        for _, extra in ipairs({ { id = "late-request" }, { session = "other-session" }, { cwd = "/other/cwd" }, {} }) do
          if next(extra) then extra.files = {{ path = "unrelated-main.txt", add = 999, patch = "WRONG RESPONSE" }} end
          client:write(vim.json.encode(vim.tbl_extend("force", response, extra)) .. "\n")
        end
      end
    end
  end)
end)
local lovable_request, lovable_client
local lovable = uv.new_pipe(false)
assert(lovable:bind(runtime .. "/agentd-lovable.sock"))
lovable:listen(8, function(err)
  assert(not err, err)
  lovable_client = uv.new_pipe(false); lovable:accept(lovable_client)
  local pending = ""
  lovable_client:read_start(function(read_err, chunk)
    assert(not read_err, read_err); if not chunk then return end
    pending = pending .. chunk
    while pending:find("\n", 1, true) do
      local line; line, pending = pending:match("^(.-)\n(.*)$")
      local obj = vim.json.decode(line)
      if obj.type == "get_changes" then
        lovable_request = obj
        lovable_client:write(vim.json.encode({ type = "changes", id = obj.id, session = "remote-id", cwd = "/vm/rebased",
          files = {{ path = "renamed.txt", add = 99, del = 0, patch = "wrong socket" },
            { path = "wrong.txt", add = 1, del = 0, patch = "wrong socket" }} }) .. "\n")
      end
    end
  end)
end)
local picker_opts, picker_items = nil, {}
local preview = {
  lines = nil, message = nil,
  reset = function(self) self.lines, self.message = nil, nil end,
  set_lines = function(self, lines) self.lines = lines end,
  highlight = function() end,
  notify = function(self, message) self.message = message end,
}
local picker = {
  title = "", update_titles = function() end,
  close = function() end,
  show = function(self)
    local task
    local ctx = {
      async = {
        schedule = function(_, callback) callback() end,
        suspend = function() coroutine.yield() end,
        resume = function()
          local ok, err = coroutine.resume(task)
          assert(ok, err)
        end,
      },
      picker = self,
      preview = preview,
    }
    task = coroutine.create(function()
      picker_opts.finder(nil, ctx)(function(item)
        assert(coroutine.status(task) == "running", "picker yielded rows after finder finished")
        picker_items[#picker_items + 1] = item
      end)
    end)
    local ok, err = coroutine.resume(task)
    assert(ok, err)
  end,
}
local Snacks = {
  setup = function() end,
  picker = {
    get = function() return {} end,
    pick = function(opts) picker_opts = opts; return picker end,
    util = { path = function(item) return item.file end },
  },
}
_G.Snacks = Snacks
package.loaded["snacks"] = Snacks
package.preload["hunk-nvim.signs"] = function() return { base_for = function() return "HEAD" end } end
package.preload["snacks.picker.format"] = function()
  return { filename = function(item) return { { item.file or "", "Normal" } } end }
end
fn.mkdir(fn.expand("~/.local/state/cockpit"), "p")
fn.writefile({ "work" }, fn.expand("~/.local/state/cockpit/mode-main"))
local cockpit = require("cockpit")
cockpit.setup({ scope = "work" })
local spec = dofile("pkgs/neovim/lua/plugins/snacks.lua")
spec.after()
local mirror = runtime .. "/deliberately-wrong-mirror"
fn.mkdir(mirror, "p")
fn.writefile(vim.fn['repeat']({ "wrong local Git content" }, 40), mirror .. "/renamed.txt")
fn.writefile({ "wrong local media" }, mirror .. "/new.bin")
fn.system({ "git", "-C", mirror, "init", "-b", "main" })
cockpit.workspace("work", "remote-id", mirror, "", "diff", "", "coding", "work", "/vm/rebased")
assert(vim.wait(2000, function() return #picker_items == 2 end, 10), "authoritative picker rows did not arrive")
assert(not lovable_request, "diff request used the lovable socket instead of work")
assert(request and request.type == "get_changes" and request.session == "remote-id", "picker did not request a fresh VM snapshot")
local bypath = {}; for _, item in ipairs(picker_items) do bypath[item.path] = item end
local renamed, binary = bypath["renamed.txt"], bypath["new.bin"]
assert(renamed.add == 7 and renamed.del == 2, "local/mirror counts replaced VM counts")
assert(renamed.text == "old.txt → renamed.txt", "rename metadata lost")
assert(binary.binary and binary.untracked, "binary/untracked metadata lost")
picker_opts.preview({ item = renamed, preview = preview })
assert(table.concat(preview.lines or {}, "\n"):find("VM truth", 1, true), "preview did not use canonical patch")
picker_opts.preview({ item = binary, preview = preview })
assert(preview.message == "Binary file", "binary preview was reconstructed as text")
picker_items = {}
local missing = runtime .. "/deliberately-missing-mirror"
request = nil
cockpit.workspace("work", "remote-id", missing, "", "diff", "", "coding", "work", "/vm/rebased")
assert(vim.wait(2000, function() return #picker_items == 2 end, 10), "read-only picker requires a local mirror")
assert(request and not lovable_request, "missing mirror changed socket routing")
picker_items = {}
cockpit.workspace("work", "hold", mirror, "", "diff", "", "coding", "work", "/vm/rebased")
assert(vim.wait(2000, function() return request and request.session == "hold" end, 10), "held request never reached VM")
cockpit.workspace("work", "remote-id", mirror, "", "diff", "", "coding", "work", "/vm/rebased")
assert(vim.wait(2000, function() return #picker_items == 2 end, 10), "switching sessions reused a canceled diff request")
picker_items = {}
cockpit.workspace("work", "remote-id", mirror, "", "diff", "", "coding", "missing", "/vm/rebased")
assert(vim.wait(2000, function() return picker.title:find("connection failed", 1, true) ~= nil end, 10), "disconnected source did not report unavailable")
assert(#picker_items == 0, "disconnected source fell back to mirror rows")
print("remote diff: routing, poisoned replies, session switching, missing mirror, and disconnection passed")
server:close(); lovable:close()
if lovable_client and not lovable_client:is_closing() then lovable_client:close() end
vim.cmd("qa!")
