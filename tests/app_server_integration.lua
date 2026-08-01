local client = require("codex.app_server.client")

local done = false
local failure
local count

local started = client.start({
  cmd = { "codex", "app-server" },
  cwd = vim.uv.cwd(),
  on_ready = function()
    client.request("thread/list", { limit = 1 }, function(result, err)
      if err then
        failure = err.message or vim.inspect(err)
      else
        count = #(result.data or {})
      end
      done = true
    end)
  end,
})

if not started or not vim.wait(10000, function()
  return done
end, 10) then
  failure = failure or "timed out waiting for app-server"
end

client.stop()
if failure then
  io.stderr:write("app-server integration failed: " .. failure .. "\n")
  vim.cmd("cquit 1")
else
  io.stdout:write(string.format("app-server integration ok: thread/list returned %d item(s)\n", count))
  vim.cmd("qa!")
end
