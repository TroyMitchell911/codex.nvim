local h = require("tests.harness")
local explorer = require("codex.explorer")

local test_root = vim.fn.tempname()
vim.fn.mkdir(test_root .. "/dir", "p")
vim.fn.writefile({ "one" }, test_root .. "/one.lua")
vim.fn.writefile({ "two" }, test_root .. "/two.lua")

local function with_buffer(filetype, callback)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].filetype = filetype
  local ok, result, err = pcall(callback, bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  if not ok then
    error(result, 0)
  end
  return result, err
end

h.test("explorer normalizes existing paths and removes duplicates", function()
  local paths, err = explorer._normalize_paths({
    test_root .. "/one.lua",
    test_root .. "/one.lua",
    test_root .. "/dir",
    test_root .. "/missing",
  })
  h.eq(nil, err)
  h.eq({ vim.uv.fs_realpath(test_root .. "/one.lua"), vim.uv.fs_realpath(test_root .. "/dir") }, paths)
end)

h.test("explorer reads marked nvim-tree paths", function()
  package.loaded["nvim-tree.api"] = {
    marks = {
      list = function()
        return {
          { absolute_path = test_root .. "/one.lua" },
          { absolute_path = test_root .. "/dir", type = "directory" },
        }
      end,
    },
    tree = { get_node_under_cursor = function() end },
  }
  local paths, err = with_buffer("NvimTree", function(bufnr)
    return explorer.get_paths(bufnr)
  end)
  package.loaded["nvim-tree.api"] = nil
  h.eq(nil, err)
  h.eq(2, #paths)
end)

h.test("explorer reads an oil visual range", function()
  package.loaded.oil = {
    get_current_dir = function()
      return test_root .. "/"
    end,
    get_entry_on_line = function(_, line)
      return line == 2 and { name = "one.lua", type = "file" } or { name = "dir", type = "directory" }
    end,
  }
  local paths, err = with_buffer("oil", function(bufnr)
    return explorer.get_paths(bufnr, 2, 3)
  end)
  package.loaded.oil = nil
  h.eq(nil, err)
  h.eq({ vim.uv.fs_realpath(test_root .. "/one.lua"), vim.uv.fs_realpath(test_root .. "/dir") }, paths)
end)

h.test("explorer rejects unsupported buffers", function()
  local paths, err = with_buffer("lua", function(bufnr)
    return explorer.get_paths(bufnr)
  end)
  h.eq(nil, paths)
  h.contains(err, "unsupported")
end)

vim.fn.delete(test_root, "rf")
