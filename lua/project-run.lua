local M = {}

--TODO: presets for:
-- Rust
-- Go
-- Zig
-- Java
-- Lua
-- JS

---@class project-run.Cmds
---@field debug string Command for debug builds
---@field release string Command for release builds

---@class project-run.Preset
---@field paths? string[] Paths to activate this preset on (projects only)
---@field build? project-run.Cmds | string
---@field run_target? project-run.Cmds | string Path to target file
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
				run_target = { debug = "out/debug/main", release = "out/release/main" },
				test = "odin test test", -- tests need to be in cwd/test
				dap_handler = "codelldb",
				efm = "%f(%l:%c) %t%*[^:]: %m",
			},
			cpp = {
				build = "g++ {%} -o main -Wall",
				run_target = "./main",
				dap_handler = "codelldb",
			},
			c = {
				base_ft = "cpp",
			},
			python = {
				run_target = "{%}",
				dap_handler = "python",
			},
		},
		projects = {
			test = {
				paths = { "~/Documents/programming/odin/testmake/testproject" },
				base_ft = "odin",
			},
		},
	},
	settings = {
		notify_build_time = true,
	},
}

local state = {
	current_project = nil,
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
		end,
	})
end

---@param action "launch" | "test" | "launch_DAP"
---@param mode "debug" | "release"
---@param build boolean
local function post_build_action(action, mode, build)
	mode = mode or "debug"

	local function run_action_terman()
		-- diagnostic can be ignored as we check for this, but could be fixed later
		local cmd
		if action == "test" then
			cmd = get_current_preset().test
		else
			cmd = get_mode_command(mode, "run_target")
		end

		if not cmd then
			vim.notify("No " .. action .. " command configured", "error", { title = "Project-run" })
			return false
		end

		local job_name = "Project-Run-" .. action

		local terman_preset = {
			name = job_name,
			cmd = cmd,
			persist = true,
		}

		require("terman").open(terman_preset)
	end

	local function launch_DAP()
		local dap = require("dap")
		local ft = vim.bo.ft

		if not ft then
			return
		end

		local preset = get_current_preset()
		if not preset then
			vim.notify("No preset found for buffer", "error", { title = "Project-run" })
			return
		end

		if not preset.dap_handler then
			vim.notify("No DAP handler configured for this preset", "error", { title = "Project-run" })
			return
		end

		local program
		if type(preset.run_target) == "string" then
			program = preset.run_target
		elseif preset.run_target.debug then
			program = preset.run_target.debug
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
				run_action_terman()
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
---@param mode "release" | "debug"
---@param build? boolean Whether to build first when applicable
function M.launch(mode, build)
	if build == false then
		post_build_action("launch", mode, false)
	else
		post_build_action("launch", mode, true)
	end
end

---@param build? boolean Whether to build first when applicable
function M.launch_DAP(build)
	-- dont build unless its configured with a build command
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

---@param user_config? project-run.UserConfig
function M.setup(user_config)
	user_config = user_config or {}
	config = vim.tbl_deep_extend("force", config, user_config)

	local function resolve_base_presets(presets)
		for key, preset in pairs(presets) do
			local base = config.presets.filetypes[preset.base_ft]
			if preset.base_ft and base then
				presets[key] = vim.tbl_deep_extend("force", base, preset)
			end
		end
	end

	resolve_base_presets(config.presets.filetypes)
	resolve_base_presets(config.presets.projects)

	vim.api.nvim_create_autocmd({ "VimEnter", "DirChanged" }, {
		desc = "Check for project",
		group = vim.api.nvim_create_augroup("project-run", { clear = true }),
		callback = check_project,
	})
	check_project()
end

return M
