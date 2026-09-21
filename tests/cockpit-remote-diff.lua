local api, fn, uv = vim.api, vim.fn, vim.uv
local runtime = assert(vim.env.XDG_RUNTIME_DIR)
local socket_path = runtime .. "/agentd-lovable.sock"
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
      if obj.type == "get_changes" then
        request = obj
        client:write(vim.json.encode({
          type = "changes", id = obj.id, session = "remote-id", cwd = "/vm/rebased",
          head = "vm-head", base = "vm-base", branch = "ticket", diff = "VM only",
          files = {
            { path = "renamed.txt", oldPath = "old.txt", add = 7, del = 2, binary = false,
              untracked = false, patch = "diff --git a/old.txt b/renamed.txt\n--- a/old.txt\n+++ b/renamed.txt\n@@ -1 +1 @@\n-wrong\n+VM truth" },
            { path = "new.bin", add = 0, del = 0, binary = true, untracked = true, patch = "" },
          },
        }) .. "\n")
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
    local ctx = {
      async = { schedule = function(_, callback) callback() end },
      picker = self,
      preview = preview,
    }
    picker_opts.finder(nil, ctx)(function(item) picker_items[#picker_items + 1] = item end)
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
package.preload["snacks.picker.format"] = function()
  return { filename = function(item) return { { item.file or "", "Normal" } } end }
end
local cockpit = require("cockpit")
cockpit.setup({ scope = "work" })
local spec = dofile("pkgs/neovim/lua/plugins/snacks.lua")
spec.after()
local mirror = runtime .. "/deliberately-wrong-mirror"
fn.mkdir(mirror, "p")
fn.writefile(vim.fn['repeat']({ "wrong local Git content" }, 40), mirror .. "/renamed.txt")
fn.writefile({ "wrong local media" }, mirror .. "/new.bin")
fn.system({ "git", "-C", mirror, "init", "-b", "main" })
cockpit.workspace("work", "remote-id", mirror, "", "diff", "", "coding", "vm", "/vm/rebased")
assert(vim.wait(2000, function() return #picker_items == 2 end, 10), "authoritative picker rows did not arrive")
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
cockpit.workspace("work", "remote-id", missing, "", "diff", "", "coding", "vm", "/vm/rebased")
assert(vim.wait(2000, function() return #picker_items == 2 end, 10), "read-only picker requires a local mirror")
print("remote diff: 7 passed")
server:close()
vim.cmd("qa!")
