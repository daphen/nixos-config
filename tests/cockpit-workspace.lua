local api, fn = vim.api, vim.fn
local cockpit = require("cockpit")
local root = fn.tempname()
fn.mkdir(root, "p")
local function git(dir, ...)
  local args = { "git", "-C", dir }
  vim.list_extend(args, { ... })
  local result = fn.systemlist(args)
  assert(vim.v.shell_error == 0, table.concat(result, "\n"))
  return result
end
local function fixture(name)
  local dir = root .. "/" .. name
  fn.mkdir(dir .. "/.plans", "p")
  git(dir, "init", "-b", "main")
  fn.writefile({ "first", "second", "third" }, dir .. "/code.txt")
  git(dir, "add", "code.txt")
  git(dir, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "base")
  git(dir, "checkout", "-b", "ticket")
  fn.writefile({ "first", "changed", "third" }, dir .. "/code.txt")
  git(dir, "add", "code.txt")
  git(dir, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "implementation")
  local slug = fn.fnamemodify(name, ":t")
  fn.writefile({ "# " .. slug, "", "Status: finalized" }, dir .. "/.plans/" .. slug .. ".md")
  return dir
end
local a, b = fixture("WORKSPACE-A"), fixture("WORKSPACE-B")
local function view(scope, id, dir, which, latest)
  cockpit.workspace(scope, id, dir, fn.fnamemodify(dir, ":t"), which, latest or "")
end
local checks = 0
local function check(test, message)
  assert(test, message)
  checks = checks + 1
end
view("work", "ticket", a, "code", a .. "/code.txt")
check(fn.getcwd() == a, "selection binds cwd")
api.nvim_win_set_cursor(0, { 2, 3 })
api.nvim_buf_set_lines(0, 1, 2, false, { "unsaved change" })
local errors, notify = {}, vim.notify
vim.notify = function(message, level, ...)
  if level == vim.log.levels.ERROR then errors[#errors + 1] = tostring(message) end
  return notify(message, level, ...)
end
view("work", "fresh", a, "code", a .. "/code.txt")
vim.notify = notify
check(#errors == 0, "switching sessions onto an unsaved open file must not reload it: " .. table.concat(errors, "; "))
check(api.nvim_get_current_line() == "unsaved change" and vim.bo.modified, "unsaved file stays open after session switch")
view("work", "ticket", a, "code")
view("work", "ticket", a, "cycle")
check(api.nvim_buf_get_name(0) == a .. "/.plans/WORKSPACE-A.md", "code cycles to exact plan")
view("work", "ticket", a, "cycle")
check(cockpit.dashboard_snapshot().active, "plan cycles to dashboard")
check(cockpit.dashboard_snapshot().model.cwd == a, "dashboard owns ticket checkout")
view("work", "ticket", a, "cycle")
check(api.nvim_buf_get_name(0) == a .. "/code.txt", "dashboard cycles back to code")
check(api.nvim_get_current_line() == "unsaved change", "unsaved buffer survives")
check(vim.deep_equal(api.nvim_win_get_cursor(0), { 2, 3 }), "cursor survives")
view("personal", "ticket", b, "code", b .. "/code.txt")
check(api.nvim_buf_get_name(0) == b .. "/code.txt", "same session name in another scope stays isolated")
view("work", "ticket", a, "code")
check(api.nvim_get_current_line() == "unsaved change", "switch back restores selected session")
view("work", "ticket", a, "plan")
vim.cmd.cd(fn.fnameescape(b))
vim.cmd.CockpitChanges()
local picker = Snacks.picker.get()[1]
check(picker ~= nil, "Ctrl-F entry opens picker")
check(vim.wait(3000, function() return not picker.finder:running() and not picker.matcher:running() and #picker:items() > 0 end), "async diff rows arrive")
local files = picker:items()
check(vim.iter(files):any(function(item) return item.file == a .. "/code.txt" end), "committed ticket diff uses binding, not cwd or plan repo")
check(not vim.iter(files):any(function(item) return item.file == b .. "/code.txt" end), "other checkout excluded")
local missing = root .. "/MISSING"
view("work", "missing", missing, "dashboard")
check(cockpit.dashboard_snapshot().model.cwd == missing, "missing mirror dashboard never falls back")
vim.cmd.CockpitChanges()
check(#Snacks.picker.get() == 0, "missing mirror blocks diff in unrelated cwd")
check(cockpit.workspace_cwd() == nil, "missing checkout is explicit")
view("work", "ticket", a, "diff")
check(vim.wait(2000, function() return #Snacks.picker.get() == 1 end), "real diff picker opens")
check(vim.bo.filetype == "snacks_picker_input", "diff picker keeps keyboard focus")
view("work", "ticket", a, "plan")
check(#Snacks.picker.get() == 0, "switching views closes diff picker")
check(api.nvim_buf_get_name(0) == a .. "/.plans/WORKSPACE-A.md", "plan is visible after closing picker")
cockpit.workspace("personal", "no-plan", b, "", "code", b .. "/code.txt")
cockpit.workspace("personal", "no-plan", b, "", "cycle", "")
check(cockpit.dashboard_snapshot().active, "cycle skips absent plan")
view("work", "plan-writer", a, "code", a .. "/.plans/WORKSPACE-A.md")
check(#Snacks.picker.get() == 1, "latest plan edit opens diff picker, not plan as code")
fn.writefile({ "newest edit" }, a .. "/latest.txt")
view("work", "ticket", a, "", a .. "/latest.txt")
check(api.nvim_buf_get_name(0) == a .. "/latest.txt", "session switch prefers latest edit over saved code")
view("personal", "ticket", b, "")
check(cockpit.dashboard_snapshot().active and cockpit.dashboard_snapshot().model.cwd == b, "session without an edit lands on its own dashboard")
view("work", "ticket", a, "")
check(cockpit.dashboard_snapshot().active, "uncached history initially lands on selected dashboard")
cockpit.follow_remote(a, a .. "/latest.txt", false)
check(api.nvim_buf_get_name(0) == a .. "/latest.txt", "late history advances resting dashboard to latest code")
view("work", "ticket", a, "plan")
cockpit.follow_remote(a, a .. "/latest.txt", false)
check(api.nvim_buf_get_name(0) == a .. "/.plans/WORKSPACE-A.md", "late history respects explicit plan navigation")
view("work", "ticket", a, "", a .. "/deleted.txt")
check(cockpit.dashboard_snapshot().active, "unreadable latest edit falls back to selected dashboard")
local followed = a .. "/followed.txt"
fn.writefile({ "one", "two", "three", "four" }, followed)
cockpit.follow_remote(a, followed, true, 2)
check(api.nvim_buf_get_name(0) == followed and api.nvim_win_get_cursor(0)[1] == 2, "live edit moves the cursor to its changed line")
local flash_ns = api.nvim_create_namespace("cockpit-edit-flash:work/ticket")
check(#api.nvim_buf_get_extmarks(0, flash_ns, 0, -1, {}) == 0, "cursor-only follows never replay historical git hunks as agent additions")
fn.writefile({ "one", "two", "first agent addition", "three", "four" }, followed)
cockpit.follow_remote(a, followed, true, 3, vim.NIL, { 3 })
check(api.nvim_get_current_line() == "first agent addition", "completed edit reloads the open buffer before positioning")
local flashes = api.nvim_buf_get_extmarks(0, flash_ns, 0, -1, { details = true })
check(#flashes == 1 and flashes[1][2] == 2, "first live addition gets an orange gutter marker")
check(flashes[1][4].sign_text:gsub("%s+$", "") == "▌" and flashes[1][4].sign_hl_group == "CockpitAgentEdit" and not flashes[1][4].hl_group,
  "agent additions use a thick gutter bar without changing the real git gutter or tinting code")
check(api.nvim_get_hl(0, { name = "CockpitAgentEdit", link = false }).fg == api.nvim_get_hl(0, { name = "Cursor", link = false }).bg,
  "agent gutter bar matches the cursor orange")
check(flashes[1][4].priority > 4096, "agent gutter marker outranks the installed Git signs")
check(fn.mode() == "n", "agent gutter marker does not change selection mode")
fn.writefile({ "one", "latest agent addition", "two", "first agent addition", "three", "four" }, followed)
cockpit.follow_remote(a, followed, true, 2, vim.NIL, { 2 })
check(api.nvim_get_current_line() == "latest agent addition", "cursor lands on the latest of successive edits")
flashes = api.nvim_buf_get_extmarks(0, flash_ns, 0, -1, { details = true })
check(#flashes == 2 and flashes[1][2] == 1 and flashes[2][2] == 3,
  "successive additions accumulate and the earlier extmark moves with inserted text")
local flashed_buf = api.nvim_get_current_buf()
vim.wait(1900)
check(#api.nvim_buf_get_extmarks(flashed_buf, flash_ns, 0, -1, {}) == 2, "accumulated additions stay highlighted while the file remains open")
cockpit.follow_remote(a, followed, true, 2, vim.NIL, {})
check(#api.nvim_buf_get_extmarks(0, flash_ns, 0, -1, {}) == 2, "deletion-only edits preserve earlier addition markers")
cockpit.follow_remote(a, followed, true, 900)
check(api.nvim_win_get_cursor(0)[1] == 6, "changed line beyond EOF lands on the last valid line")
cockpit.follow_remote(a, followed, true, vim.NIL, vim.base64.encode("first agent addition"))
check(api.nvim_win_get_cursor(0)[1] == 4, "write locator resolves to inserted text")
vim.wait(20)
api.nvim_exec_autocmds("CursorMoved", { buffer = api.nvim_get_current_buf() })
local paused_cursor = api.nvim_win_get_cursor(0)[1]
fn.writefile({ "one", "latest agent addition", "two", "first agent addition", "three", "four", "paused addition" }, followed)
cockpit.follow_remote(a, followed, false, 7, vim.NIL, { 7 })
check(api.nvim_win_get_cursor(0)[1] == paused_cursor, "manual browsing pauses automatic cursor movement")
flashes = api.nvim_buf_get_extmarks(0, flash_ns, 0, -1, { details = true })
check(#flashes == 3 and flashes[1][2] == 1 and flashes[2][2] == 3 and flashes[3][2] == 6,
  "visible file keeps accumulating gutter markers while cursor movement is paused")
vim.cmd.edit(fn.fnameescape(a .. "/latest.txt"))
vim.cmd.edit(fn.fnameescape(followed))
check(#api.nvim_buf_get_extmarks(0, flash_ns, 0, -1, {}) == 3, "manual file opens preserve the session's accumulated agent additions")
local next_follow = a .. "/next-follow.txt"
fn.writefile({ "next agent file" }, next_follow)
cockpit.follow_remote(a, next_follow, true, 1, vim.NIL, { 1 })
check(#api.nvim_buf_get_extmarks(flashed_buf, flash_ns, 0, -1, {}) == 0
  and #api.nvim_buf_get_extmarks(0, flash_ns, 0, -1, {}) == 1,
  "the same session resets its old markers only when its agent follows a different file")
cockpit.follow_remote(a, followed, true, 4)
local reopened_cursor, protected_line = api.nvim_win_get_cursor(0)[1], api.nvim_get_current_line()
vim.cmd.CockpitFollow()
cockpit.follow_remote(a, followed, true, 1)
check(api.nvim_win_get_cursor(0)[1] == reopened_cursor, "follow off blocks forced live events")
vim.cmd.CockpitFollow()
api.nvim_buf_set_lines(0, 0, 1, false, { "unsaved local line" })
cockpit.follow_remote(a, b .. "/code.txt", true, 1)
check(api.nvim_buf_get_name(0) == followed and api.nvim_get_current_line() == protected_line, "live follow preserves the displayed unsaved buffer")
vim.bo.modified = false
cockpit.follow_remote(a, b .. "/code.txt", true, 1)
check(api.nvim_buf_get_name(0) == b .. "/code.txt" and cockpit.workspace_cwd() == a,
  "public live-follow opens an absolute foreign-repository path without rebinding the selected workspace")
local hidden = fn.bufadd(a .. "/hidden.txt")
fn.writefile({ "disk" }, a .. "/hidden.txt")
fn.bufload(hidden)
api.nvim_buf_set_lines(hidden, 0, 1, false, { "unsaved hidden line" })
cockpit.follow_remote(a, a .. "/hidden.txt", true, 1)
check(api.nvim_buf_get_name(0) == b .. "/code.txt", "live follow protects unsaved destination buffers too")
vim.bo[hidden].modified = false
local directory_changes = 0
local watch = api.nvim_create_autocmd("DirChanged", { callback = function() directory_changes = directory_changes + 1 end })
view("work", "ticket", a, "plan")
view("work", "ticket", a, "dashboard")
check(directory_changes == 0, "view switches do not retrigger checkout setup")
api.nvim_del_autocmd(watch)
local huge = fixture("work/lovable.daphen-every-9999")
for i = 1, 201 do fn.writefile({ "incoming main file" }, string.format("%s/main-%03d.txt", huge, i)) end
git(huge, "add", ".")
git(huge, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "large main merge")
view("work", "large-merge", huge, "dashboard")
check(vim.wait(3000, function()
  local summary = cockpit.git_summary(huge)
  return summary and summary.add == 0 and summary.del == 0
end), "remote merge-sized diff fails closed instead of rendering false hunks")
view("personal", "background-b", b, "dashboard")
local visible_win, visible_buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
local visible_cursor = api.nvim_win_get_cursor(visible_win)
local background = a .. "/background.txt"
fn.writefile({ "one", "two", "three" }, background)
local recorded, file_changed = cockpit.record_edit(
  "personal", "background-a", a, background, { 2 }, false, 1789465836000, 2)
check(recorded and file_changed, "first accepted file reports that the owning agent changed files")
fn.writefile({ "zero", "one", "two", "three" }, background)
recorded, file_changed = cockpit.record_edit(
  "personal", "background-a", a, background, { 1 }, false, 1789465837000, 1)
check(recorded and not file_changed, "a later accepted write to the same file reports no file change")
fn.writefile({ "zero", "one", "two", "three", "same millisecond" }, background)
check(cockpit.record_edit("personal", "background-a", a, background, { 5 }, false, 1789465837000, 5),
  "same-millisecond live additions are accepted and accumulated")
local background_buf = fn.bufnr(background)
local background_ns = api.nvim_create_namespace("cockpit-edit-flash:personal/background-a")
local background_marks = api.nvim_buf_get_extmarks(background_buf, background_ns, 0, -1, {})
check(#background_marks == 3 and background_marks[1][2] == 0
  and background_marks[2][2] == 2 and background_marks[3][2] == 4,
  "unselected session edits accumulate in their owning namespace and move with hidden-buffer reloads")
check(api.nvim_get_current_win() == visible_win and api.nvim_get_current_buf() == visible_buf
  and vim.deep_equal(api.nvim_win_get_cursor(visible_win), visible_cursor)
  and cockpit.workspace_cwd() == b,
  "background edit recording preserves the selected workspace, visible buffer, cursor, and focus")
local provenance = a .. "/provenance.txt"
fn.writefile({ "live row", "snapshot row", "third" }, provenance)
recorded, file_changed = cockpit.record_edit(
  "personal", "provenance", a, provenance, { 1 }, false, 104, 1, "edit-X")
check(recorded and file_changed, "live edit provenance is recorded with its first file")
recorded, file_changed = cockpit.record_edit(
  "personal", "provenance", a, provenance, { 2 }, true, 101, 2, "edit-X")
local provenance_buf = fn.bufnr(provenance)
local provenance_ns = api.nvim_create_namespace("cockpit-edit-flash:personal/provenance")
local provenance_marks = api.nvim_buf_get_extmarks(provenance_buf, provenance_ns, 0, -1, {})
check(recorded and not file_changed and #provenance_marks == 1 and provenance_marks[1][2] == 1,
  "older authoritative snapshot for the same completed edit replaces its live markers")
local old_provenance = a .. "/old-provenance.txt"
fn.writefile({ "old" }, old_provenance)
check(not cockpit.record_edit(
    "personal", "provenance", a, old_provenance, { 1 }, true, 100, 1, "edit-Y")
  and fn.bufnr(old_provenance) == -1
  and #api.nvim_buf_get_extmarks(provenance_buf, provenance_ns, 0, -1, {}) == 1,
  "older snapshot for a different edit remains rejected without changing provenance marks")
local stale_background = a .. "/stale-background.txt"
fn.writefile({ "stale snapshot" }, stale_background)
check(not cockpit.record_edit("personal", "background-a", a, stale_background, { 1 }, true,
    "2026-09-15T11:50:36.509Z")
  and not cockpit.record_edit("personal", "background-a", a, stale_background, { 1 }, true, 1789465837000)
  and #api.nvim_buf_get_extmarks(background_buf, background_ns, 0, -1, {}) == 3
  and fn.bufnr(stale_background) == -1
  and api.nvim_get_current_win() == visible_win and api.nvim_get_current_buf() == visible_buf
  and vim.deep_equal(api.nvim_win_get_cursor(visible_win), visible_cursor)
  and cockpit.workspace_cwd() == b,
  "older and equal snapshots are rejected before changing marks, ownership, selection, or cursor")
local protected_background = a .. "/protected-background.txt"
fn.writefile({ "disk" }, protected_background)
local protected_background_buf = fn.bufadd(protected_background)
fn.bufload(protected_background_buf)
api.nvim_buf_set_lines(protected_background_buf, 0, 1, false, { "local unsaved" })
check(not cockpit.record_edit("personal", "background-a", a, protected_background, { 1 }, false, 1789465837500),
  "modified background destination rejects the write")
check(api.nvim_buf_get_lines(protected_background_buf, 0, 1, false)[1] == "local unsaved"
  and vim.bo[protected_background_buf].modified
  and #api.nvim_buf_get_extmarks(background_buf, background_ns, 0, -1, {}) == 3,
  "background recording protects modified destinations without resetting the owner's current marks")
api.nvim_buf_delete(protected_background_buf, { force = true })
check(cockpit.record_edit("personal", "background-a", a, background, { 2, 4 }, true,
  "2026-09-15T11:50:38.000Z", 4), "newer history hydration is accepted")
background_marks = api.nvim_buf_get_extmarks(background_buf, background_ns, 0, -1, {})
check(#background_marks == 2 and background_marks[1][2] == 1 and background_marks[2][2] == 3,
  "history hydration exactly replaces the owner's complete marker snapshot")
local nonexistent = a .. "/does-not-exist.txt"
check(not cockpit.record_edit("personal", "missing-background", a, nonexistent, { 1 }, false,
  1789465839000, 1), "nonexistent background destinations are rejected")
local missing_errors, saved_notify = {}, vim.notify
vim.notify = function(message, level, ...)
  if level == vim.log.levels.ERROR then missing_errors[#missing_errors + 1] = tostring(message) end
  return saved_notify(message, level, ...)
end
cockpit.workspace("personal", "missing-background", a, "", "code", "")
vim.notify = saved_notify
check(#missing_errors == 0, "selecting an owner whose failed record has no saved buffer does not raise an RPC error")
local foreign_background = b .. "/foreign-background.txt"
fn.writefile({ "foreign one", "foreign latest", "foreign three" }, foreign_background)
check(cockpit.record_edit("personal", "background-foreign", a, foreign_background, { 2 }, false,
  1789465840000, 2), "foreign-repository background edit is recorded")
local foreign_background_ns = api.nvim_create_namespace("cockpit-edit-flash:personal/background-foreign")
cockpit.workspace("personal", "background-foreign", a, "", "code", "")
check(api.nvim_buf_get_name(0) == foreign_background and api.nvim_win_get_cursor(0)[1] == 2
  and #api.nvim_buf_get_extmarks(0, foreign_background_ns, 0, -1, {}) == 1,
  "switching owners restores an agent-followed foreign-repository file with its cursor and markers")
cockpit.workspace("personal", "background-a", a, "", "code", "")
check(api.nvim_buf_get_name(0) == background and api.nvim_win_get_cursor(0)[1] == 4
  and #api.nvim_buf_get_extmarks(0, background_ns, 0, -1, {}) == 2,
  "switching to a previously unselected session restores its newest agent file, cursor, and markers")
view("personal", "highlight-a", a, "dashboard")
cockpit.follow_remote(a, followed, true, 5, vim.NIL, { 5 })
local marked_a = api.nvim_get_current_buf()
local flash_a = api.nvim_create_namespace("cockpit-edit-flash:personal/highlight-a")
check(#api.nvim_buf_get_extmarks(marked_a, flash_a, 0, -1, {}) == 1, "first session owns its agent marker")
view("personal", "highlight-b", b, "dashboard")
cockpit.follow_remote(b, b .. "/code.txt", true, 2, vim.NIL, { 2 })
local marked_b = api.nvim_get_current_buf()
local flash_b = api.nvim_create_namespace("cockpit-edit-flash:personal/highlight-b")
check(#api.nvim_buf_get_extmarks(marked_a, flash_a, 0, -1, {}) == 1
  and #api.nvim_buf_get_extmarks(marked_b, flash_b, 0, -1, {}) == 1,
  "switching sessions preserves both sessions' independently owned markers")
view("personal", "highlight-a", a, "dashboard")
check(#api.nvim_buf_get_extmarks(marked_a, flash_a, 0, -1, {}) == 1
  and #api.nvim_buf_get_extmarks(marked_b, flash_b, 0, -1, {}) == 1,
  "jumping back to a session preserves every session's markers")
print("workspace: " .. checks .. " passed")
fn.delete(root, "rf")
vim.cmd("qa!")
