local Job = require("plenary.job")
local ui = require("flutter-tools.ui")
local utils = require("flutter-tools.utils")
local devices = require("flutter-tools.devices")
local config = require("flutter-tools.config")
local executable = require("flutter-tools.executable")
local dev_log = require("flutter-tools.log")
local dev_tools = require("flutter-tools.dev_tools")
local lsp = require("flutter-tools.lsp")
local dap = require("dap")

local M = {}

---@type table
local current_device = nil

function M.current_device()
  return current_device
end

function M.is_running()
  return dap.session()
end

local function match_error_string(line)
  if not line then
    return false
  end
  -- match the error string if no devices are setup
  if line:match("No supported devices connected") ~= nil then
    -- match the error string returned if multiple devices are matched
    return true, "Choose a device"
  elseif line:match("More than one device connected") ~= nil then
    return true, "Choose a device"
  end
end

---@param line string
---@return boolean, string
local function has_recoverable_error(line)
  local match, msg = match_error_string(line)
  if match then
    return match, msg
  end
  return false, nil
end

---Handle a finished flutter run command
---@param line string
local function look_for_error(line)
  local matched_error, msg = has_recoverable_error(line)
  if matched_error then
    local result = {}
    for subline in line:gmatch("[^\n]+") do
      table.insert(result, subline)
    end
    local lines, win_devices, highlights = devices.extract_device_props(result)
    ui.popup_create({
      title = "Flutter run (" .. msg .. ") ",
      lines = lines,
      highlights = highlights,
      on_create = function(buf, _)
        vim.b.devices = win_devices
        utils.map("n", "<CR>", devices.select_device, { buffer = buf })
      end,
    })
  end
end

---Handle output from flutter run command
---@param is_err boolean if this is stdout or stderr
---@param opts table config options for the dev log window
---@return fun(err: string, data: string, job: Job): nil
local function on_run_data(is_err, opts)
  return vim.schedule_wrap(function(data)
    look_for_error(data)
    if is_err then
      ui.notify({ data })
    end
    if not match_error_string(data) then
      dev_log.log(data, opts)
    end
  end)
end

local function shutdown()
  current_device = nil
  dap.disconnect()
  dap.close()
  dev_tools.on_flutter_shutdown()
end

--- Take arguments from the commandline and pass
--- them to the run command
---@param args string
function M.run_command(args)
  args = args and args ~= "" and vim.split(args, " ") or nil
  M.run({ args = args })
end

---Run the flutter application
---@param opts table
function M.run(opts)
  opts = opts or {}
  local device = opts.device
  local cmd_args = opts.args
  if dap.session() then
    return utils.notify("Flutter is already running!")
  end
  executable.get(function(paths)
    local args = { "run" }
    if not cmd_args and device and device.id then
      current_device = device
      vim.list_extend(args, { "-d", device.id })
    end

    if cmd_args then
      vim.list_extend(args, cmd_args)
    end

    local dev_url = dev_tools.get_url()
    if dev_url then
      vim.list_extend(args, { "--devtools-server-address", dev_url })
    end

    ui.notify({ "Starting flutter project..." })

    vim.list_extend(args, { "--flavor", "staging" })
    local conf = config.get("dev_log")

    dap.listeners.before["event_output"]["flutter-tools"] = function(_, body)
      print("output", vim.inspect(body))
      if body.category == "console" then
        on_run_data(false, conf)(body.output)
      end
      if body.category == "stdout" then
        on_run_data(false, conf)(body.output)
      end
      if body.category == "sterr" then
        on_run_data(true, conf)(body.output)
      end
    end

    dap.listeners.before["event_stopped"]["flutter-tools"] = function(_, body)
      print("stopped", vim.inspect(body))
      shutdown()
    end

    dap.listeners.before["event_initialized"]["flutter-tools"] = function(_, _)
      vim.cmd("doautocmd User FlutterToolsAppStarted")
    end

    dap.listeners.before["event_dart.debuggerUris"]["flutter-tools"] = function(_, body)
      dev_tools.handle_log('http://127.0.0.1:9100?uri=' .. body.observatoryUri)
    end


    dap.run({
      type = "dart",
      request = "launch",
      name = "Launch flutter",
      dartSdkPath = paths.dart_sdk,
      flutterSdkPath = paths.flutter_sdk,
      args = args,
      program = lsp.get_lsp_root_dir() .. "/lib/main.dart",
      cwd = lsp.get_lsp_root_dir(),
    })
  end)
end

---@param cmd string
---@param quiet boolean
---@param on_send function|nil
local function send(cmd, quiet, on_send)
  if dap.session() then
    dap.session():request(cmd)
    if on_send then
      on_send()
    end
  elseif not quiet then
    utils.notify("Sorry! Flutter is not running")
  end
end

---@param quiet boolean
function M.reload(quiet)
  send("hotReload", quiet)
end

---@param quiet boolean
function M.restart(quiet)
  send("hotRestart", quiet, function()
    if not quiet then
      ui.notify({ "Restarting..." }, 1500)
    end
  end)
end

---@param quiet boolean
function M.quit(quiet)
  send("terminate", quiet, function()
    if not quiet then
      ui.notify({ "Closing flutter application..." }, 1500)
      shutdown()
    end
  end)
end

---@param quiet boolean
function M.visual_debug(quiet)
  send("p", quiet)
end

function M.copy_profiler_url()
  if not dap.session() then
    ui.notify({ "You must run the app first!" })
    return
  end

  local url, is_running = dev_tools.get_profiler_url()

  if url then
    vim.cmd("let @+='" .. url .. "'")
    ui.notify({ "Profiler url copied to clipboard!" })
  elseif is_running then
    ui.notify({ "Wait while the app starts", "please try again later" })
  else
    ui.notify({ "You must start the DevTools server first!" })
  end
end

-----------------------------------------------------------------------------//
-- Pub commands
-----------------------------------------------------------------------------//
---Print result of running pub get
---@param result string[]
local function on_pub_get(result, err)
  local timeout = err and 10000 or nil
  ui.notify(result, timeout)
end

---@type Job
local pub_get_job = nil

function M.pub_get()
  if not pub_get_job then
    executable.flutter(function(cmd)
      pub_get_job = Job:new({
        command = cmd,
        args = { "pub", "get" },
        cwd = lsp.get_lsp_root_dir(),
      })
      pub_get_job:after_success(vim.schedule_wrap(function(j)
        on_pub_get(j:result())
        pub_get_job = nil
      end))
      pub_get_job:after_failure(vim.schedule_wrap(function(j)
        on_pub_get(j:stderr_result(), true)
        pub_get_job = nil
      end))
      pub_get_job:start()
    end)
  end
end

---@type Job
local pub_upgrade_job = nil

--- Take arguments from the commandline and pass
--- them to the pub upgrade command
---@param args string
function M.pub_upgrade_command(args)
  args = args and args ~= "" and vim.split(args, " ") or nil
  M.pub_upgrade(args)
end

function M.pub_upgrade(cmd_args)
  if not pub_upgrade_job then
    executable.flutter(function(cmd)
      local notify_timeout = 10000
      local args = { "pub", "upgrade" }
      if cmd_args then
        vim.list_extend(args, cmd_args)
      end
      pub_upgrade_job = Job:new({ command = cmd, args = args, cwd = lsp.get_lsp_root_dir() })
      pub_upgrade_job:after_success(vim.schedule_wrap(function(j)
        ui.notify(j:result(), notify_timeout)
        pub_upgrade_job = nil
      end))
      pub_upgrade_job:after_failure(vim.schedule_wrap(function(j)
        ui.notify(j:stderr_result(), notify_timeout)
        pub_upgrade_job = nil
      end))
      pub_upgrade_job:start()
    end)
  end
end

return M
