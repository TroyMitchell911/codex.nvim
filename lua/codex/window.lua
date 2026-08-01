local M = {}

local function is_owned_window(winid, ...)
  local bufnr = vim.api.nvim_win_get_buf(winid)
  for index = 1, select("#", ...) do
    local owned_bufnr = select(index, ...)
    if owned_bufnr and vim.api.nvim_buf_is_valid(owned_bufnr) and bufnr == owned_bufnr then
      return true
    end
  end
  return false
end

---@param previous_winid integer?
---@param ... integer?
---@return integer?
function M.remember(previous_winid, ...)
  local winid = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_is_valid(winid) and not is_owned_window(winid, ...) then
    return winid
  end
  return previous_winid
end

---@param return_winid integer?
---@param ... integer?
---@return boolean
function M.restore(return_winid, ...)
  if not return_winid or not vim.api.nvim_win_is_valid(return_winid) or is_owned_window(return_winid, ...) then
    return false
  end
  return pcall(vim.api.nvim_set_current_win, return_winid)
end

---@param bufnr integer
---@return boolean ok
---@return unknown? error
function M.hide_buffer_windows(bufnr)
  local replacement
  for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(winid) then
      local tabpage = vim.api.nvim_win_get_tabpage(winid)
      local ok, err
      if #vim.api.nvim_tabpage_list_wins(tabpage) == 1 then
        replacement = replacement or vim.api.nvim_create_buf(false, true)
        ok, err = pcall(vim.api.nvim_win_set_buf, winid, replacement)
      else
        ok, err = pcall(vim.api.nvim_win_close, winid, false)
      end
      if not ok then
        return false, err
      end
    end
  end
  return true
end

return M
