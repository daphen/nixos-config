-- Run with the real config: COCKPIT_INSTANCE=tabs-test nvim --headless -c "luafile tests/workspace-tabs.lua"
-- Reads (never writes) the real vault at ~/personal/notes/storage.
local c = require("cockpit")
local api, fn = vim.api, vim.fn
local V = fn.expand("~/personal/notes/storage")
local repo = fn.tempname()
fn.mkdir(repo, "p")
vim.system({ "git", "init", "-q", repo }):wait()
for _, n in ipairs({ "a.txt", "b.txt", "c.txt" }) do fn.writefile({ n, "two", "three", "four" }, repo .. "/" .. n) end
vim.system({ "git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qam", "init", "--allow-empty" }):wait()
vim.system({ "git", "-C", repo, "add", "." }):wait()
vim.system({ "git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "files" }):wait()
local note = fn.glob(V .. "/references/*.md", false, true)[1]
local plan = fn.fnamemodify(fn.glob(V .. "/plans/*.md", false, true)[1], ":t:r")
vim.g.agent_editor_win = api.nvim_get_current_win()

local failures = {}
local function shown() return api.nvim_buf_get_name(api.nvim_win_get_buf(vim.g.agent_editor_win)) end
local function check(label, cond, detail)
  if not cond then table.insert(failures, label .. " (" .. tostring(detail) .. ")") end
end
local function land(id, view, latest)
  c.workspace("personal", id, view == "vault" and V or repo, plan, view, latest or "", "", "", "")
  vim.wait(50)
end
local function follow(path, line) c.follow_remote(repo, path, false, line); vim.wait(50) end
local function row() return api.nvim_win_get_cursor(vim.g.agent_editor_win)[1] end

-- Code tab follows the agent.
land("s1", "code")
follow(repo .. "/a.txt")
check("code follows edits", shown() == repo .. "/a.txt", shown())

-- Vault is static: first visit opens the plan, edits never move it, Code keeps the edit.
land("s1", "vault")
check("vault opens the session plan", shown() == V .. "/plans/" .. plan .. ".md", shown())
vim.cmd.edit(fn.fnameescape(note))
follow(repo .. "/b.txt")
check("vault ignores code edits", shown() == note, shown())
follow(V .. "/plans/" .. plan .. ".md")
check("vault ignores vault edits", shown() == note, shown())
check("vault cwd", fn.getcwd() == V, fn.getcwd())

-- Back to Code (agent idle): the edit made while away is waiting.
land("s1", "code")
check("code shows the edit made while on vault", shown() == repo .. "/b.txt", shown())
check("code cwd", fn.getcwd() == repo, fn.getcwd())
follow(V .. "/plans/" .. plan .. ".md")
check("code ignores vault-file edits", shown() == repo .. "/b.txt", shown())

-- Vault remembers its note.
land("s1", "vault")
check("vault remembers its note", shown() == note, shown())

-- Dashboard stays the dashboard while the agent edits.
land("s1", "dashboard")
check("dashboard active", c.dashboard_snapshot().active, "inactive")
follow(repo .. "/c.txt", 3)
check("dashboard ignores edits", c.dashboard_snapshot().active, shown())
land("s1", "code")
check("code shows the edit made while on dashboard", shown() == repo .. "/c.txt", shown())
check("code lands on the changed line", row() == 3, row())

-- Code while the agent is working jumps to its latest edit, not the remembered file.
vim.cmd.edit(fn.fnameescape(repo .. "/a.txt"))
land("s1", "vault")
land("s1", "code", repo .. "/b.txt")
check("busy code opens the latest edit", shown() == repo .. "/b.txt", shown())

-- An explicit vault open from Vault is Vault's memory, not Code's.
land("s1", "vault")
vim.cmd.CockpitEdit(fn.fnameescape(V .. "/plans/" .. plan .. ".md"))
land("s1", "code")
check("code not polluted by a vault open", shown() == repo .. "/b.txt", shown())
land("s1", "vault")
check("vault keeps the explicitly opened note", shown() == V .. "/plans/" .. plan .. ".md", shown())

-- Sessions keep separate state.
c.workspace("personal", "s2", V, "", "vault", "", "", "", "")
vim.wait(50)
check("new session vault does not inherit", shown() == "", shown())
check("planless vault opens the file picker", require("mini.files").get_explorer_state() ~= nil, "closed")
c.workspace("personal", "s2", repo, "", "code", "", "", "", "")
vim.wait(50)
check("leaving vault closes the file picker", require("mini.files").get_explorer_state() == nil, "still open")

fn.delete(repo, "rf")
if #failures > 0 then
  io.stdout:write("FAIL\n" .. table.concat(failures, "\n") .. "\n")
  vim.cmd("cquit 1")
end
io.stdout:write("PASS workspace tabs\n")
vim.cmd("qa!")
