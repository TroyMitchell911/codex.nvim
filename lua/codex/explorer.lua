local M = {}

---@param paths string[]
---@return string[]? normalized
---@return string? error
function M._normalize_paths(paths)
  local normalized = {}
  local seen = {}
  for _, path in ipairs(paths or {}) do
    if type(path) == "string" and path ~= "" then
      local absolute = require("codex.cwd").absolute(path)
      local stat = vim.uv.fs_stat(absolute)
      if stat and (stat.type == "file" or stat.type == "directory" or stat.type == "link") then
        absolute = vim.uv.fs_realpath(absolute) or absolute
        if not seen[absolute] then
          seen[absolute] = true
          table.insert(normalized, absolute)
        end
      end
    end
  end
  if #normalized == 0 then
    return nil, "no existing files or directories are selected"
  end
  return normalized
end

---@param bufnr integer
---@param first_line? integer
---@param last_line? integer
---@return string[]? paths
---@return string? error
local function nvim_tree(_bufnr, _first_line, _last_line)
  local ok, api = pcall(require, "nvim-tree.api")
  if not ok then
    return nil, "nvim-tree is not available"
  end
  local paths = {}
  for _, node in ipairs(api.marks.list() or {}) do
    table.insert(paths, node.absolute_path)
  end
  if #paths == 0 then
    local node = api.tree.get_node_under_cursor()
    if node then
      table.insert(paths, node.absolute_path)
    end
  end
  return paths
end

---@param bufnr integer
---@param first_line? integer
---@param last_line? integer
---@return string[]? paths
---@return string? error
local function neo_tree(_bufnr, first_line, last_line)
  local ok, manager = pcall(require, "neo-tree.sources.manager")
  if not ok then
    return nil, "neo-tree is not available"
  end
  local state = manager.get_state("filesystem")
  if not state or not state.tree then
    return nil, "neo-tree filesystem state is unavailable"
  end
  local nodes = {}
  if first_line and last_line then
    for line = first_line, last_line do
      table.insert(nodes, state.tree:get_node(line))
    end
  elseif state.tree.get_selection then
    nodes = state.tree:get_selection() or {}
  end
  if #nodes == 0 then
    table.insert(nodes, state.tree:get_node())
  end
  local paths = {}
  for _, node in ipairs(nodes) do
    if node and node.path and node.type ~= "message" then
      table.insert(paths, node.path)
    end
  end
  return paths
end

---@param bufnr integer
---@param first_line? integer
---@param last_line? integer
---@return string[]? paths
---@return string? error
local function oil(bufnr, first_line, last_line)
  local ok, oil_api = pcall(require, "oil")
  if not ok then
    return nil, "oil.nvim is not available"
  end
  local current_dir = oil_api.get_current_dir(bufnr)
  if not current_dir then
    return nil, "oil.nvim did not provide a current directory"
  end
  local entries = {}
  if first_line and last_line then
    for line = first_line, last_line do
      table.insert(entries, oil_api.get_entry_on_line(bufnr, line))
    end
  else
    table.insert(entries, oil_api.get_cursor_entry())
  end
  local paths = {}
  for _, entry in ipairs(entries) do
    if entry and entry.name and entry.name ~= "." and entry.name ~= ".." then
      table.insert(paths, vim.fs.joinpath(current_dir, entry.name))
    end
  end
  return paths
end

---@param bufnr integer
---@param first_line? integer
---@param last_line? integer
---@return string[]? paths
---@return string? error
local function mini_files(bufnr, first_line, last_line)
  local ok, mini = pcall(require, "mini.files")
  if not ok then
    return nil, "mini.files is not available"
  end
  local paths = {}
  if first_line and last_line then
    for line = first_line, last_line do
      local entry = mini.get_fs_entry(bufnr, line)
      if entry then
        table.insert(paths, entry.path)
      end
    end
  else
    local entry = mini.get_fs_entry(bufnr)
    if entry then
      table.insert(paths, entry.path)
    end
  end
  return paths
end

---@return string[]? paths
---@return string? error
local function netrw()
  if vim.fn.exists("*netrw#Expose") ~= 1 or vim.fn.exists("*netrw#Call") ~= 1 then
    return nil, "netrw functions are unavailable"
  end
  local marked = vim.fn.call("netrw#Expose", { "netrwmarkfilelist" })
  if type(marked) == "table" and #marked > 0 then
    return marked
  end
  local word = vim.fn.call("netrw#Call", { "NetrwGetWord" })
  if type(word) ~= "string" or word == "" or word == "." or word == ".." or word == "../" then
    return nil, "netrw has no path under the cursor"
  end
  return { vim.fs.joinpath(vim.b.netrw_curdir or vim.uv.cwd(), word) }
end

---@return string[]? paths
---@return string? error
local function snacks()
  local ok, snacks_api = pcall(require, "snacks")
  if not ok then
    return nil, "snacks.nvim is not available"
  end
  local probe_ok, pickers = pcall(function()
    return snacks_api.picker.get({ tab = true })
  end)
  if not probe_ok or type(pickers) ~= "table" or #pickers == 0 then
    return nil, "no active Snacks picker was found"
  end
  local current_win = vim.api.nvim_get_current_win()
  local picker = pickers[#pickers]
  for _, candidate in ipairs(pickers) do
    if candidate.list and candidate.list.win and candidate.list.win.win == current_win then
      picker = candidate
      break
    end
  end
  local selected = picker:selected({ fallback = true }) or {}
  local paths = {}
  for _, item in ipairs(selected) do
    if type(item.file) == "string" then
      table.insert(paths, item.cwd and vim.fs.joinpath(item.cwd, item.file) or item.file)
    end
  end
  return paths
end

local adapters = {
  NvimTree = nvim_tree,
  ["neo-tree"] = neo_tree,
  oil = oil,
  minifiles = mini_files,
  netrw = netrw,
  snacks_picker_list = snacks,
}

---@param bufnr? integer
---@param first_line? integer
---@param last_line? integer
---@return string[]? paths
---@return string? error
function M.get_paths(bufnr, first_line, last_line)
  bufnr = bufnr or 0
  local filetype = vim.bo[bufnr].filetype
  local adapter = adapters[filetype]
  if not adapter then
    return nil, "unsupported explorer buffer: " .. filetype
  end
  local ok, paths, err = pcall(adapter, bufnr, first_line, last_line)
  if not ok then
    return nil, filetype .. " integration failed: " .. tostring(paths)
  end
  if not paths then
    return nil, err
  end
  return M._normalize_paths(paths)
end

return M
