local fn = vim.fn
local dir = fn.tempname()
fn.mkdir(dir, "p")
local function git(...)
  local args = { "git", "-C", dir }
  vim.list_extend(args, { ... })
  local out = fn.systemlist(args)
  assert(vim.v.shell_error == 0, table.concat(out, "\n"))
  return out[1]
end
git("init", "-b", "main")
git("config", "user.name", "Test")
git("config", "user.email", "test@example.com")
local tree = git("mktree")
local root = git("commit-tree", tree, "-m", "main root")
local parents = { "commit-tree", tree, "-m", "import histories", "-p", root }
for i = 1, 12 do
  vim.list_extend(parents, { "-p", git("commit-tree", tree, "-m", "import " .. i) })
end
local imported = git(unpack(parents))
git("update-ref", "refs/heads/main", imported)
local nonroot = git("commit-tree", tree, "-p", imported, "-m", "[skip lovable] Initialize Lovable project fixture")
git("update-ref", "refs/heads/ticket", nonroot)
git("symbolic-ref", "HEAD", "refs/heads/ticket")
local signs = require("hunk-nvim.signs")
local original, calls = fn.systemlist, 0
fn.systemlist = function(...) calls = calls + 1; return original(...) end
local base = signs.base_for(dir)
fn.systemlist = original
assert(base == imported, "non-root fixture must not override branch base")
assert(calls <= 10, "cold base must not spawn Git once per imported root: " .. calls)
local project = git("commit-tree", tree, "-m", "[skip lovable] Initialize Lovable project")
local merged = git("commit-tree", tree, "-p", nonroot, "-p", project, "-m", "real project root")
git("update-ref", "refs/heads/ticket", merged)
assert(signs.base_for(dir) == project, "real project root remains the preferred base")
vim.g.hunk_signs_base = imported
assert(signs.resolve_base(dir) == imported, "explicit base remains authoritative")
vim.g.hunk_signs_base = nil
print("hunk base: 4 passed; cold Git calls=" .. calls)
fn.delete(dir, "rf")
vim.cmd("qa!")
