local h = require("tests.harness")
local config = require("codex.config")
local ui = require("codex.app_server.ui")

local function with_failed_split(callback)
  local original_cmd = vim.cmd
  local original_notify = vim.notify
  rawset(vim, "cmd", function(command)
    if type(command) == "string" and command:find("vsplit", 1, true) then
      error("simulated split failure")
    end
    return original_cmd(command)
  end)
  rawset(vim, "notify", function() end)
  local ok, result = pcall(callback)
  rawset(vim, "notify", original_notify)
  rawset(vim, "cmd", original_cmd)
  if not ok then
    error(result, 0)
  end
  return result
end

h.test("app-server UI rolls back an initial split failure", function()
  ui.reset()
  config.setup({ terminal = { auto_insert = false } })
  local windows_before = #vim.api.nvim_list_wins()
  h.eq(
    false,
    with_failed_split(function()
      return ui.open(true)
    end)
  )
  h.eq(windows_before, #vim.api.nvim_list_wins())
  h.eq(nil, ui.status().bufnr)
  h.eq(false, ui.status().visible)
end)

h.test("app-server UI cleans up a failed diff split", function()
  ui.reset()
  h.eq(
    false,
    with_failed_split(function()
      return ui.show_diff("diff --git a/a b/a")
    end)
  )
  ui.reset()
end)
