local M = {}

--TODO: way to run a selected chunk of code
--TODO: pre and post build hooks

---@class project-run.Cmds
---@field debug string Command for debug builds
---@field release string Command for release builds

---@class project-run.Preset
---@field paths? string[] Paths to activate this preset on (projects only)
---@field build? project-run.Cmds | string
---@field run_target? project-run.Cmds | string
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
				--TODO: dap integration. do we need a debug command that can also be a function/call dap
				build = {
					debug = "odin build . -o:none -out:out/debug/main -debug",
					release = "odin build . -o:speed -out:out/release/main",
				},
				run_target = { debug = "out/debug/main", release = "out/debug/main" },
				dap_handler = "codelldb",
				test = "odin test test", -- tests need to be in cwd/test
				efm = "%f(%l:%c) %t%*[^:]: %m",
			},
			cpp = {
				build = "g++ {%} -o main -Wall",
				run_target = "./main",
			},
			c = {
				base_ft = "cpp",
			},
		},
		projects = {},
	},
	settings = {
		notify_build_time = true,
	},
}

local function get_current_preset()
	local ft = vim.bo.ft
	if not ft then
		return nil
	end

	--TODO: this code only needs to run on startup and when the dir changes, we can cache this
	local cwd = vim.fn.getcwd()
	for _, project in pairs(config.presets.projects) do
		if project.paths then
			for _, path in ipairs(project.paths) do
				local expanded = vim.fn.expand(path)
				if expanded == "" then
					vim.notify("Invalid path in project preset: " .. path, "error", { title = "Project-run" })
				elseif vim.startswith(cwd, expanded) then
					return project
				end
			end
		end
	end

	return config.presets.filetypes[ft]
end

-- Get the cmd for the current file type and selected mode
---@param mode? "debug" | "release"
---@param action? "build" | "run" | "test"
local function get_action_cmd(mode, action)
	mode = mode or "debug"
	action = action or "build"

	local ft = vim.bo.ft
	if not ft then
		vim.notify("No filetype set for buffer", "error", { title = "Project-run" })
		return false
	end

	local cmd

	local preset = get_current_preset()

	if not preset then
		vim.notify("No " .. action .. " command configured", "error", { title = "Project-run" })
		return false
	end

	if type(preset[action]) == "string" then
		cmd = preset[action]
	elseif preset[action] then
		cmd = preset[action][mode]
	end

	if not cmd then
		return false
	end

	local function expand_word(word)
		local cap = word:sub(2, #word - 1)
		return vim.fn.expand(cap)
	end

	-- expand {} using vim.fn.expand()
	return cmd:gsub("{.-}", expand_word)
end

-- build the current ft
---@param mode? "release" | "debug"
---@param callback function Function to call when done
function M.build(mode, callback)
	local cmd = get_action_cmd(mode, "build")

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

local function post_build_action(action, mode, build)
	mode = mode or "debug"

	if build == nil then
		build = true
	end

	local function terman_action()
		local cmd = get_action_cmd(mode, action)
		if not cmd then
			vim.notify("No " .. action .. " command configured", "error", { title = "Project-run" })
			return false
		end

		local job_name = "Project-run-" .. action .. "-" .. vim.bo.ft

		local terman_preset = {
			name = job_name,
			cmd = cmd,
			persist = true,
		}

		require("terman").open(terman_preset)
	end

	local function run_if_success(code)
		if code == 0 then
			terman_action()
		end
	end

	--TODO: move this line into the get preset function
	local preset = get_current_preset() or config.presets.filetypes[vim.bo.ft]

	if build then
		M.build(mode, run_if_success)
	else
		terman_action()
	end
end

-- run current ft
---@param mode? "release" | "debug"
---@param build? boolean Whether to build first
---@param launch_debug? boolean Launch debug via dap
function M.launch(mode, build, launch_debug)
	post_build_action("run", mode, build)
end

---@param build? boolean Whether to build first
function M.launch_debug(build)
	if build == nil then
		build = true
	end

	local function launch_dap(code)
		if code == 0 then
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

			-- untested
			local program
			if type(preset.run_target) == "string" then
				program = preset.run_target
			elseif preset.run_target.debug then
				program = preset.run_target.debug
			else
				vim.notify("No run target found", "error", { title = "Project-run" })
				return
			end

			local dap_config = {
				console = "integratedTerminal",
				name = "Project-Run Debug",
				program = program, --FIX:
				request = "launch",
				type = preset.dap_handler,
			}

			vim.print(dap_config)
			dap.run(dap_config)
		end
	end

	if build then
		M.build("debug", launch_dap)
	else
		launch_dap(0)
	end
end

---@param build boolean Build first?
function M.test(build)
	post_build_action("test", "debug", build)
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
end

return M
