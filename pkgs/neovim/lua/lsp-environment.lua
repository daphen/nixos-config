local notified = {}

local function gate(root, on_dir)
  local envroot = vim.fs.root(root or vim.fn.getcwd(), ".envrc")
  if not envroot then
    on_dir(root)
    return
  end
  vim.system({ "direnv", "status", "--json" }, { cwd = envroot, text = true }, function(result)
    local ok, status = pcall(vim.json.decode, result.stdout or "")
    local found = ok and status.state and status.state.foundRC
    local allowed = result.code == 0 and found and found.allowed == 0
      and vim.fs.normalize(found.path) == vim.fs.joinpath(vim.fs.normalize(envroot), ".envrc")
    vim.schedule(function()
      if allowed then
        on_dir(root)
      elseif not notified[envroot] then
        notified[envroot] = true
        vim.notify("LSP paused: " .. envroot .. "/.envrc is not allowed; run `direnv allow "
          .. envroot .. "` if you trust it, then reopen the file", vim.log.levels.WARN)
      end
    end)
  end)
end

return function(config, command, prefer_local)
  local native_root = config.root_dir
  local markers = config.root_markers
  return {
    root_dir = function(bufnr, on_dir)
      local check = function(root) gate(root, on_dir) end
      if type(native_root) == "function" then
        native_root(bufnr, check)
      else
        local root = native_root
        if root == nil and markers then root = vim.fs.root(bufnr, markers) end
        check(root)
      end
    end,
    cmd = function(dispatchers, runtime)
      local root = runtime.root_dir
      local argv = vim.deepcopy(command)
      if prefer_local and root then
        local local_cmd = vim.fs.joinpath(root, "node_modules/.bin", argv[1])
        if vim.fn.executable(local_cmd) == 1 then argv[1] = local_cmd end
      end
      local envroot = vim.fs.root(root or vim.fn.getcwd(), ".envrc")
      if envroot then argv = vim.list_extend({ "direnv", "exec", envroot }, argv) end
      return vim.lsp.rpc.start(argv, dispatchers, {
        cwd = runtime.cmd_cwd or root, env = runtime.cmd_env, detached = runtime.detached,
      })
    end,
  }
end
