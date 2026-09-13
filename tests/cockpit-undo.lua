local fn = vim.fn
local home = assert(vim.env.HOME)
assert(home:find("/tmp/cockpit-undo-", 1, true), "isolated HOME required")
local shared = fn.stdpath("state") .. "/undo"
fn.mkdir(shared, "p", 448)
vim.opt.undodir = shared .. "//"
vim.opt.undofile = true
local file = home .. "/source.txt"
fn.writefile({ "before" }, file)
vim.cmd.edit(file)
vim.cmd("normal! ccafter\027")
vim.cmd.write()
local old = fn.undofile(file)
assert(fn.filereadable(old) == 1, "shared history fixture was not written")
local bytes = fn.readblob(old)
vim.cmd.bwipeout()
require("core.options")
local instance = vim.env.COCKPIT_INSTANCE
local directory = shared .. "/cockpit-" .. instance
assert(fn.undofile(file):sub(1, #directory + 1) == directory .. "/", "write destination must be per instance")
assert(fn.getfperm(directory) == "rwx------", "undo directory must be private")
vim.cmd.edit(file)
vim.cmd.undo()
assert(fn.getline(1) == "before", "old shared history must remain readable")
vim.cmd.redo()
assert(fn.getline(1) == "after", "old redo history preserved")
vim.cmd.write()
assert(fn.filereadable(fn.undofile(file)) == 1, "new history written in the instance directory")
assert(vim.deep_equal(fn.readblob(old), bytes), "shared fallback must not be rewritten")
print("cockpit undo: 7 passed for " .. instance)
vim.cmd("qa!")
