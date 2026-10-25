---@mod katana.apply.execute Ejecución de una acción
---
--- Encadena el ciclo de vida de una acción:
---
---   1. `resolve_fn` -> resuelve la acción (`codeAction/resolve`).
---   2. `edit`       -> prepara y aplica el `WorkspaceEdit`.
---   3. `command`    -> ejecuta el comando LSP.
---   4. `execute_fn` -> ejecuta la lógica propia de la acción.
---
--- Devuelve un resultado explícito (`KatanaResult`) con estados `success`,
--- `failed`, `partial`, `cancelled` o `timed_out`.

local notifications = require("katana.apply.notifications")
local pipeline = require("katana.apply.pipeline")
local optional = require("katana.core.optional")
local resolve = require("katana.core.resolve")

local M = {}

local uv = vim.uv or vim.loop

---@param message string
---@param err any|nil
---@return string
local function format_error(message, err)
  if err == nil then
    return message
  end
  return string.format("%s: %s", message, tostring(err))
end

---@param timer any
local function stop_timer(timer)
  if not timer then
    return
  end
  pcall(function()
    timer:stop()
    if not timer:is_closing() then
      timer:close()
    end
  end)
end

--- Ejecuta una acción.
---
--- Para acciones que necesitan `codeAction/resolve` devuelve un `KatanaExecution`
--- (la UI no lo usa) y entrega el resultado final por `opts.on_result`. Para el
--- resto devuelve el `KatanaResult` de forma síncrona.
---@param action KatanaAction|nil
---@param opts KatanaExecutorOptions|nil
---@return KatanaResult|KatanaExecution|nil
function M.execute(action, opts)
  if type(action) ~= "table" then
    return nil
  end

  opts = opts or {}
  opts.bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  opts.win = opts.win or vim.api.nvim_get_current_win()

  if not vim.api.nvim_buf_is_valid(opts.bufnr) then
    opts.bufnr = vim.api.nvim_get_current_buf()
  end

  local started = uv and uv.hrtime() or 0

  ---@type KatanaExecution
  local execution = {
    action = action,
    result = nil,
    finished = false,
    timer = nil,
  }

  ---@param status KatanaResultStatus
  ---@param fields table
  ---@return KatanaResult
  local function finish(status, fields)
    if execution.finished then
      return execution.result
    end

    execution.finished = true
    stop_timer(execution.timer)
    execution.timer = nil

    local duration = 0
    if uv and uv.hrtime and started ~= 0 then
      duration = (uv.hrtime() - started) / 1e6
    end

    ---@type KatanaResult
    local result = {
      status = status,
      action = action,
      title = action.title,
      message = fields.message,
      error = fields.error,
      stage = fields.stage,
      reason = fields.reason,
      rollback = fields.rollback or "not_needed",
      effects = fields.effects or {
        edit = false,
        command = false,
        execute_fn = false,
        buffers = {},
      },
      duration_ms = duration,
    }

    execution.result = result

    if opts.notify ~= false then
      notifications.notify_result(result)
    end

    if type(opts.on_result) == "function" then
      local ok, err = pcall(opts.on_result, result)
      if not ok then
        result.callback_error = tostring(err)
      end
    end

    return result
  end

  execution.cancel = function(reason)
    if execution.finished then
      return
    end
    finish("cancelled", {
      message = reason or "cancelada por el usuario",
      stage = "resolve",
    })
  end

  local action_disabled = optional.value(action.disabled)
  if action_disabled ~= nil then
    local reason = type(action_disabled) == "table" and action_disabled.reason or nil
    finish("failed", {
      message = reason or "action is disabled",
      reason = "disabled",
      stage = "validate",
    })
    return execution.result
  end

  local function invoke(resolved)
    if execution.finished then
      return
    end

    if type(resolved) ~= "table" then
      resolved = action
    end

    local resolved_disabled = optional.value(resolved.disabled)
    if resolved_disabled ~= nil then
      local reason = type(resolved_disabled) == "table" and resolved_disabled.reason or nil
      finish("failed", {
        message = reason or "action is disabled",
        reason = "disabled",
        stage = "validate",
      })
      return
    end

    local status, fields = pipeline.run(resolved, opts)
    finish(status, fields)
  end

  local needs_resolve = type(optional.value(action.resolve_fn)) == "function"
    and optional.value(action.edit) == nil
    and optional.value(action.command) == nil

  if needs_resolve then
    local timeout = opts.timeout or 5000

    if uv and uv.new_timer then
      local timer = uv.new_timer()
      if timer then
        execution.timer = timer
        timer:start(timeout, 0, function()
          vim.schedule(function()
            if execution.finished then
              return
            end
            finish("timed_out", {
              message = string.format("no hubo respuesta en %d ms", timeout),
              reason = tostring(timeout) .. " ms",
              stage = "resolve",
            })
          end)
        end)
      end
    end

    resolve.resolve_single(action, function(resolved_action, resolve_err)
      if execution.finished then
        return
      end

      stop_timer(execution.timer)
      execution.timer = nil

      if resolve_err ~= nil then
        finish("failed", {
          message = format_error("no se pudo resolver la acción", resolve_err),
          error = resolve_err,
          stage = "resolve",
        })
        return
      end

      invoke(resolved_action or action)
    end)

    -- Si `resolve_fn` llamó al callback de forma síncrona, el resultado ya está
    -- listo: se devuelve el `KatanaResult` en lugar de un handle terminado.
    return execution.finished and execution.result or execution
  end

  invoke(action)
  return execution.result
end

--- Ejecuta la acción seleccionada en el picker.
---@return KatanaResult|KatanaExecution|nil
function M.run_current()
  local state = require("katana.state")
  if not state.open then
    return nil
  end

  local item = state.flat[state.index]
  if not item or item.type ~= "action" then
    return nil
  end

  return M.execute(item.action, {
    bufnr = state.origin_buf or vim.api.nvim_get_current_buf(),
    win = state.origin_win or vim.api.nvim_get_current_win(),
  })
end

return M
