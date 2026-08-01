local h = require("tests.harness")
local config = require("codex.config")

h.test("config returns independent defaults", function()
  config._reset()
  local first = config.defaults()
  first.cmd[1] = "changed"
  h.eq("codex", config.defaults().cmd[1])
end)

h.test("config replaces argv lists and merges nested options", function()
  config._reset()
  local value = config.setup({
    cmd = { "my-codex", "--profile", "work" },
    terminal = { auto_insert = false },
  })
  h.eq({ "my-codex", "--profile", "work" }, value.cmd)
  h.eq(false, value.terminal.auto_insert)
  h.eq("right", value.terminal.split_side)
  h.eq("root", value.cwd)
  h.eq("terminal", value.backend)
end)

h.test("config accepts cwd policies and app-server backend", function()
  config._reset()
  local provider = function(ctx)
    return ctx.file_dir
  end
  h.eq("file", config.setup({ cwd = "file" }).cwd)
  h.eq("/tmp/project", config.setup({ cwd = "/tmp/project" }).cwd)
  h.eq(provider, config.setup({ cwd = provider }).cwd)
  h.eq("app_server", config.setup({ backend = "app_server" }).backend)
end)

h.test("config validates cwd and terminal navigation", function()
  config._reset()
  h.raises("cwd", function()
    config.setup({ cwd = 42 })
  end)
  h.raises("backend", function()
    config.setup({ backend = "unknown" })
  end)
  h.raises("terminal.window_navigation.left", function()
    config.setup({ terminal = { window_navigation = { left = "" } } })
  end)
end)

h.test("config treats empty nested tables as maps", function()
  config._reset()
  local value = config.setup({ terminal = {}, context = {} })
  h.eq("right", value.terminal.split_side)
  h.eq(500, value.context.max_lines)
end)

h.test("config validates precise option paths", function()
  config._reset()
  h.raises("terminal.split_side", function()
    ---@diagnostic disable-next-line: assign-type-mismatch
    config.setup({ terminal = { split_side = "top" } })
  end)
  h.raises("context.max_lines", function()
    config.setup({ context = { max_lines = 0 } })
  end)
  h.raises("terminal.typo", function()
    config.setup({ terminal = { typo = true } })
  end)
end)

h.test("config lazily applies global options without eager module loading", function()
  config._reset()
  vim.g.codex_nvim_opts = { focus_after_send = true }
  h.eq(true, config.get().focus_after_send)
  vim.g.codex_nvim_opts = nil
  config._reset()
end)
