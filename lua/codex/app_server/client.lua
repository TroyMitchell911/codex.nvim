local M = {}

local state = {
  jobid = nil,
  next_id = 1,
  pending = {},
  partial = "",
  initialized = false,
  ready = {},
  notification_handler = nil,
  server_request_handler = nil,
  exit_handler = nil,
  last_error = nil,
}

local function notify(message, level)
  vim.notify("codex.nvim app-server: " .. message, level or vim.log.levels.ERROR)
end

---@param message table
---@return boolean
local function write(message)
  if not state.jobid then
    return false
  end
  local payload = vim.json.encode(message) .. "\n"
  local ok, written = pcall(vim.fn.chansend, state.jobid, payload)
  return ok and written > 0
end

---@param id integer|string
---@param result? table
---@param error_data? table
---@return boolean
function M.respond(id, result, error_data)
  local message = { id = id }
  if error_data then
    message.error = error_data
  else
    message.result = result or {}
  end
  return write(message)
end

---@param message table
local function dispatch(message)
  if message.id ~= nil and (message.result ~= nil or message.error ~= nil) then
    local callback = state.pending[message.id]
    state.pending[message.id] = nil
    if callback then
      callback(message.result, message.error)
    end
    return
  end
  if type(message.method) ~= "string" then
    return
  end
  if message.id ~= nil then
    if state.server_request_handler then
      state.server_request_handler(message.method, message.params or {}, message.id)
    else
      M.respond(message.id, nil, { code = -32601, message = "Client method not implemented" })
    end
  elseif state.notification_handler then
    state.notification_handler(message.method, message.params or {})
  end
end

---@param line string
function M._handle_line(line)
  if line == "" then
    return
  end
  local ok, message = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  if not ok or type(message) ~= "table" then
    state.last_error = "invalid JSONL message: " .. tostring(message)
    return
  end
  if vim.in_fast_event() then
    vim.schedule(function()
      dispatch(message)
    end)
  else
    dispatch(message)
  end
end

---@param data string[]?
local function consume(data)
  if not data then
    return
  end
  for index, chunk in ipairs(data) do
    local line = index == 1 and (state.partial .. chunk) or chunk
    if index < #data then
      M._handle_line(line)
    else
      state.partial = line
    end
  end
end

---@return boolean
function M.is_running()
  return state.jobid ~= nil and vim.fn.jobwait({ state.jobid }, 0)[1] == -1
end

---@param method string
---@param params? table
---@param callback? fun(result: table?, error: table?)
---@return boolean
function M.request(method, params, callback)
  if not M.is_running() then
    return false
  end
  local id = state.next_id
  state.next_id = state.next_id + 1
  if callback then
    state.pending[id] = callback
  end
  if not write({ id = id, method = method, params = params or {} }) then
    state.pending[id] = nil
    return false
  end
  return true
end

---@param handler? fun(method: string, params: table)
function M.set_notification_handler(handler)
  state.notification_handler = handler
end

---@param handler? fun(method: string, params: table, id: integer|string)
function M.set_server_request_handler(handler)
  state.server_request_handler = handler
end

---@param opts { cmd: string[], cwd: string, env?: table<string, string>, on_ready?: function, on_exit?: function }
---@return boolean
function M.start(opts)
  state.exit_handler = opts.on_exit
  if M.is_running() then
    if state.initialized and opts.on_ready then
      vim.schedule(opts.on_ready)
    elseif opts.on_ready then
      table.insert(state.ready, opts.on_ready)
    end
    return true
  end

  state.partial = ""
  state.initialized = false
  state.last_error = nil
  if opts.on_ready then
    table.insert(state.ready, opts.on_ready)
  end

  local jobid
  local job_options = {
    cwd = opts.cwd,
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      consume(data)
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data or {}) do
        if line ~= "" then
          state.last_error = line
        end
      end
    end,
    on_exit = function(exited_jobid, code)
      vim.schedule(function()
        if state.jobid ~= exited_jobid then
          return
        end
        state.jobid = nil
        state.initialized = false
        state.ready = {}
        local exit_handler = state.exit_handler
        state.exit_handler = nil
        for id, callback in pairs(state.pending) do
          state.pending[id] = nil
          callback(nil, { code = code, message = state.last_error or "app-server exited" })
        end
        if exit_handler then
          exit_handler(code)
        end
        pcall(vim.api.nvim_exec_autocmds, "User", {
          pattern = "CodexAppServerExited",
          modeline = false,
          data = { exit_code = code },
        })
      end)
    end,
  }
  if opts.env and next(opts.env) ~= nil then
    job_options.env = opts.env
  end
  local ok, result = pcall(vim.fn.jobstart, opts.cmd, job_options)
  if not ok or result <= 0 then
    state.ready = {}
    state.exit_handler = nil
    notify("failed to start: " .. tostring(result))
    return false
  end
  jobid = result
  state.jobid = jobid

  return M.request("initialize", {
    clientInfo = {
      name = "codex_nvim",
      title = "codex.nvim",
      version = require("codex").version,
    },
  }, function(_, err)
    if err then
      notify("initialize failed: " .. tostring(err.message or err.code))
      local exit_handler = state.exit_handler
      M.stop()
      if exit_handler then
        exit_handler(tonumber(err.code) or 1)
      end
      return
    end
    write({ method = "initialized", params = {} })
    state.initialized = true
    local callbacks = state.ready
    state.ready = {}
    for _, callback in ipairs(callbacks) do
      callback()
    end
    pcall(vim.api.nvim_exec_autocmds, "User", {
      pattern = "CodexAppServerReady",
      modeline = false,
      data = {},
    })
  end)
end

---@return boolean
function M.stop()
  if not state.jobid then
    state.exit_handler = nil
    return true
  end
  local stopped = vim.fn.jobstop(state.jobid) == 1
  if stopped then
    state.jobid = nil
    state.initialized = false
    state.pending = {}
    state.ready = {}
    state.partial = ""
    state.exit_handler = nil
    pcall(vim.api.nvim_exec_autocmds, "User", {
      pattern = "CodexAppServerExited",
      modeline = false,
      data = { stopped = true },
    })
  end
  return stopped
end

function M.status()
  return {
    running = M.is_running(),
    initialized = state.initialized,
    jobid = state.jobid,
    last_error = state.last_error,
  }
end

function M._reset()
  if state.jobid then
    pcall(vim.fn.jobstop, state.jobid)
  end
  state.jobid = nil
  state.next_id = 1
  state.pending = {}
  state.partial = ""
  state.initialized = false
  state.ready = {}
  state.notification_handler = nil
  state.server_request_handler = nil
  state.exit_handler = nil
  state.last_error = nil
end

return M
