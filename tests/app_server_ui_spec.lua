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

h.test("app-server UI restores the most recent editor window", function()
  ui.reset()
  config.setup({ terminal = { auto_insert = false } })
  local original_win = vim.api.nvim_get_current_win()
  vim.cmd("vsplit")
  local recent_editor_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(original_win)

  h.truthy(ui.open(false))
  vim.api.nvim_set_current_win(recent_editor_win)
  h.truthy(ui.open(true))
  h.truthy(ui.hide())
  h.eq(recent_editor_win, vim.api.nvim_get_current_win())

  ui.reset()
  if vim.api.nvim_win_is_valid(recent_editor_win) then
    vim.api.nvim_win_close(recent_editor_win, true)
  end
end)

h.test("app-server UI does not treat its diff as an editor return window", function()
  ui.reset()
  config.setup({ terminal = { auto_insert = false } })
  local older_editor_win = vim.api.nvim_get_current_win()

  h.truthy(ui.open(false))
  vim.cmd("vsplit")
  local recent_editor_win = vim.api.nvim_get_current_win()
  h.truthy(ui.show_diff("diff --git a/a.lua b/a.lua\n+new"))
  h.truthy(ui.open(true))
  h.truthy(ui.hide())
  h.eq(recent_editor_win, vim.api.nvim_get_current_win())

  ui.reset()
  if vim.api.nvim_win_is_valid(recent_editor_win) then
    vim.api.nvim_win_close(recent_editor_win, true)
  end
  h.eq(older_editor_win, vim.api.nvim_get_current_win())
end)

h.test("app-server UI hides transcript views across tabs", function()
  ui.reset()
  config.setup({ terminal = { auto_insert = false } })
  local original_tab = vim.api.nvim_get_current_tabpage()
  local editor_win = vim.api.nvim_get_current_win()
  h.truthy(ui.open(false))
  local bufnr = ui.status().bufnr
  h.truthy(bufnr)
  ---@cast bufnr integer

  vim.cmd("tabnew")
  local extra_tab = vim.api.nvim_get_current_tabpage()
  vim.api.nvim_win_set_buf(0, bufnr)
  h.eq(2, #vim.fn.win_findbuf(bufnr))
  h.truthy(ui.hide())
  h.eq(0, #vim.fn.win_findbuf(bufnr))
  h.eq(editor_win, vim.api.nvim_get_current_win())

  vim.api.nvim_set_current_tabpage(extra_tab)
  vim.cmd("tabclose")
  h.eq(original_tab, vim.api.nvim_get_current_tabpage())
  ui.reset()
end)
