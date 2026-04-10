local M = {}

--TODO: presets for:
-- Rust
-- Go
-- Zig
-- Java
-- Lua
-- JS
-- C

---@class project-run.Cmds
---@field debug string Command for debug builds
---@field release string Command for release builds

---@class project-run.Preset
---@field paths? string[] Paths to activate this preset on (projects only)
---@field build? project-run.Cmds | string
---@field target? project-run.Cmds | string Path to target file
---@field run_cmd? project-run.Cmds | string Command to use instead of run target. Best for interpreted langs
---@field dap_handler? string DAP Handler to use
---@field test? string Command to run for tests
---@field efm? string Custom errorformat to apply to qf
---@field base_ft? string Filetype to use as template

---@class project-run.Settings
---@field notify_build_time boolean Whether to send a notification containing the build time

---@class project-run.Config
---@field presets { filetypes: table<string, project-run.Preset>, projects: table<string, project-run.Preset> }
---@field settings project-run.Settings

---@class project-run.UserConfig
---@field presets? { filetypes: table<string, project-run.Preset>, projects: table<string, project-run.Preset> }
---@field settings? project-run.Settings
local config = {
	presets = {
		filetypes = {
			odin = {
				build = {
					debug = "odin build . -o:none -out:out/debug/main -debug",
					release = "odin build . -o:speed -out:out/release/main",
				},
				target = { debug = "out/debug/main", release = "out/release/main" },
				test = "odin test test", -- tests need to be in cwd/test
				dap_handler = "codelldb",
				efm = "%f(%l:%c) %t%*[^:]: %m",
			},
			cpp = {
				build = "g++ {%} -o main -Wall",
				target = "./main",
				dap_handler = "codelldb",
			},
			python = {
				target = "{%}",
				run_cmd = "python {%}",
				dap_handler = "python",
			},
		},
		projects = {},
	},
	settings = {
		notify_build_time = true,
	},
}

local state = {
	current_project = nil,
	loaded_local_configs = {},
}

-- check if we are in a project dir and update state
local function check_project()
	state.current_project = nil

	local cwd = vim.fn.getcwd()
	for _, project in pairs(config.presets.projects) do
		if project.paths then
			for _, path in ipairs(project.paths) do
				local expanded = vim.fn.expand(path)
				if expanded == "" then
					vim.notify("Invalid path in project preset: " .. path, "error", { title = "Project-run" })
				elseif vim.startswith(cwd, expanded) then
					state.current_project = project
				end
			end
		end
	end
end

local function get_current_preset()
	return state.current_project or config.presets.filetypes[vim.bo.ft]
end

-- expand {} using vim.fn.expand()
local function expand(str)
	local function expand_word(word)
		local capture = word:sub(2, #word - 1)
		return vim.fn.expand(capture)
	end

	return str:gsub("{.-}", expand_word)
end

-- Navigate the cmd | string structure in config
---@param mode "debug" | "release"
---@param key string Key to locate
local function get_mode_command(mode, key)
	local preset = get_current_preset()

	if not preset then
		return false
	end

	local cmd

	if type(preset[key]) == "string" then
		cmd = preset[key]
	elseif preset[key] then
		cmd = preset[key][mode]
	end

	if not cmd then
		return false
	end

	return expand(cmd)
end

-- build the current ft
---@param mode? "release" | "debug"
---@param callback? function Function to call when done
function M.build(mode, callback)
	if mode == nil then
		mode = "debug"
	end

	local cmd = get_mode_command(mode, "build")

	if not cmd then
		vim.notify("No build command configured", "error", { title = "Project-run" })
		return false
	end

	local handle_output = function(data)
		if data == nil or (#data == 1 and data[1] == "") then
			return
		end

		local efm
		local preset = get_current_preset()
		if preset then
			efm = preset.efm
		end

		local items = vim.fn.getqflist({ lines = data, efm = efm }).items
		vim.fn.setqflist(items, "a")
	end

	local start_time = vim.uv.hrtime()

	vim.fn.setqflist({})
	vim.fn.jobstart(cmd, {
		stdout_buffered = true,
		stderr_buffered = true,
		on_stdout = function(_, data)
			handle_output(data)
		end,
		on_stderr = function(_, data)
			handle_output(data)
		end,
		on_exit = function(_, code, _)
			vim.schedule(function()
				local qf = vim.fn.getqflist()
				if #qf > 0 then -- qf is populated
					vim.cmd("botright copen")
				else -- qf empty
					vim.cmd("cclose")
				end

				if code == 0 then
					if config.settings.notify_build_time then
						local message = string.format("Build completed in %.2fms", (vim.uv.hrtime() - start_time) / 1e6)
						vim.notify(message, "info", { title = "Project-run" })
					end
				else
					vim.notify("Build failed with code " .. code, "error", { title = "Project-run" })
				end

				if callback then
					callback(code)
				end
			end)
		end,
	})
end

local function run_terman(cmd, name)
	local job_name = "Project-Run-" .. name

	local terman_preset = {
		name = job_name,
		cmd = cmd,
		persist = true,
	}

	require("terman").open(terman_preset)
end

---@param action "launch" | "test" | "launch_DAP"
---@param mode "debug" | "release"
---@param build boolean
local function post_build_action(action, mode, build)
	local preset = get_current_preset()
	if not preset then
		vim.notify("No preset found", "error", { title = "Project-run" })
		return false
	end

	-- handle non-compiled langs
	if preset.build == nil then
		build = false
	end

	local function launch_DAP()
		local dap = require("dap")

		if not preset.dap_handler then
			vim.notify("No DAP handler configured for this preset", "error", { title = "Project-run" })
			return
		end

		local program
		if type(preset.target) == "string" then
			program = preset.target
		elseif preset.target.debug then
			program = preset.target.debug
		else
			vim.notify("No run target found", "error", { title = "Project-run" })
			return
		end

		-- resolve substitutions
		program = expand(program)

		local dap_config = {
			console = "integratedTerminal",
			name = "Project-Run Debug",
			program = program,
			request = "launch",
			type = preset.dap_handler,
		}
		dap.run(dap_config)
	end

	local function run_if_success(code)
		if code == 0 then
			if action == "launch" or action == "test" then
				local cmd
				if action == "test" then
					cmd = preset.test
				else
					cmd = get_mode_command(mode, "target")
				end

				if not cmd then
					vim.notify("No " .. action .. " command configured", "error", { title = "Project-run" })
					return false
				end

				run_terman(cmd, action)
			else
				-- action == "launch_DAP"
				launch_DAP()
			end
		end
	end

	if build then
		M.build(mode, run_if_success)
	else
		run_if_success(0)
	end
end

-- run current ft
---@param mode? "release" | "debug"
---@param build? boolean Whether to build first when applicable
function M.launch(mode, build)
	mode = mode or "debug"

	local preset = get_current_preset()
	if not preset then
		vim.notify("No preset found", "error", { title = "Project-run" })
		return false
	end

	if preset.run_cmd then
		local cmd = get_mode_command(mode, "run_cmd")
		run_terman(cmd, "launch")
		return false
	end

	if build == false then
		post_build_action("launch", mode, false)
	else
		post_build_action("launch", mode, true)
	end
end

---@param build? boolean Whether to build first when applicable
function M.launch_DAP(build)
	if build == false then
		post_build_action("launch_DAP", "debug", false)
	else
		post_build_action("launch_DAP", "debug", true)
	end
end

---@param build? boolean Build first?
function M.test(build)
	if build == false then
		post_build_action("test", "debug", false)
	else
		post_build_action("test", "debug", true)
	end
end

local function resolve_base_filetype(presets)
	for key, preset in pairs(presets) do
		local base = config.presets.filetypes[preset.base_ft]
		if preset.base_ft and base then
			presets[key] = vim.tbl_deep_extend("force", base, preset)
		end
	end
end

local function load_local_config()
	local cwd = vim.fn.getcwd()

	if state.loaded_local_configs[cwd] then
		return
	end

	local data = vim.secure.read(".project-run.lua")

	if data == nil then
		state.loaded_local_configs[cwd] = false
		return
	end

	local fn = load(data)
	if not fn then
		vim.notify("Failed to load local config", "error", { title = "Project-run" })
		return
	end

	---@type table<string, project-run.Preset>
	local extracted = fn()

	if not extracted then
		vim.notify("Failed to execute local config", "error", { title = "Project-run" })
		return
	end

	for _, project_config in pairs(extracted) do
		if not project_config.paths then
			project_config.paths = {}
		end
		if not vim.tbl_contains(project_config.paths, cwd) then
			table.insert(project_config.paths, cwd)
		end
	end

	resolve_base_filetype(extracted)

	config.presets.projects = vim.tbl_deep_extend("force", config.presets.projects, extracted)
	state.loaded_local_configs[cwd] = true
	vim.notify("Loaded local project config", "info", { title = "Project-run" })
end

---@param opts? project-run.UserConfig
function M.setup(opts)
	opts = opts or {}
	config = vim.tbl_deep_extend("force", config, opts)

	resolve_base_filetype(config.presets.filetypes)
	resolve_base_filetype(config.presets.projects)

	vim.api.nvim_create_autocmd({ "VimEnter", "DirChanged" }, {
		desc = "Check for project",
		group = vim.api.nvim_create_augroup("project-run", { clear = true }),
		callback = function()
			load_local_config()
			check_project()
		end,
	})
	load_local_config()
	check_project()
end

function M.list_current_preset()
	if state.current_project then
		vim.print(state.current_project)
	else
		vim.print(config.presets.filetypes[vim.bo.ft])
	end
end

function M.list_presets()
	vim.print(config.presets)
end

return M
