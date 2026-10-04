local baseline = assert(arg[1], "pass the baseline config path")
local candidate = assert(arg[2], "pass the candidate config path")

local function normalize(value)
	if type(value) == "function" then
		return "<callback>"
	end
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, item in pairs(value) do
		result[key] = normalize(item)
	end
	return result
end

local function load_config(path)
	local calls, config = {}, {}
	local function merge(target, source)
		for key, value in pairs(source) do
			if type(value) == "table" and type(target[key]) == "table" then
				merge(target[key], value)
			else
				target[key] = normalize(value)
			end
		end
	end
	local function api(name)
		return setmetatable({}, {
			__index = function(_, key)
				return api(name .. "." .. key)
			end,
			__call = function(_, ...)
				local args = { ... }
				if name == "hl.config" then
					merge(config, args[1])
				else
					calls[#calls + 1] = { name, normalize(args) }
				end
				return setmetatable({ command = name, args = normalize(args) }, {
					__index = function(_, key) return api(name .. "." .. key) end,
				})
			end,
		})
	end
	_G.hl = api("hl")
	for name in pairs(package.loaded) do
		if name:match("^modules%.") then
			package.loaded[name] = nil
		end
	end
	package.loaded["canvas-state"] = { read = function() return {} end }
	local old_path = package.path
	package.path = path:match("^(.*)/") .. "/?.lua;" .. old_path
	assert(loadfile(path))()
	package.path = old_path
	return { calls = calls, config = config }
end

local before = load_config(baseline)
local after = load_config(candidate)
if not vim.deep_equal(before, after) then
	vim.fn.writefile({ vim.inspect(before) }, "/tmp/hyprland-parity-before.txt")
	vim.fn.writefile({ vim.inspect(after) }, "/tmp/hyprland-parity-after.txt")
	error("config API parity failed; traces in /tmp/hyprland-parity-{before,after}.txt")
end
print("PASS config values and " .. #after.calls .. " ordered API registrations match")
