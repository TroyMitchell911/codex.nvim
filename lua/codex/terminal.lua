local M = {}

local window = require("codex.window")

---@class (exact) CodexNvimTerminalState
---@field bufnr? integer
---@field winid? integer
---@field jobid? integer
---@field cwd? string
---@field argv? string[]
---@field close_on_exit? boolean
---@field return_winid? integer

---@type CodexNvimTerminalState
local state = {
  bufnr = nil,
  winid = nil,
  jobid = nil,
  cwd = nil,
  argv = nil,
  close_on_exit = nil,
  return_winid = nil,
}

---@return CodexNvimConfig
local function config()
  return require("codex.config").get()
end

local function notify(message, level)
  vim.notify("codex.nvim: " .. message, level or vim.log.levels.INFO)
end

---@param pattern string
---@param data table
local function emit(pattern, data)
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = pattern,
    modeline = false,
    data = data,
  })
end

local function valid_buffer()
  return state.bufnr ~= nil and vim.api.nvim_buf_is_valid(state.bufnr)
end

local function find_window()
  if not valid_buffer() then
    state.winid = nil
    return nil
  end
  if
    state.winid
    and vim.api.nvim_win_is_valid(state.winid)
    and vim.api.nvim_win_get_buf(state.winid) == state.bufnr
  then
    return state.winid
  end
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == state.bufnr then
      state.winid = winid
      return winid
    end
  end
  state.winid = nil
  return nil
end

---@param bufnr integer
---@return integer
local function open_split(bufnr)
  local terminal_config = config().terminal
  local width = math.max(1, math.floor(vim.o.columns * terminal_config.split_width_percentage))
  local modifier = terminal_config.split_side == "left" and "topleft" or "botright"
  local original_win = vim.api.nvim_get_current_win()
  local original_wins = {}
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    original_wins[winid] = true
  end

  local ok, winid_or_error = pcall(function()
    vim.cmd(string.format("%s %dvsplit", modifier, width))
    local winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(winid, bufnr)
    vim.wo[winid].number = false
    vim.wo[winid].relativenumber = false
    vim.wo[winid].signcolumn = "no"
    return winid
  end)
  if not ok then
    for _, winid in ipairs(vim.api.nvim_list_wins()) do
      if not original_wins[winid] then
        pcall(vim.api.nvim_win_close, winid, true)
      end
    end
    if vim.api.nvim_win_is_valid(original_win) then
      pcall(vim.api.nvim_set_current_win, original_win)
    end
    error(winid_or_error, 0)
  end
  return winid_or_error
end

---@param bufnr integer
---@return integer? winid
---@return unknown? error
local function try_open_split(bufnr)
  local ok, winid_or_error = pcall(open_split, bufnr)
  if not ok then
    return nil, winid_or_error
  end
  return winid_or_error
end

---@param winid integer
local function focus_window(winid)
  vim.api.nvim_set_current_win(winid)
  if config().terminal.auto_insert then
    vim.cmd("startinsert")
  end
end

---@param bufnr integer
local function setup_window_navigation(bufnr)
  local navigation = config().terminal.window_navigation
  if navigation == false then
    return
  end
  local directions = {
    left = "h",
    down = "j",
    up = "k",
    right = "l",
  }
  for name, key in pairs(directions) do
    vim.keymap.set("t", navigation[name], "<C-\\><C-n><C-w>" .. key, {
      buf = bufnr,
      desc = "Move to " .. name .. " window",
      silent = true,
    })
  end
end

local function clear_state()
  state.bufnr = nil
  state.winid = nil
  state.jobid = nil
  state.cwd = nil
  state.argv = nil
  state.close_on_exit = nil
  state.return_winid = nil
end

---@param bufnr integer
local function cleanup_failed_start(bufnr)
  window.hide_buffer_windows(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
  clear_state()
end

---@param exited_jobid integer
---@param exit_code integer
local function handle_exit(exited_jobid, exit_code)
  vim.schedule(function()
    if state.jobid ~= exited_jobid then
      return
    end
    local exited_status = M.status()
    exited_status.exit_code = exit_code
    local exited_bufnr = state.bufnr
    local close_on_exit = state.close_on_exit ~= false
    local return_winid = state.return_winid
    local restore_focus = exited_bufnr ~= nil and vim.api.nvim_win_get_buf(0) == exited_bufnr
    clear_state()
    if close_on_exit and config().terminal.auto_close and exited_bufnr and vim.api.nvim_buf_is_valid(exited_bufnr) then
      window.hide_buffer_windows(exited_bufnr)
      pcall(vim.api.nvim_buf_delete, exited_bufnr, { force = true })
      if restore_focus then
        window.restore(return_winid, exited_bufnr)
      end
    end
    emit("CodexExited", exited_status)
  end)
end

---@return boolean
function M.is_running()
  if not state.jobid then
    return false
  end
  return vim.fn.jobwait({ state.jobid }, 0)[1] == -1
end

---@return boolean
function M.is_visible()
  return find_window() ~= nil
end

---@param subcommand? string
---@param args? string[]
---@return string[]
function M._build_argv(subcommand, args)
  local argv = vim.deepcopy(config().cmd)
  if subcommand then
    table.insert(argv, subcommand)
  end
  vim.list_extend(argv, args or {})
  return argv
end

---@param opts? CodexNvimShowOptions
---@return boolean
function M.show(opts)
  opts = opts or {}
  if not valid_buffer() or not M.is_running() then
    return false
  end
  state.return_winid = window.remember(state.return_winid, state.bufnr)
  local winid = find_window()
  local reopened = winid == nil
  if not winid then
    local original_win = vim.api.nvim_get_current_win()
    local split_error
    winid, split_error = try_open_split(state.bufnr)
    if not winid then
      notify("could not open terminal split: " .. tostring(split_error), vim.log.levels.ERROR)
      return false
    end
    state.winid = winid
    if opts.focus == false and vim.api.nvim_win_is_valid(original_win) then
      vim.api.nvim_set_current_win(original_win)
    end
  end
  if opts.focus ~= false then
    focus_window(winid)
  end
  if reopened then
    emit("CodexOpened", M.status())
  end
  return true
end

---@param opts? CodexNvimOpenOptions
---@return boolean
function M.open(opts)
  opts = opts or {}
  if M.is_running() then
    return M.show({ focus = opts.focus })
  end

  if valid_buffer() then
    pcall(vim.api.nvim_buf_delete, state.bufnr, { force = true })
    clear_state()
  end

  local original_win = vim.api.nvim_get_current_win()
  state.return_winid = original_win
  local source_bufnr = vim.api.nvim_win_get_buf(original_win)
  local bufnr = vim.api.nvim_create_buf(false, true)
  state.bufnr = bufnr
  local split_error
  state.winid, split_error = try_open_split(bufnr)
  if not state.winid then
    cleanup_failed_start(bufnr)
    notify("could not open terminal split: " .. tostring(split_error), vim.log.levels.ERROR)
    return false
  end
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.b[bufnr].codex_nvim_terminal = true
  setup_window_navigation(bufnr)

  local argv = opts.argv or M._build_argv(opts.subcommand, opts.args)
  local working_directory, cwd_error
  if opts.cwd then
    working_directory, cwd_error = require("codex.cwd").resolve(source_bufnr, opts.cwd, config().root_markers)
  else
    working_directory, cwd_error = require("codex.cwd").resolve(source_bufnr, config().cwd, config().root_markers)
  end
  if not working_directory then
    cleanup_failed_start(bufnr)
    notify(tostring(cwd_error), vim.log.levels.ERROR)
    return false
  end
  state.cwd = working_directory
  state.argv = vim.deepcopy(argv)
  state.close_on_exit = opts.keep_open_on_exit ~= true

  local jobid
  local job_options = {
    cwd = working_directory,
    term = true,
    on_exit = function(_, exit_code)
      handle_exit(jobid, exit_code)
    end,
  }
  if next(config().env) ~= nil then
    job_options.env = config().env
  end

  local started, job_or_error = pcall(vim.fn.jobstart, argv, job_options)
  if not started or job_or_error <= 0 then
    local detail = tostring(job_or_error)
    cleanup_failed_start(bufnr)
    notify("failed to start Codex: " .. detail, vim.log.levels.ERROR)
    return false
  end
  jobid = job_or_error

  state.jobid = jobid
  if opts.focus == false and vim.api.nvim_win_is_valid(original_win) then
    vim.api.nvim_set_current_win(original_win)
  else
    focus_window(state.winid)
  end
  emit("CodexStarted", M.status())
  return true
end

---@return boolean
function M.hide()
  if not valid_buffer() or not find_window() then
    return true
  end
  local restore_focus = vim.api.nvim_win_get_buf(0) == state.bufnr
  local ok, err = window.hide_buffer_windows(state.bufnr)
  if not ok then
    notify("could not hide terminal: " .. tostring(err), vim.log.levels.ERROR)
    return false
  end
  state.winid = nil
  if restore_focus then
    window.restore(state.return_winid, state.bufnr)
  end
  emit("CodexClosed", M.status())
  return true
end

---@param opts? CodexNvimOpenOptions
---@return boolean
function M.toggle(opts)
  opts = opts or {}
  if M.is_visible() then
    return M.hide()
  end
  if M.is_running() then
    return M.show({ focus = opts.focus })
  end
  return M.open(opts)
end

---@return boolean
function M.focus()
  if not M.is_running() then
    return M.open()
  end
  local winid = find_window()
  if winid and vim.api.nvim_get_current_win() == winid then
    return M.hide()
  end
  return M.show({ focus = true })
end

---@return boolean
function M.stop()
  if not M.is_running() then
    notify("no Codex session is running", vim.log.levels.WARN)
    return false
  end
  return vim.fn.jobstop(state.jobid) == 1
end

---@param text string
---@return string
function M._encode(text)
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("%z", ""):gsub("\27%[201~", "[201~")
  if text:find("\n", 1, true) then
    return "\27[200~" .. text .. "\27[201~"
  end
  return text
end

---@param text string
---@param opts? CodexNvimSendOptions
---@return boolean
function M.send(text, opts)
  opts = opts or {}
  if type(text) ~= "string" or text == "" then
    notify("cannot send empty text", vim.log.levels.WARN)
    return false
  end
  if not M.is_running() then
    notify("start Codex before sending context", vim.log.levels.WARN)
    return false
  end
  local channel = valid_buffer() and vim.b[state.bufnr].terminal_job_id or nil
  if not channel or channel == 0 then
    channel = valid_buffer() and vim.bo[state.bufnr].channel or state.jobid
  end
  local payload = M._encode(text)
  if opts.submit ~= false then
    payload = payload .. "\r"
  end
  local sent, written = pcall(vim.fn.chansend, channel, payload)
  if not sent or written == 0 then
    notify("terminal channel is closed", vim.log.levels.WARN)
    return false
  end
  if config().focus_after_send then
    M.show({ focus = true })
  end
  if opts.on_complete then
    opts.on_complete(true)
  end
  return true
end

---@return CodexNvimStatus
function M.status()
  local winid = find_window()
  return {
    backend = "terminal",
    running = M.is_running(),
    visible = winid ~= nil,
    bufnr = state.bufnr,
    winid = winid,
    jobid = state.jobid,
    cwd = state.cwd,
    argv = state.argv and vim.deepcopy(state.argv) or nil,
  }
end

function M._reset()
  if M.is_running() then
    vim.fn.jobstop(state.jobid)
    vim.fn.jobwait({ state.jobid }, 1000)
  end
  if valid_buffer() then
    pcall(vim.api.nvim_buf_delete, state.bufnr, { force = true })
  end
  clear_state()
end

return M
