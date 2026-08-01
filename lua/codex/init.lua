local M = {}

M.version = "0.0.1"

local function config()
  return require("codex.config").get()
end

local function backend()
  if config().backend == "app_server" then
    return require("codex.app_server")
  end
  return require("codex.terminal")
end

local function notify(message, level)
  vim.notify("codex.nvim: " .. message, level or vim.log.levels.INFO)
end

local function working_directory()
  local status = backend().status()
  if status.cwd then
    return status.cwd
  end
  local resolved, err = require("codex.cwd").resolve(0, config().cwd, config().root_markers)
  if not resolved then
    notify(tostring(err), vim.log.levels.ERROR)
  end
  return resolved
end

---@param kind "file"|"range"|"visual"
---@param metadata CodexNvimContextMetadata
local function emit_context(kind, metadata)
  metadata.kind = kind
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = "CodexContextSent",
    modeline = false,
    data = metadata,
  })
end

---@param paths string[]
---@param source string
local function emit_paths(paths, source)
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = "CodexPathsSent",
    modeline = false,
    data = { paths = paths, source = source },
  })
end

---@param prompt string?
---@param metadata CodexNvimContextMetadata|string
---@param kind "file"|"range"|"visual"
---@return boolean
local function send_context(prompt, metadata, kind)
  if not prompt then
    notify(tostring(metadata), vim.log.levels.ERROR)
    return false
  end
  if not backend().send(prompt) then
    return false
  end
  ---@cast metadata CodexNvimContextMetadata
  emit_context(kind, metadata)
  return true
end

---@param args? string[]
---@return boolean
function M.toggle(args)
  if config().backend == "app_server" then
    local toggled = backend().toggle()
    if toggled and args and #args > 0 then
      backend().send(table.concat(args, " "))
    end
    return toggled
  end
  return backend().toggle({ args = args or {} })
end

---@param args? string[]
---@return boolean
function M.open(args)
  if config().backend == "app_server" then
    local opened = backend().open()
    if opened and args and #args > 0 then
      backend().send(table.concat(args, " "))
    end
    return opened
  end
  return backend().open({ args = args or {} })
end

function M.close()
  return backend().hide()
end

function M.focus()
  return backend().focus()
end

function M.stop()
  return backend().stop()
end

---@param subcommand? "resume"|"fork"|"review"
---@param args? string[]
---@param keep_open_on_exit? boolean
---@return boolean
local function open_subcommand(subcommand, args, keep_open_on_exit)
  local terminal = require("codex.terminal")
  if terminal.is_running() then
    notify("stop the active session before starting another Codex command", vim.log.levels.WARN)
    return false
  end
  return terminal.open({
    subcommand = subcommand,
    args = args or {},
    keep_open_on_exit = keep_open_on_exit,
  })
end

---@param thread table
---@return string
local function thread_label(thread)
  local title = thread.name or thread.preview or thread.id
  return title .. (thread.cwd and (" — " .. thread.cwd) or "")
end

---@param action "resume"|"fork"
---@param all? boolean
---@return boolean
local function pick_thread(action, all)
  local app = require("codex.app_server")
  local terminal_backend = config().backend == "terminal"
  return app.list_threads(function(threads, err)
    if err or not threads or #threads == 0 then
      local message = err and (err.message or tostring(err)) or "no Codex threads found"
      notify(message, err and vim.log.levels.ERROR or vim.log.levels.WARN)
      if terminal_backend then
        app.stop()
      end
      return
    end
    vim.ui.select(threads, {
      prompt = action == "resume" and "Resume Codex thread" or "Fork Codex thread",
      format_item = thread_label,
    }, function(choice)
      if not choice then
        if terminal_backend then
          app.stop()
        end
        return
      end
      if terminal_backend then
        app.stop()
        open_subcommand(action, { choice.id })
      elseif action == "resume" then
        app.resume_thread(choice.id)
      else
        app.fork_thread(choice.id)
      end
    end)
  end, all)
end

---@param args? string[]
---@return boolean
function M.resume(args)
  args = args or {}
  if #args == 0 or (#args == 1 and args[1] == "--all") then
    return pick_thread("resume", args[1] == "--all")
  end
  if config().backend == "app_server" then
    return require("codex.app_server").resume_thread(args[1])
  end
  return open_subcommand("resume", args)
end

function M.continue()
  if config().backend == "app_server" then
    local app = require("codex.app_server")
    return app.list_threads(function(threads, err)
      if err or not threads or not threads[1] then
        notify("no recent Codex thread found", vim.log.levels.WARN)
        return
      end
      app.resume_thread(threads[1].id)
    end)
  end
  return open_subcommand("resume", { "--last" })
end

---@param args? string[]
---@return boolean
function M.fork(args)
  args = args or {}
  if #args == 0 or (#args == 1 and args[1] == "--all") then
    return pick_thread("fork", args[1] == "--all")
  end
  if config().backend == "app_server" then
    return require("codex.app_server").fork_thread(args[1])
  end
  return open_subcommand("fork", args)
end

---@param text string
---@param opts? CodexNvimSendOptions
---@return boolean
function M.send(text, opts)
  return backend().send(text, opts)
end

---@param start_line integer
---@param end_line integer
---@param bufnr? integer
---@return boolean
function M.send_range(start_line, end_line, bufnr)
  local cwd = working_directory()
  if not cwd then
    return false
  end
  local prompt, metadata = require("codex.context").range(bufnr or 0, start_line, end_line, cwd, config().context)
  return send_context(prompt, metadata, "range")
end

---@param bufnr? integer
---@return boolean
function M.send_visual(bufnr)
  local cwd = working_directory()
  if not cwd then
    return false
  end
  local prompt, metadata = require("codex.context").visual(bufnr or 0, cwd, config().context)
  return send_context(prompt, metadata, "visual")
end

---@param path? string
---@param bufnr? integer
---@return boolean
function M.add(path, bufnr)
  return M.add_paths({ path or vim.api.nvim_buf_get_name(bufnr or 0) }, "buffer")
end

---@param paths string[]
---@param source? string
---@return boolean
function M.add_paths(paths, source)
  local cwd = working_directory()
  if not cwd then
    return false
  end
  local relative_paths = {}
  for _, path in ipairs(paths) do
    local relative_path, path_or_error = require("codex.context").file(path, 0, cwd)
    if not relative_path then
      notify(path_or_error, vim.log.levels.ERROR)
      return false
    end
    table.insert(relative_paths, relative_path)
  end
  local mentions = {}
  for _, path in ipairs(relative_paths) do
    table.insert(mentions, "@" .. path)
  end
  if not backend().send(table.concat(mentions, " ") .. " ", { submit = false }) then
    return false
  end
  for _, path in ipairs(relative_paths) do
    emit_context("file", { file_path = path })
  end
  emit_paths(relative_paths, source or "command")
  return true
end

---@param first_line? integer
---@param last_line? integer
---@return boolean
function M.add_from_explorer(first_line, last_line)
  local paths, err = require("codex.explorer").get_paths(0, first_line, last_line)
  if not paths then
    notify(tostring(err), vim.log.levels.ERROR)
    return false
  end
  return M.add_paths(paths, vim.bo.filetype)
end

---@param args string[]
---@return table
function M._review_target(args)
  if args[1] == "--base" and args[2] then
    return { type = "baseBranch", branch = args[2] }
  elseif args[1] == "--commit" and args[2] then
    return { type = "commit", sha = args[2] }
  elseif args[1] == "--uncommitted" or #args == 0 then
    return { type = "uncommittedChanges" }
  end
  return { type = "custom", instructions = table.concat(args, " ") }
end

---@param args string[]
---@return string[]
function M._terminal_review_args(args)
  if #args == 0 or vim.startswith(args[1], "-") then
    return vim.deepcopy(args)
  end
  return { table.concat(args, " ") }
end

---@param args? string[]
---@return boolean
function M.review(args)
  args = args or {}
  if config().backend == "app_server" then
    return require("codex.app_server").review(M._review_target(args))
  end
  return open_subcommand("review", M._terminal_review_args(args), true)
end

---@param paths string[]
---@return boolean
function M.image(paths)
  if #paths == 0 then
    notify("provide at least one image path", vim.log.levels.ERROR)
    return false
  end
  if config().backend == "app_server" then
    return require("codex.app_server").send_images(paths)
  end
  local args = {}
  for _, path in ipairs(paths) do
    local absolute = require("codex.cwd").absolute(path)
    local stat = vim.uv.fs_stat(absolute)
    if not stat or stat.type ~= "file" then
      notify("image does not exist: " .. absolute, vim.log.levels.ERROR)
      return false
    end
    table.insert(args, "--image")
    table.insert(args, absolute)
  end
  return open_subcommand(nil, args)
end

function M.show_diff()
  if config().backend ~= "app_server" then
    notify('native diff is available with backend = "app_server"', vim.log.levels.WARN)
    return false
  end
  return require("codex.app_server").show_diff()
end

function M.interrupt()
  if config().backend ~= "app_server" then
    notify('interrupt is available with backend = "app_server"', vim.log.levels.WARN)
    return false
  end
  return require("codex.app_server").interrupt()
end

---@param text? string
---@return boolean
function M.prompt(text)
  if text and text ~= "" then
    return M.send(text)
  end
  vim.ui.input({ prompt = "Codex prompt: " }, function(input)
    if input and input ~= "" then
      M.send(input)
    end
  end)
  return true
end

function M.status()
  return backend().status()
end

---@param opts? CodexNvimSetupOptions
---@return table
function M.setup(opts)
  require("codex.config").setup(opts)
  return M
end

return M
