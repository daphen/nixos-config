local M = {}

local function u32(value)
  return string.char(
    math.floor(value / 0x1000000) % 0x100,
    math.floor(value / 0x10000) % 0x100,
    math.floor(value / 0x100) % 0x100,
    value % 0x100
  )
end

local function read_u32(data, offset)
  local a, b, c, d = data:byte(offset, offset + 3)
  if not d then return nil end
  return ((a * 0x100 + b) * 0x100 + c) * 0x100 + d
end

local function qstring(value)
  local ok, utf16 = pcall(vim.iconv, value, "utf-8", "utf-16be")
  if not ok or not utf16 then return nil end
  return u32(#utf16) .. utf16
end

local function endpoint()
  local editor = vim.fn.fnamemodify(vim.v.servername or "", ":t")
  if editor == "" then return nil, "editor has no server name" end
  local runtime = vim.env.XDG_RUNTIME_DIR or ("/run/user/" .. vim.fn.getuid())
  local file = io.open(runtime .. "/cockpit-ipc." .. editor .. ".id", "r")
  if not file then return nil, "Cockpit IPC binding is unavailable" end
  local instance = vim.trim(file:read("*l") or "")
  file:close()
  if not instance:match("^[%w_-]+$") then return nil, "Cockpit IPC binding is invalid" end
  return runtime .. "/quickshell/by-id/" .. instance .. "/ipc.sock"
end

local function packet(method, args)
  local target, fn = qstring("cockpit"), qstring(method)
  if not target or not fn then return nil, "IPC method is not valid UTF-8" end
  local parts = { string.char(3), target, fn, u32(#args) }
  for _, arg in ipairs(args) do
    local encoded = qstring(arg)
    if not encoded then return nil, "IPC argument is not valid UTF-8" end
    parts[#parts + 1] = encoded
  end
  return table.concat(parts)
end

local function start(method, args, timeout_ms, callback)
  if type(method) ~= "string" or method == "" then callback(false, "IPC method is required"); return end
  if type(args) ~= "table" or not vim.islist(args) then callback(false, "IPC arguments must be a list"); return end
  for _, arg in ipairs(args) do
    if type(arg) ~= "string" then callback(false, "IPC arguments must be strings"); return end
  end
  local path, path_err = endpoint()
  if not path then callback(false, path_err); return end
  local request, request_err = packet(method, args)
  if not request then callback(false, request_err); return end

  local pipe, response, done = vim.uv.new_pipe(false), "", false
  local function finish(ok, value)
    if done then return end
    done = true
    if not pipe:is_closing() then pipe:close() end
    callback(ok, value)
  end
  vim.defer_fn(function() finish(false, "Cockpit IPC timed out") end, timeout_ms)
  pipe:connect(path, function(connect_err)
    if connect_err then finish(false, connect_err); return end
    pipe:read_start(function(read_err, data)
      if read_err then finish(false, read_err); return end
      if not data then finish(false, "Cockpit IPC closed without a reply"); return end
      response = response .. data
      local tag = response:byte(1)
      if tag and tag ~= 5 then finish(false, "Cockpit IPC call failed (reply " .. tag .. ")"); return end
      if #response < 6 then return end
      local length = read_u32(response, 3)
      if length == 0xffffffff then length = 0 end
      if length % 2 ~= 0 then finish(false, "Cockpit IPC returned an invalid string"); return end
      if #response < 6 + length then return end
      local ok, value = pcall(vim.iconv, response:sub(7, 6 + length), "utf-16be", "utf-8")
      if not ok or not value then finish(false, "Cockpit IPC returned invalid UTF-16"); return end
      finish(true, value)
    end)
    pipe:write(request, function(write_err)
      if write_err then finish(false, write_err) end
    end)
  end)
end

function M.call(method, args, timeout_ms, callback)
  args, timeout_ms = args or {}, timeout_ms or 1000
  if callback then start(method, args, timeout_ms, callback); return end
  local settled, ok, value = false, false, nil
  start(method, args, timeout_ms, function(call_ok, result)
    settled, ok, value = true, call_ok, result
  end)
  vim.wait(timeout_ms + 50, function() return settled end, 5)
  if not settled then return false, "Cockpit IPC timed out" end
  return ok, value
end

return M
