local api, fn = vim.api, vim.fn
local repo = fn.getcwd()
local environment_config = dofile(repo .. "/pkgs/neovim/lua/lsp-environment.lua")
local tmp = fn.tempname()
local python = fn.exepath("python3")
fn.mkdir(tmp .. "/tools", "p")
local server = [[
import os,sys,json
path=os.environ['LSP_PROBE_PATH']
with open(path,'w') as f:
 json.dump({'scope':os.environ.get('COCKPIT_TEST_SCOPE'),'explicit':os.environ.get('EXPLICIT_OPTION'),'cwd':os.getcwd(),'exe':sys.argv[0],'args':sys.argv[1:]},f)
while True:
 headers={}
 while True:
  line=sys.stdin.buffer.readline()
  if not line: sys.exit(0)
  if line in (b'\r\n',b'\n'):break
  k,v=line.decode().split(':',1);headers[k.lower()]=v.strip()
 msg=json.loads(sys.stdin.buffer.read(int(headers['content-length'])))
 if msg.get('method')=='exit':break
 if 'id' not in msg:continue
 result={'capabilities':{}} if msg.get('method')=='initialize' else None
 body=json.dumps({'jsonrpc':'2.0','id':msg['id'],'result':result}).encode()
 sys.stdout.buffer.write(('Content-Length: %d\r\n\r\n'%len(body)).encode()+body);sys.stdout.buffer.flush()
]]
local function executable(path)
  fn.writefile(vim.list_extend({ "#!" .. python }, vim.split(server, "\n", { plain = true })), path)
  fn.setfperm(path, "rwxr-xr-x")
end
executable(tmp .. "/tools/typescript-language-server")
executable(tmp .. "/tools/gopls")
local allowed_roots = {}
local function directory(name, envrc, allow, local_binary)
  local root = tmp .. "/" .. name
  fn.mkdir(root .. "/go", "p")
  fn.writefile({ "{}" }, root .. "/package.json")
  if envrc then
    fn.writefile({ "# " .. name, "export COCKPIT_TEST_SCOPE=" .. name, "PATH_add " .. fn.shellescape(tmp .. "/tools") }, root .. "/.envrc")
    if allow then
      fn.system({ "direnv", "allow", root })
      assert(vim.v.shell_error == 0, "fixture direnv allow failed")
      allowed_roots[#allowed_roots + 1] = root
    end
  end
  if local_binary then
    fn.mkdir(root .. "/node_modules/.bin", "p")
    executable(root .. "/node_modules/.bin/typescript-language-server")
  end
  return root
end
local a = directory("a", true, true, true)
local b = directory("b", true, true, false)
local plain = directory("plain", false, false, true)
local blocked = directory("blocked", true, false, true)
fn.writefile({ "{}" }, blocked .. "/.oxlintrc.json")
vim.env.COCKPIT_TEST_SCOPE = "parent"
vim.env.PATH = tmp .. "/tools:" .. vim.env.PATH
local clients, count = {}, 0
local function check(ok, text) assert(ok, text); count = count + 1 end
local function configure(name, root, command, prefer_local, root_kind, filetype, cwd, workspace_required)
  local base = {
    name = name,
    filetypes = { filetype or name },
    cmd_cwd = cwd or root,
    cmd_env = { LSP_PROBE_PATH = tmp .. "/" .. name .. ".json", EXPLICIT_OPTION = name },
    workspace_required = workspace_required,
  }
  if root_kind == "markers" then
    base.root_markers = { { ".oxlintrc.json", ".oxlintrc.jsonc", "oxlint.config.ts" } }
  elseif root_kind ~= "none" then
    base.root_dir = function(bufnr, on_dir)
      local path = api.nvim_buf_get_name(bufnr)
      if vim.startswith(path, root .. "/") then on_dir(root_kind == "go" and root .. "/go" or root) end
    end
  end
  vim.lsp.config(name, vim.tbl_extend("force", base, environment_config(base, command, prefer_local)))
  vim.lsp.enable(name)
end
local function open(root, file, filetype)
  local path = root .. "/" .. file
  fn.writefile({ "const value = 1" }, path)
  vim.cmd.edit(fn.fnameescape(path))
  vim.bo.filetype = filetype
end
local function result(name)
  local path = tmp .. "/" .. name .. ".json"
  assert(vim.wait(5000, function() return fn.filereadable(path) == 1 end), "server did not start: " .. name)
  return vim.json.decode(table.concat(fn.readfile(path), "\n"))
end
configure("a-client", a, { "typescript-language-server", "--stdio" }, true, "function")
configure("b-client", b, { "typescript-language-server", "--stdio" }, true, "function")
open(a, "a.ts", "a-client")
open(b, "b.ts", "b-client")
local ar, br = result("a-client"), result("b-client")
check(ar.scope == "a" and br.scope == "b", "concurrent language servers use their own direnv")
check(ar.exe == a .. "/node_modules/.bin/typescript-language-server", "repo-local language server retains precedence")
check(br.exe == tmp .. "/tools/typescript-language-server", "direnv PATH supplies fallback executable")
check(ar.cwd == a and ar.explicit == "a-client" and ar.args[1] == "--stdio", "cwd, explicit env, and arguments are preserved")
check(vim.env.COCKPIT_TEST_SCOPE == "parent", "Neovim global environment is unchanged")
configure("plain-client", plain, { "typescript-language-server", "--stdio" }, true, "function")
open(plain, "plain.ts", "plain-client")
check(result("plain-client").scope == "parent", "projects without envrc retain normal environment")
vim.cmd.cd(fn.fnameescape(plain))
configure("workspace-required", plain, { tmp .. "/tools/typescript-language-server", "--stdio" }, false, "none", "workspace-required", plain, true)
open(plain, "required.ts", "workspace-required")
vim.wait(300)
check(fn.filereadable(tmp .. "/workspace-required.json") == 0, "workspace_required still skips without a root")
configure("single-file", plain, { tmp .. "/tools/typescript-language-server", "--stdio" }, false, "none", "single-file", plain, false)
open(plain, "single.ts", "single-file")
check(result("single-file").scope == "parent", "single-file activation still starts without a root")
configure("go-client", a, { "gopls" }, false, "go", "go-client", a .. "/go")
open(a .. "/go", "main.go", "go-client")
check(result("go-client").scope == "a", "gopls still discovers ancestor envrc")
local notices, notify = {}, vim.notify
vim.notify = function(message, level) notices[#notices + 1] = { message, level } end
configure("blocked-ts", blocked, { "typescript-language-server", "--stdio" }, true, "function", "blocked")
configure("blocked-tailwind", blocked, { "typescript-language-server", "--stdio" }, true, "function", "blocked")
configure("blocked-oxlint", blocked, { "typescript-language-server", "--stdio" }, true, "markers", "blocked")
open(blocked, "blocked.ts", "blocked")
check(vim.wait(5000, function() return #notices == 1 end), "blocked shared root reports once")
vim.wait(300)
check(#vim.lsp.get_clients({ name = "blocked-ts", _uninitialized = true }) == 0
  and #vim.lsp.get_clients({ name = "blocked-tailwind", _uninitialized = true }) == 0
  and #vim.lsp.get_clients({ name = "blocked-oxlint", _uninitialized = true }) == 0, "blocked root spawns zero clients")
check(fn.filereadable(tmp .. "/blocked-ts.json") == 0 and fn.filereadable(tmp .. "/blocked-tailwind.json") == 0
  and fn.filereadable(tmp .. "/blocked-oxlint.json") == 0, "untrusted envrc launches no server processes")
check(notices[1][1]:find("direnv allow " .. blocked, 1, true) ~= nil and #notices == 1, "notice is actionable without quit-warning flood")
fn.system({ "direnv", "allow", blocked })
assert(vim.v.shell_error == 0, "blocked fixture allow failed")
allowed_roots[#allowed_roots + 1] = blocked
open(blocked, "recovered.ts", "blocked")
check(result("blocked-ts").scope == "blocked" and result("blocked-tailwind").scope == "blocked"
  and result("blocked-oxlint").scope == "blocked", "approval-state change recovers through public activation")
vim.notify = notify
for _, client in ipairs(vim.lsp.get_clients({ _uninitialized = true })) do
  clients[#clients + 1] = client.id
  client:stop(true)
end
vim.wait(200)
for _, root in ipairs(allowed_roots) do fn.system({ "direnv", "deny", root }) end
vim.env.COCKPIT_TEST_SCOPE = nil
print("LSP direnv: " .. count .. " passed")
fn.delete(tmp, "rf")
vim.cmd("qa!")
