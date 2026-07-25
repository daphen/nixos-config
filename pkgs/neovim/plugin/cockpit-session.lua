-- Per-cockpit-context session autosave. Only active when the cockpit launches
-- nvim with COCKPIT_NVIM_SESSION set; restore is `nvim -S` from cockpit-add.
local session = vim.env.COCKPIT_NVIM_SESSION
if not session or session == "" then
  return
end

local function save()
  vim.fn.mkdir(vim.fn.fnamemodify(session, ":h"), "p")
  vim.cmd("silent! mksession! " .. vim.fn.fnameescape(session))
end

vim.api.nvim_create_autocmd({ "BufEnter", "FocusLost", "VimLeavePre" }, {
  group = vim.api.nvim_create_augroup("CockpitSession", {}),
  callback = save,
})

-- The machine dying without warning is the threat model — checkpoint on a
-- timer too, since VimLeavePre never fires in a crash.
local timer = (vim.uv or vim.loop).new_timer()
timer:start(60000, 60000, vim.schedule_wrap(save))
