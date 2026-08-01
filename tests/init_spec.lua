local h = require("tests.harness")
local codex = require("codex")
local config = require("codex.config")

h.test("add_paths sends one composer update and emits normalized context", function()
  local sent
  local original_terminal = package.loaded["codex.terminal"]
  package.loaded["codex.terminal"] = {
    status = function()
      return { cwd = "/tmp", running = true }
    end,
    send = function(text, opts)
      sent = { text = text, opts = opts }
      return true
    end,
  }
  config.setup({ cwd = "nvim" })

  local first = vim.fn.tempname()
  local second = vim.fn.tempname()
  vim.fn.writefile({}, first)
  vim.fn.writefile({}, second)
  local canonical_first = vim.uv.fs_realpath(first)
  local canonical_second = vim.uv.fs_realpath(second)
  local expected_first = require("codex.cwd").relative(canonical_first, "/tmp")
  local expected_second = require("codex.cwd").relative(canonical_second, "/tmp")
  local ok = codex.add_paths({ first, second }, "test")

  package.loaded["codex.terminal"] = original_terminal
  vim.fn.delete(first)
  vim.fn.delete(second)
  h.truthy(ok)
  h.contains(sent.text, "@" .. expected_first)
  h.contains(sent.text, "@" .. expected_second)
  h.eq(false, sent.opts.submit)
end)

h.test("review arguments map to app-server review targets", function()
  h.eq({ type = "uncommittedChanges" }, codex._review_target({}))
  h.eq({ type = "baseBranch", branch = "main" }, codex._review_target({ "--base", "main" }))
  h.eq({ type = "commit", sha = "abc123" }, codex._review_target({ "--commit", "abc123" }))
  h.eq({ type = "custom", instructions = "focus on safety" }, codex._review_target({ "focus", "on", "safety" }))
end)

h.test("terminal review preserves options and combines a multiword prompt", function()
  h.eq({}, codex._terminal_review_args({}))
  h.eq({ "--base", "main" }, codex._terminal_review_args({ "--base", "main" }))
  h.eq({ "focus on safety" }, codex._terminal_review_args({ "focus", "on", "safety" }))
end)
