local h = require("tests.harness")
local config = require("codex.config")
local terminal = require("codex.terminal")

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

local function with_failed_buffer_attach(callback)
  local original_set_buf = vim.api.nvim_win_set_buf
  local original_notify = vim.notify
  rawset(vim.api, "nvim_win_set_buf", function()
    error("simulated buffer attach failure")
  end)
  rawset(vim, "notify", function() end)

  local ok, result = pcall(callback)

  rawset(vim, "notify", original_notify)
  rawset(vim.api, "nvim_win_set_buf", original_set_buf)
  if not ok then
    error(result, 0)
  end
  return result
end

local function with_failed_winnew(callback)
  local original_notify = vim.notify
  local group = vim.api.nvim_create_augroup("codex_nvim_test_failed_winnew", { clear = true })
  vim.api.nvim_create_autocmd("WinNew", {
    group = group,
    once = true,
    callback = function()
      error("simulated WinNew failure")
    end,
  })
  rawset(vim, "notify", function() end)

  local ok, result = pcall(callback)

  rawset(vim, "notify", original_notify)
  pcall(vim.api.nvim_del_augroup_by_id, group)
  if not ok then
    error(result, 0)
  end
  return result
end

h.test("terminal builds argv without shell interpolation", function()
  config.setup({ cmd = { "codex", "--profile", "work" } })
  h.eq({ "codex", "--profile", "work", "resume", "--last" }, terminal._build_argv("resume", { "--last" }))
end)

h.test("terminal wraps multiline input as bracketed paste", function()
  h.eq("hello", terminal._encode("hello"))
  h.eq("\27[200~one\ntwo\27[201~", terminal._encode("one\ntwo"))
end)

h.test("failed terminal start cleans up its split and state", function()
  terminal._reset()
  config.setup({
    cmd = { "/definitely/not/a/codex/binary" },
    terminal = { auto_insert = false },
  })
  local windows_before = #vim.api.nvim_list_wins()
  local original_notify = vim.notify
  rawset(vim, "notify", function() end)
  local ok, result = pcall(terminal.open, { focus = false })
  rawset(vim, "notify", original_notify)
  h.eq(true, ok)
  h.eq(false, result)
  h.eq(windows_before, #vim.api.nvim_list_wins())
  h.eq(false, terminal.status().running)
  h.eq(false, terminal.status().visible)
end)

h.test("failed initial split does not leak buffer state", function()
  terminal._reset()
  config.setup({
    cmd = { "sh" },
    terminal = { auto_insert = false },
  })

  h.eq(
    false,
    with_failed_split(function()
      return terminal.open({ focus = false })
    end)
  )
  h.eq(nil, terminal.status().bufnr)
  h.eq(false, terminal.is_running())
end)

h.test("partially created split is rolled back", function()
  terminal._reset()
  config.setup({
    cmd = { "sh" },
    terminal = { auto_insert = false },
  })
  local original_win = vim.api.nvim_get_current_win()
  local windows_before = #vim.api.nvim_list_wins()

  h.eq(
    false,
    with_failed_buffer_attach(function()
      return terminal.open({ focus = false })
    end)
  )
  h.eq(windows_before, #vim.api.nvim_list_wins())
  h.eq(original_win, vim.api.nvim_get_current_win())
  h.eq(nil, terminal.status().bufnr)
  h.eq(false, terminal.is_running())
end)

h.test("split created before a WinNew error is rolled back", function()
  terminal._reset()
  config.setup({
    cmd = { "sh" },
    terminal = { auto_insert = false },
  })
  local original_win = vim.api.nvim_get_current_win()
  local windows_before = #vim.api.nvim_list_wins()

  h.eq(
    false,
    with_failed_winnew(function()
      return terminal.open({ focus = false })
    end)
  )
  h.eq(windows_before, #vim.api.nvim_list_wins())
  h.eq(original_win, vim.api.nvim_get_current_win())
  h.eq(nil, terminal.status().bufnr)
  h.eq(false, terminal.is_running())
end)

h.test("failed split restore preserves a hidden session", function()
  terminal._reset()
  config.setup({
    cmd = { "sh" },
    terminal = { auto_insert = false, auto_close = true },
  })
  h.truthy(terminal.open({ focus = false }))
  local bufnr = terminal.status().bufnr
  h.truthy(terminal.hide())

  h.eq(
    false,
    with_failed_split(function()
      return terminal.show({ focus = false })
    end)
  )
  h.eq(bufnr, terminal.status().bufnr)
  h.truthy(terminal.is_running())
  h.eq(false, terminal.is_visible())

  h.truthy(terminal.show({ focus = false }))
  h.truthy(terminal.send("exit"))
  h.truthy(vim.wait(1000, function()
    return not terminal.is_running()
  end, 10))
  terminal._reset()
end)

h.test("native terminal survives hiding and can be shown again", function()
  terminal._reset()
  config.setup({
    cmd = { "sh" },
    terminal = { auto_insert = false, auto_close = true },
  })
  h.truthy(terminal.open({ focus = false }))
  h.truthy(terminal.is_running())
  h.truthy(terminal.is_visible())
  h.truthy(terminal.hide())
  h.eq(false, terminal.is_visible())
  h.truthy(terminal.show({ focus = false }))
  h.truthy(terminal.is_visible())
  h.truthy(terminal.send("exit"))
  h.truthy(vim.wait(1000, function()
    return not terminal.is_running()
  end, 10))
  terminal._reset()
end)

h.test("focus is a smart focus and hide toggle", function()
  terminal._reset()
  config.setup({
    cmd = { "sh" },
    terminal = { auto_insert = false, auto_close = true },
  })
  local editor_win = vim.api.nvim_get_current_win()
  h.truthy(terminal.open({ focus = false }))
  local terminal_win = terminal.status().winid
  h.eq(editor_win, vim.api.nvim_get_current_win())

  h.truthy(terminal.focus())
  h.eq(terminal_win, vim.api.nvim_get_current_win())
  h.truthy(terminal.focus())
  h.eq(false, terminal.is_visible())
  h.eq(editor_win, vim.api.nvim_get_current_win())
  h.truthy(terminal.focus())
  h.truthy(terminal.is_visible())

  h.truthy(terminal.send("exit"))
  h.truthy(vim.wait(1000, function()
    return not terminal.is_running()
  end, 10))
  terminal._reset()
end)

h.test("hiding the terminal restores the most recent editor window", function()
  terminal._reset()
  config.setup({
    cmd = { "sh" },
    terminal = { auto_insert = false, auto_close = true },
  })
  local original_win = vim.api.nvim_get_current_win()
  vim.cmd("vsplit")
  local recent_editor_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(original_win)

  h.truthy(terminal.open({ focus = false }))
  vim.api.nvim_set_current_win(recent_editor_win)
  h.truthy(terminal.show({ focus = true }))
  h.truthy(terminal.hide())
  h.eq(recent_editor_win, vim.api.nvim_get_current_win())

  h.truthy(terminal.show({ focus = false }))
  h.truthy(terminal.send("exit"))
  h.truthy(vim.wait(1000, function()
    return not terminal.is_running()
  end, 10))
  terminal._reset()
  if vim.api.nvim_win_is_valid(recent_editor_win) then
    vim.api.nvim_win_close(recent_editor_win, true)
  end
end)

h.test("terminal exit restores an editor window from another tab", function()
  terminal._reset()
  config.setup({
    cmd = { "sh" },
    terminal = { auto_insert = false, auto_close = true },
  })
  local original_tab = vim.api.nvim_get_current_tabpage()
  h.truthy(terminal.open({ focus = false }))
  vim.cmd("tabnew")
  local editor_tab = vim.api.nvim_get_current_tabpage()
  local editor_win = vim.api.nvim_get_current_win()

  h.truthy(terminal.show({ focus = true }))
  h.truthy(terminal.send("exit"))
  h.truthy(vim.wait(1000, function()
    return not terminal.is_running()
      and vim.api.nvim_get_current_tabpage() == editor_tab
      and vim.api.nvim_get_current_win() == editor_win
  end, 10))
  h.eq(editor_tab, vim.api.nvim_get_current_tabpage())
  h.eq(editor_win, vim.api.nvim_get_current_win())

  vim.cmd("tabclose")
  h.eq(original_tab, vim.api.nvim_get_current_tabpage())
  terminal._reset()
end)

h.test("focus starts a session when none is running", function()
  terminal._reset()
  config.setup({
    cmd = { "sh" },
    terminal = { auto_insert = false, auto_close = true },
  })

  h.truthy(terminal.focus())
  h.truthy(terminal.is_running())
  h.truthy(terminal.is_visible())
  h.eq(terminal.status().winid, vim.api.nvim_get_current_win())

  h.truthy(terminal.send("exit"))
  h.truthy(vim.wait(1000, function()
    return not terminal.is_running()
  end, 10))
  terminal._reset()
end)

h.test("terminal installs configurable buffer-local window navigation", function()
  terminal._reset()
  config.setup({
    cmd = { "sh" },
    terminal = {
      auto_insert = false,
      auto_close = true,
      window_navigation = { left = "<F6>" },
    },
  })
  h.truthy(terminal.open({ focus = false }))
  local bufnr = terminal.status().bufnr
  local mappings = vim.api.nvim_buf_get_keymap(bufnr, "t")
  local found = false
  for _, mapping in ipairs(mappings) do
    if mapping.lhs == "<F6>" and mapping.desc == "Move to left window" then
      found = true
      break
    end
  end
  h.truthy(found)

  h.truthy(terminal.send("exit"))
  h.truthy(vim.wait(1000, function()
    return not terminal.is_running()
  end, 10))
  terminal._reset()
end)

h.test("terminal lifecycle events distinguish focus from reopening", function()
  terminal._reset()
  config.setup({ cmd = { "sh" }, terminal = { auto_insert = false, auto_close = true } })
  local opened = 0
  local closed = 0
  local group = vim.api.nvim_create_augroup("codex_nvim_test_lifecycle", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodexOpened",
    callback = function()
      opened = opened + 1
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodexClosed",
    callback = function()
      closed = closed + 1
    end,
  })

  h.truthy(terminal.open({ focus = false }))
  h.truthy(terminal.show({ focus = true }))
  h.eq(0, opened)
  h.truthy(terminal.hide())
  h.eq(1, closed)
  h.truthy(terminal.show({ focus = false }))
  h.eq(1, opened)

  vim.api.nvim_del_augroup_by_id(group)
  h.truthy(terminal.send("exit"))
  h.truthy(vim.wait(1000, function()
    return not terminal.is_running()
  end, 10))
  terminal._reset()
end)

h.test("terminal hides every view and survives as the last window", function()
  terminal._reset()
  config.setup({
    cmd = { "sh" },
    terminal = { auto_insert = false, auto_close = true },
  })
  local editor_win = vim.api.nvim_get_current_win()
  h.truthy(terminal.open({ focus = false }))
  local status = terminal.status()

  vim.cmd("vsplit")
  vim.api.nvim_win_set_buf(0, status.bufnr)
  h.eq(2, #vim.fn.win_findbuf(status.bufnr))
  h.truthy(terminal.hide())
  h.eq(0, #vim.fn.win_findbuf(status.bufnr))
  h.truthy(terminal.is_running())

  h.truthy(terminal.show({ focus = false }))
  vim.api.nvim_win_close(editor_win, true)
  h.eq(1, #vim.api.nvim_list_wins())
  h.truthy(terminal.hide())
  h.eq(1, #vim.api.nvim_list_wins())
  h.eq(0, #vim.fn.win_findbuf(status.bufnr))
  h.truthy(terminal.is_running())

  h.truthy(terminal.show({ focus = false }))
  h.truthy(terminal.send("exit"))
  h.truthy(vim.wait(1000, function()
    return not terminal.is_running()
  end, 10))
  terminal._reset()
end)
