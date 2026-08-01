local h = require("tests.harness")
local client = require("codex.app_server.client")

local function with_job_mock(callback)
  local original_jobstart = vim.fn.jobstart
  local original_jobwait = vim.fn.jobwait
  local original_jobstop = vim.fn.jobstop
  local original_chansend = vim.fn.chansend
  local sent = {}
  local job_options
  rawset(vim.fn, "jobstart", function(_, opts)
    job_options = opts
    return 71
  end)
  rawset(vim.fn, "jobwait", function()
    return { -1 }
  end)
  rawset(vim.fn, "jobstop", function()
    return 1
  end)
  rawset(vim.fn, "chansend", function(_, payload)
    table.insert(sent, payload)
    return #payload
  end)

  local ok, err = pcall(callback, sent, function(data)
    job_options.on_stdout(71, data)
  end, function()
    return job_options
  end)

  rawset(vim.fn, "jobstart", original_jobstart)
  rawset(vim.fn, "jobwait", original_jobwait)
  rawset(vim.fn, "jobstop", original_jobstop)
  rawset(vim.fn, "chansend", original_chansend)
  client._reset()
  if not ok then
    error(err, 0)
  end
end

h.test("app-server client initializes over JSONL stdio", function()
  with_job_mock(function(sent, stdout, get_job_options)
    local ready = false
    h.truthy(client.start({
      cmd = { "codex", "app-server" },
      cwd = "/tmp",
      env = { CODEX_NVM_TEST = "1" },
      on_ready = function()
        ready = true
      end,
    }))
    local initialize = vim.json.decode(sent[1])
    h.eq("initialize", initialize.method)
    h.eq("codex_nvim", initialize.params.clientInfo.name)
    h.eq({ CODEX_NVM_TEST = "1" }, get_job_options().env)

    stdout({ vim.json.encode({ id = initialize.id, result = { userAgent = "test" } }), "" })
    h.truthy(ready)
    h.eq("initialized", vim.json.decode(sent[2]).method)
  end)
end)

h.test("app-server client preserves partial JSONL frames and dispatches notifications", function()
  with_job_mock(function(_, stdout)
    local notification
    client.set_notification_handler(function(method, params)
      notification = { method = method, params = params }
    end)
    client.start({ cmd = { "codex", "app-server" }, cwd = "/tmp" })
    stdout({ '{"method":"warning","params":{"message":"par' })
    h.eq(nil, notification)
    stdout({ 'tial"}}', "" })
    h.eq("warning", notification.method)
    h.eq("partial", notification.params.message)
  end)
end)

h.test("app-server client normalizes nullable object fields to nil", function()
  with_job_mock(function(_, stdout)
    local request
    client.set_server_request_handler(function(method, params, id)
      request = { method = method, params = params, id = id }
    end)
    client.start({ cmd = { "codex", "app-server" }, cwd = "/tmp" })
    stdout({
      '{"id":9,"method":"item/commandExecution/requestApproval",'
        .. '"params":{"threadId":"t","turnId":null,"command":null,"cwd":null}}',
      "",
    })
    h.eq("item/commandExecution/requestApproval", request.method)
    h.eq(nil, request.params.turnId)
    h.eq(nil, request.params.command)
    h.eq(nil, request.params.cwd)
  end)
end)

h.test("app-server client drops stale ready callbacks after an unexpected exit", function()
  with_job_mock(function(sent, stdout, get_job_options)
    local ready_count = 0
    local original_notify = vim.notify
    rawset(vim, "notify", function() end)

    client.start({
      cmd = { "codex", "app-server" },
      cwd = "/tmp",
      on_ready = function()
        ready_count = ready_count + 1
      end,
    })
    get_job_options().on_exit(71, 1)
    h.truthy(vim.wait(1000, function()
      return not client.is_running()
    end, 10))

    client.start({
      cmd = { "codex", "app-server" },
      cwd = "/tmp",
      on_ready = function()
        ready_count = ready_count + 1
      end,
    })
    local initialize = vim.json.decode(sent[#sent])
    stdout({ vim.json.encode({ id = initialize.id, result = { userAgent = "test" } }), "" })
    rawset(vim, "notify", original_notify)
    h.eq(1, ready_count)
  end)
end)
