local h = require("tests.harness")
local cwd = require("codex.cwd")

local test_root = vim.fn.tempname()
vim.fn.mkdir(test_root .. "/repo/src", "p")
vim.fn.writefile({}, test_root .. "/repo/.git")
vim.fn.writefile({ "return true" }, test_root .. "/repo/src/main.lua")
local buffer = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(buffer, test_root .. "/repo/src/main.lua")
local canonical_root = vim.uv.fs_realpath(test_root)

h.test("cwd resolves root, file, nvim, fixed, and callback policies", function()
  h.eq(canonical_root .. "/repo", cwd.resolve(buffer, "root", { ".git" }))
  h.eq(canonical_root .. "/repo/src", cwd.resolve(buffer, "file", { ".git" }))
  h.eq(vim.uv.fs_realpath(vim.uv.cwd()), cwd.resolve(buffer, "nvim", { ".git" }))
  h.eq(canonical_root .. "/repo/src", cwd.resolve(buffer, test_root .. "/repo/src", { ".git" }))
  h.eq(
    canonical_root .. "/repo/src",
    cwd.resolve(buffer, function(ctx)
      h.eq(canonical_root .. "/repo/src/main.lua", ctx.file)
      h.eq(canonical_root .. "/repo/src", ctx.file_dir)
      return ctx.file_dir
    end, { ".git" })
  )
end)

h.test("root cwd falls back to the opened file directory", function()
  h.eq(canonical_root .. "/repo/src", cwd.resolve(buffer, "root", { "missing-marker" }))
end)

h.test("cwd rejects invalid callback results and missing directories", function()
  local value, err = cwd.resolve(buffer, function()
    return nil
  end, { ".git" })
  h.eq(nil, value)
  h.contains(err, "must return")

  value, err = cwd.resolve(buffer, test_root .. "/missing", { ".git" })
  h.eq(nil, value)
  h.contains(err, "not a directory")
end)

vim.api.nvim_buf_delete(buffer, { force = true })
vim.fn.delete(test_root, "rf")
