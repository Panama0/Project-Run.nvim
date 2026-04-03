# Project-Run.nvim
Plugin for managing project and filetype specific commands for running, building, debugging and testing.

## Features
- Manage common tasks on a per-project or filetype level
- Build projects and see errors/warnings in the native quickfix window
- Run projects in a persistent terminal session
- Debugging support via DAP
- Project configuration can be loaded dynamically from a file (user is prompted to trust file via `vim.secure.read()`)
- Project and filetype presets can inherit
- Single file, 300 line plugin

## API

`mode = "debug" | "release"` - Mode to build/run in. Default = `"debug"`

`build` - Whether to build before action. Default = `true`

| Function | Description |
|----------|-------------|
| `setup(opts?)` | Initialize plugin with optional user config |
| `build(mode?, callback?)` | Build project |
| `launch(mode?, build?)` | Run project |
| `launch_DAP(build?)` | Run with DAP debugger |
| `test(build?)` | Run tests |
| `list_current_preset()` | Debug: print current active preset |

## Configuration

### Presets
Commands can be a string or a table like so:
```lua
{ debug = string, release = string }
```
Preset config:
```lua
{
  paths? = string[],          -- Project paths (projects only)
  build? = Cmds | string,     -- Build command(s)
  run_target? = Cmds | string,-- Executable path
  dap_handler? = string,     -- DAP adapter (e.g., "codelldb", "python")
  test? = string,             -- Test command
  efm? = string,              -- Errorformat for quickfix
  base_ft? = string,          -- Inherit from another filetype
}
```

The preset table is structured as follows:
```lua
presets = {
  filetypes = {
  -- ft presets here
  },
  projects = {
  -- project presets here
  }
},
```

### Default config
```lua
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
		notify_build_time = true, -- Whether to emit a message showing the build time after each build
	},
}

```

## Installation
Lazy.nvim
```lua
{
  'Panama0/project-run.nvim'
  dependencies = { 'Panama0/Terman.nvim', 'mfussenegger/nvim-dap' },
  opts = {}
}
```
