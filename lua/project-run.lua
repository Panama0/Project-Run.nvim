local M = {}

---@class project-run.Cmds
---@field debug string Command for debug builds
---@field release string Command for release builds

---@class project-run.Preset
---@field paths? string[] Paths to activate this preset on
---@field build project-run.Cmds | string
---@field run project-run.Cmds | string
---@field efm? string Custom errorformat to apply to qf
---@field project_name? string Project name - used for replacements

---@class project-run.Settings
---@field notify_build_time boolean Whether to send a notification containing the build time

---@class project-run.Config
---@field presets { filetypes: table<string, project-run.Preset>, projects: table<string, project-run.Preset> }
---@field settings project-run.Settings
local config = {
	presets = {
		filetypes = {
			odin = {
				build = { debug = "odin build .", release = "odin build ." },
				run = "odin run .",
				efm = "%f(%l:%c) %t%*[^:]: %m",
			},
			cpp = {
				build = "g++ %%file%% -o %%name%%",
				run = "./%%name%%",
				project_name = "mainnnn",
			},
		},
		projects = {
			test = {
				--TODO: this should inherit from 'ft' = odin
				ft = "odin",
				paths = { "~/Documents/programming/odin/testmake" },
				build = { debug = "odin build .", release = "odin build ." },
				run = "odin run .",
				efm = "%f(%l:%c) %t%*[^:]: %m",
			},
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
				--TODO: make work for subdir
				if cwd == expanded then
					vim.print(project)
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

	-- replacements
	--TODO: user config to extend this table
	--TODO: this should also probably happen when the plugin is loaded to avoid repeating every run
	local replacements = {
		["%%file%%"] = vim.fn.expand("%:p"),
		["%%name%%"] = preset.project_name,
		["%%mode%%"] = mode,
	}

	local function replace_in_word(word)
		-- %%%% becomes a single literal %,
		return (
			word:gsub("%%%%([^%%%%]+)%%%%", function(capture)
				local key = "%%" .. capture .. "%%"
				return replacements[key] or word
			end)
		)
	end

	return vim.tbl_map(replace_in_word, vim.split(cmd, "%s+", { trimempty = true }))
end

-- build the current ft
---@param mode? "release" | "debug"
M.build = function(mode, callback)
	local cmd = get_run_cmd(mode, "build")

	if not cmd then
		return false
	end

	local success = true

	local handle_output = function(data)
		if data == nil or (#data == 1 and data[1] == "") then
			return
		end

		--TODO: maybe this has to mode to on_stderr, but we will test with it here for now
		success = false

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
		on_exit = function()
			local qf = vim.fn.getqflist()
			if #qf > 0 then -- qf is populated
				vim.cmd("botright copen")
			else -- qf empty
				vim.cmd("cclose")
			end

			if success then
				if config.settings.notify_build_time then
					local message = string.format("Build completed in %.2fms", (vim.uv.hrtime() - start_time) / 1e6)
					vim.notify(message, "info", { title = "Project-run" })
				end
			else
				vim.notify("Build failed", "error", { title = "Project-run" })
			end

			callback(success)
		end,
	})
end

-- run current ft
---@param mode? "release" | "debug"
---@param build boolean Whether to build first
M.run = function(build, mode)
	mode = mode or "debug"

	local function build_if_success(success)
		if not success then
			return
		end

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

	if build then
		M.build(mode, build_if_success)
	end
end

M.setup = function(user_config)
	user_config = user_config or {}
	config = vim.tbl_deep_extend("force", config, user_config)
end

return M
