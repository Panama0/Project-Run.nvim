local M = {}

---@class project-run.Cmds
---@field debug string Command for debug builds
---@field release string Command for release builds

---@class project-run.Preset
---@field ft string Filetype to activate on
---@field build project-run.Cmds | string
---@field run project-run.Cmds | string
---@field efm? string Custom errorformat to apply to qf
---@field project_name? string Project name - used for replacements

---@class project-run.Settings
---@field show_output "build" | "run" | "all" | "on_error" When to show output
---@field notify_build_time boolean Whether to send a notification containing the build time

---@class project-run.Config
---@field presets table<string, project-run.Preset>
---@field settings project-run.Settings
local config = {
	presets = {
		odin = {
			ft = "odin",
			build = { debug = "odin build .", release = "odin build ." },
			run = "odin run .",
			efm = "%f(%l:%c) %t%*[^:]: %m",
		},
		cpp = {
			ft = "cpp",
			build = "g++ %%file%% -o %%name%%",
			run = "./%%name%%",
			project_name = "mainnnn",
		},
	},
	settings = {
		show_output = "build",
		notify_build_time = true,
	},
}

-- Get the cmd for the current file type and selected mode
---@param mode? "debug" | "release"
---@param action? "build" | "run"
local get_ft_cmd = function(mode, action)
	mode = mode or "debug"
	action = action or "build"

	local ft = vim.bo.ft
	if not ft then
		return false
	end

	local cmd

	local preset = config.presets[ft]

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
		-- gsub replaces all occurrences within the word, not just whole-word matches
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
	local cmd = get_ft_cmd(mode, "build")

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
		if config.presets[vim.bo.ft] then
			efm = config.presets[vim.bo.ft].efm
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
				local message = string.format("Build completed in %.2fms", (vim.uv.hrtime() - start_time) / 1e6)
				vim.notify(message, "info", { title = "Project-run" })
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

		local cmd = get_ft_cmd(mode, "run")
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

M.setup = function() end

return M
