local h = require("tests.harness")

h.test("app-server backend starts a thread, sends a turn, and streams UI updates", function()
  local requests = {}
  local notification_handler
  local server_request_handler
  local client_exit_handler
  local turn_callback
  local review_callback
  local appended = {}
  local diff
  local cwd_calls = 0
  local ui_open_ok = true
  local sequence = {}
  local responses = {}
  local fake_client = {
    start = function(opts)
      client_exit_handler = opts.on_exit
      opts.on_ready()
      return true
    end,
    request = function(method, params, callback)
      table.insert(requests, { method = method, params = params })
      if method == "thread/start" then
        callback({ thread = { id = "thread-1" }, cwd = params.cwd })
      elseif method == "turn/start" then
        turn_callback = callback
      elseif method == "review/start" then
        review_callback = callback
      end
      return true
    end,
    set_notification_handler = function(handler)
      notification_handler = handler
    end,
    set_server_request_handler = function(handler)
      server_request_handler = handler
    end,
    is_running = function()
      return true
    end,
    status = function()
      return { running = true, initialized = true, jobid = 71 }
    end,
    stop = function()
      return true
    end,
    respond = function(id, result, err)
      table.insert(responses, { id = id, result = result, error = err })
    end,
  }
  local fake_ui = {
    open = function()
      table.insert(sequence, "ui")
      return ui_open_ok
    end,
    hide = function() end,
    focus = function() end,
    toggle = function() end,
    append = function(text)
      table.insert(appended, text)
    end,
    show_diff = function(value)
      diff = value
      return true
    end,
    status = function()
      return { visible = true, bufnr = 8, winid = 9 }
    end,
    reset = function() end,
  }
  local original_client = package.loaded["codex.app_server.client"]
  local original_ui = package.loaded["codex.app_server.ui"]
  package.loaded["codex.app_server.client"] = fake_client
  package.loaded["codex.app_server.ui"] = fake_ui
  package.loaded["codex.app_server"] = nil

  require("codex.config").setup({
    backend = "app_server",
    cwd = function()
      cwd_calls = cwd_calls + 1
      table.insert(sequence, "cwd")
      return vim.uv.cwd()
    end,
  })
  local app = require("codex.app_server")
  h.truthy(app.open())
  h.eq({ "cwd", "ui" }, sequence)
  h.eq("thread/start", requests[1].method)
  h.truthy(app.send("hello"))
  h.eq("turn/start", requests[2].method)
  h.eq("hello", requests[2].params.input[1].text)
  h.truthy(app.send("follow up"))
  h.eq(2, #requests)
  turn_callback({ turn = { id = "turn-1" } })
  h.eq("turn/steer", requests[3].method)
  h.eq("follow up", requests[3].params.input[1].text)
  h.eq(1, cwd_calls)
  h.eq(vim.uv.cwd(), requests[2].params.cwd)

  notification_handler("item/agentMessage/delta", { delta = "answer" })
  notification_handler("turn/diff/updated", { diff = "diff --git a/a b/a" })
  h.eq("answer", appended[#appended])
  h.truthy(app.show_diff())
  h.contains(diff, "diff --git")
  h.truthy(server_request_handler)

  local original_select = vim.ui.select
  rawset(vim.ui, "select", function(items, _, callback)
    callback(items[1])
  end)
  diff = nil
  notification_handler("item/started", {
    threadId = "thread-1",
    turnId = "turn-1",
    item = {
      id = "file-item",
      type = "fileChange",
      changes = { { path = "a.lua", kind = "update", diff = "diff --git a/a.lua b/a.lua\n+new" } },
    },
  })
  server_request_handler("item/fileChange/requestApproval", {
    threadId = "thread-1",
    turnId = "turn-1",
    itemId = "file-item",
  }, 90)
  h.contains(diff, "diff --git a/a.lua")
  h.eq(false, diff:find("diff --git a/a b/a", 1, true) ~= nil)

  server_request_handler("item/commandExecution/requestApproval", {
    threadId = "thread-1",
    turnId = "turn-1",
    itemId = "item-1",
    command = "make test",
    cwd = vim.uv.cwd(),
    availableDecisions = {
      { acceptWithExecpolicyAmendment = { execpolicy_amendment = { "make", "test" } } },
      "decline",
    },
  }, 91)
  rawset(vim.ui, "select", original_select)
  h.eq(91, responses[#responses].id)
  h.eq({ "make", "test" }, responses[#responses].result.decision.acceptWithExecpolicyAmendment.execpolicy_amendment)

  local appended_before = #appended
  notification_handler("item/agentMessage/delta", {
    threadId = "another-thread",
    turnId = "another-turn",
    delta = "stale",
  })
  h.eq(appended_before, #appended)
  local original_notify = vim.notify
  rawset(vim, "notify", function() end)
  h.eq(false, app.resume_thread("another-thread"))
  rawset(vim, "notify", original_notify)

  notification_handler("turn/completed", {
    threadId = "thread-1",
    turn = { id = "turn-1", status = "completed" },
  })
  h.truthy(app.review({ type = "uncommittedChanges" }))
  local review_requests = #requests
  original_notify = vim.notify
  rawset(vim, "notify", function() end)
  h.eq(false, app.send("review focus"))
  rawset(vim, "notify", original_notify)
  h.eq(review_requests, #requests)
  h.truthy(review_callback)
  review_callback({ turn = { id = "review-turn" } })
  original_notify = vim.notify
  rawset(vim, "notify", function() end)
  h.eq(false, app.send("still reviewing"))
  rawset(vim, "notify", original_notify)
  h.eq(review_requests, #requests)

  notification_handler("turn/completed", {
    threadId = "thread-1",
    turn = { id = "review-turn", status = "completed" },
  })
  ui_open_ok = false
  local requests_before = #requests
  original_notify = vim.notify
  rawset(vim, "notify", function() end)
  h.truthy(app.send("must not be sent without a panel"))
  rawset(vim, "notify", original_notify)
  h.eq(requests_before, #requests)

  client_exit_handler(1)
  h.eq(false, app.status().active)
  h.eq(nil, app.status().thread_id)
  h.eq(nil, app.status().cwd)

  app._reset()
  package.loaded["codex.app_server"] = nil
  package.loaded["codex.app_server.client"] = original_client
  package.loaded["codex.app_server.ui"] = original_ui
end)
