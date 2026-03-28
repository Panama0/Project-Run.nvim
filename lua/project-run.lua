local M = {}

--TODO: way to run a selected chunk of code

--TODO: add testing as a cmd or string

---@class project-run.Cmds
---@field debug string Command for debug builds
---@field release string Command for release builds

---@class project-run.Preset
---@field paths? string[] Paths to activate this preset on (projects only)
---@field build? project-run.Cmds | string
---@field run? project-run.Cmds | string
---@field efm? string Custom errorformat to apply to qf
---@field project_name? string Project name - used for replacements
---@field base_ft? string Filetype to use as template (projects only)

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
				build = { debug = "odin build .", release = "odin build ." },
				run = "odin run .",
				efm = "%f(%l:%c) %t%*[^:]: %m",
			},
			cpp = {
				build = "g++ {%} -o main -Wall",
				run = "./main",
			},
			c = {
				base_ft = "cpp",
			},
		},
		projects = {
			-- test = {
			-- 	base_ft = "odin",
			-- 	paths = { "~/Documents/programming/odin/testmake" },
			-- 	build = { debug = "shell: {$SHELL}", release = "odin build ." },
			-- 	run = "odin run .",
			-- },
		},
	},
	settings = {
		notify_build_time = true,
	},
}

local function get_project_preset()
	local cwd = vim.fn.getcwd()
	for _, project in pairs(config.presets.projects) do
		if project.paths then
			for _, path in ipairs(project.paths) do
				local expanded = vim.fn.expand(path)
				if expanded == "" then
					vim.notify("Invalid path in project preset: " .. path, "warn", { title = "Project-run" })
				elseif vim.startswith(cwd, expanded) then
					return project
				end
			end
		end
	end
	return nil
end

-- Get the cmd for the current file type and selected mode
---@param mode? "debug" | "release"
---@param action? "build" | "run"
local get_run_cmd = function(mode, action)
	mode = mode or "debug"
	action = action or "build"

	local ft = vim.bo.ft
	if not ft then
		return false
	end

	local cmd

	local preset = get_project_preset() or config.presets.filetypes[ft]

	if not preset then
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
M.build = function(mode, callback)
	local cmd = get_run_cmd(mode, "build")

	if not cmd then
		return false
	end

	local handle_output = function(data)
		if data == nil or (#data == 1 and data[1] == "") then
			return
		end

		local efm
		local preset = get_project_preset() or config.presets.filetypes[vim.bo.ft]
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

-- run current ft
---@param mode? "release" | "debug"
---@param build? boolean Whether to build first
M.run = function(mode, build)
	mode = mode or "debug"

	if build == nil then
		build = true
	end

	local function run()
		local cmd = get_run_cmd(mode, "run")
		if not cmd then
			return false
		end

		local job_name = "Project-run-" .. vim.bo.ft

		local terman_preset = {
			name = job_name,
			cmd = cmd,
			persist = true,
		}

		require("terman").open(terman_preset)
	end

	-- setup callback
	local function run_if_success(code)
		if code == 0 then
			run()
		end
	end

	if build then
		M.build(mode, run_if_success)
	else
		run()
	end
end

---@param user_config? project-run.UserConfig
M.setup = function(user_config)
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
