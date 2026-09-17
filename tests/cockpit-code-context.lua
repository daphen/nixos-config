local api, fn = vim.api, vim.fn
local home = assert(vim.env.HOME)
assert(home:find("/tmp/cockpit-code-", 1, true), "isolated HOME required")
fn.mkdir(home .. "/bin", "p")
local fake = '#!/usr/bin/env python3\nimport sys,json,os\nfrom pathlib import Path\na=sys.argv[1:]\nif Path(sys.argv[0]).name=="qs":\n if a[-1]=="railState": print(json.dumps({"sel":"target","scopeMode":"personal"}))\n elif a[-2]=="editorContext":\n  with open(os.environ["HOME"]+"/contexts","a") as f:f.write(Path(a[-1]).read_text().strip()+"\\n")\n  print("accepted")\nelse:\n with open(os.environ["HOME"]+"/dispatches","a") as f:f.write(json.dumps({"args":a,"text":sys.stdin.read()})+"\\n")\n'
for _, name in ipairs({ "qs", "agent" }) do fn.writefile(vim.split(fake, "\n"), home .. "/bin/" .. name); fn.setfperm(home .. "/bin/" .. name, "rwxr-xr-x") end
vim.env.PATH = home .. "/bin:" .. vim.env.PATH
local plan = require("plan-nvim")
plan.setup()
local function last(file)
  assert(vim.wait(1000, function() return fn.filereadable(home .. "/" .. file) == 1 end, 10), "missing " .. file)
  local lines = fn.readfile(home .. "/" .. file)
  return vim.json.decode(lines[#lines])
end
local checks = 0
local function check(value, message) assert(value, message); checks = checks + 1 end
local function key(value) api.nvim_feedkeys(api.nvim_replace_termcodes(value, true, false, true), "xt", false) end
local file = home .. "/code with spaces.ts"
fn.writefile({ "saved" }, file); vim.cmd.edit(file)
api.nvim_buf_set_lines(0, 0, -1, false, { "αlpha beta", "second line" })
for _, case in ipairs({ {"gg0v2l", "αlp", "v"}, {"2G05lv3h", "cond", "v"}, {"ggVj", "αlpha beta\nsecond line", "V"}, {"gg0\022j2l", "αlp\nsec", "\022"} }) do
  key("<Esc>"); vim.cmd("normal! " .. case[1]); key("<C-p>")
  local data = last("contexts")
  check(data.kind == "code" and data.text == case[2], "exact visual selection lost: " .. data.text)
  check(api.nvim_get_mode().mode == case[3], "selection highlight/mode lost")
  check(data.session == "target" and data.mode == "personal" and data.path == file, "selection routed outside current window/session")
end
key("<Esc>"); vim.o.selection = "exclusive"
vim.cmd('normal! 2G05lv3h"zy'); local exact = fn.getreg("z")
vim.cmd("normal! gv"); key("<C-p>")
check(last("contexts").text == exact, "backward exclusive selection differs from native yank: " .. last("contexts").text .. " / " .. exact)
key("<Esc>"); vim.o.selection = "inclusive"
api.nvim_buf_set_lines(0, 0, -1, false, { string.rep("z", 200000) }); vim.cmd("normal! ggV"); key("<C-p>")
check(#last("contexts").text == 200000, "large selection was truncated or sent as an argument")
check(fn.readfile(file)[1] == "saved" and vim.bo.modified, "selection saved or lost unsaved edits")
key("<Esc>")
local dir = home .. "/personal/notes/storage/plans"
fn.mkdir(dir, "p"); fn.mkdir(home .. "/.local/state/agentd", "p")
local path = dir .. "/example.md"
fn.writefile({ "# Example", "", "> Status: `draft`" }, path)
fn.writefile({ vim.json.encode({ {name="target",plan="example"} }) }, home .. "/.local/state/agentd/personal-sessions.json")
vim.cmd("hide edit " .. fn.fnameescape(path)); key("<C-p>")
local menu = last("contexts")
check(menu.kind == "menu" and #menu.labels == 7 and menu.labels[3]:find("finalize first",1,true), "plan menu/lock metadata changed")
plan.menu(3, path)
check(fn.filereadable(home .. "/dispatches") == 0, "locked action dispatched")
api.nvim_buf_set_lines(0, 2, 3, false, { "> Status: `finalized`" }); vim.cmd.write()
plan.menu(3, path)
check(last("contexts").actions[1] == "confirm-go" and fn.filereadable(home .. "/dispatches") == 0, "implementation confirmation was bypassed")
api.nvim_buf_set_lines(0, 2, 3, false, { "> Status: `draft`" })
plan.menu("confirm-go", path)
check(fn.filereadable(home .. "/dispatches") == 0, "confirmation bypassed a changed plan lock")
api.nvim_buf_set_lines(0, 2, 3, false, { "> Status: `finalized`" }); vim.cmd.write()
plan.menu("confirm-go", path)
check(last("dispatches").text:find("/plan-ticket --go example",1,true) ~= nil, "fresh plan state did not unlock implementation")
plan.menu(5, path)
local draft = last("contexts")
check(draft.kind == "compose" and #api.nvim_list_wins() == 1, "amend opened a Neovim modal")
local input = home .. "/submit.json"
fn.writefile({ vim.json.encode({id=draft.id,text="Add keyboard tests"}) }, input)
check(plan.submit_compose(input) == "sent", "chat draft did not reach original plan callback")
check(vim.wait(1000, function() return last("dispatches").text:find("--amend example",1,true) ~= nil end, 10), "amend routing changed")
check(last("dispatches").args[2] == "target", "plan action lost its bound-session target")
vim.env.COCKPIT_INSTANCE = nil; vim.env.HEIDR_INSTANCE = nil
local native = false; vim.ui.select = function() native = true end
plan.menu()
check(native, "ordinary Neovim menu fallback was removed")
local confirmed = false; fn.confirm = function() confirmed = true; return 2 end
vim.cmd.PlanGo()
check(confirmed, "PlanGo command options bypassed confirmation")
print("code context: " .. checks .. " passed")
vim.cmd("qa!")
