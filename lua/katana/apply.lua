---@mod katana.apply Ejecución de acciones
---
--- El executor es el único módulo que muta buffers. Encadena los pasos del ciclo
--- de vida de una acción:
---
---   1. `resolve_fn` -> resuelve la acción (`codeAction/resolve`).
---   2. `edit`       -> prepara y aplica el `WorkspaceEdit`.
---   3. `command`    -> ejecuta el comando LSP.
---   4. `execute_fn` -> ejecuta la lógica propia de la acción.
---
--- Devuelve un resultado explícito (`KatanaResult`) con estados:
---
---   * `success`   - todo lo que había que hacer se hizo.
---   * `failed`    - no se produjo ningún efecto persistente (o se revirtió).
---   * `partial`   - algo se aplicó y un paso posterior falló; no se revierte
---                   automáticamente porque el comando/callback puede haber
---                   producido efectos externos.
---   * `cancelled` - se canceló antes de aplicar la acción.
---   * `timed_out` - la resolución no llegó a tiempo; no se aplicó nada.
---
--- La edición de varios ficheros se prepara por completo antes de escribir. No
--- se promete atomicidad entre ficheros: si un fallo inesperado ocurre a mitad,
--- se intenta revertir sólo lo que la propia operación dejó y el buffer no haya
--- cambiado después.

local workspace = require("katana.lsp.workspace")
local resolve = require("katana.core.resolve")

local M = {}

local uv = vim.uv or vim.loop

---@alias KatanaResultStatus '"success"'|'"failed"'|'"partial"'|'"cancelled"'|'"timed_out"'

---@class KatanaResultEffects
---@field edit boolean
---@field command boolean
---@field execute_fn boolean
---@field buffers string[]

---@class KatanaResult
---@field status KatanaResultStatus
---@field action KatanaAction|nil
---@field title string|nil
---@field message string|nil
---@field error any
---@field stage string|nil
---@field reason string|nil
---@field rollback '"not_needed"'|'"restored"'|'"failed"'
---@field effects KatanaResultEffects
---@field duration_ms number
---@field notification_error string|nil
---@field callback_error string|nil

---@class KatanaExecution
---@field action KatanaAction
---@field result KatanaResult|nil
---@field finished boolean
---@field cancel fun(reason: string|nil)
---@field timer any

---@class KatanaExecutorOptions
---@field bufnr integer
---@field win integer
---@field timeout integer|nil Milisegundos de espera para la resolución (por defecto 5000)
---@field notify boolean|nil `false` desactiva la notificación centralizada
---@field on_result fun(result: KatanaResult)|nil
---@field client_id integer|nil Cliente LSP explícito para `workspace/executeCommand`

---@param message string
---@param err any|nil
local function format_error(message, err)
  if err == nil then
    return message
  end
  return string.format("%s: %s", message, tostring(err))
end

---@param title string|nil
---@return string
local function display_title(title)
  return title and ("'" .. title .. "'") or "la acción"
end

---@param buffers string[]
---@return string
local function format_buffers(buffers)
  if not buffers or #buffers == 0 then
    return ""
  end
  return table.concat(buffers, ", ")
end

--- Notifica el resultado de una ejecución.
---
--- Es el único punto que decide el nivel y el texto de la notificación. Un fallo
--- al notificar no oculta el resultado: se guarda en `notification_error`.
---@param result KatanaResult
---@return boolean ok
function M.notify_result(result)
  if type(result) ~= "table" then
    return false
  end

  local message
  local level

  if result.status == "success" then
    return true
  elseif result.status == "cancelled" then
    message = string.format("Katana: %s cancelada", display_title(result.title))
    level = vim.log.levels.INFO
  elseif result.status == "timed_out" then
    message = string.format(
      "Katana: %s agotó el tiempo de resolución (%s): %s",
      display_title(result.title),
      tostring(result.reason or "?"),
      tostring(result.message or "")
    )
    level = vim.log.levels.ERROR
  elseif result.status == "partial" then
    local buffers = format_buffers(result.effects and result.effects.buffers)
    message = string.format(
      "Katana: %s quedó parcialmente aplicada (%s): %s",
      display_title(result.title),
      tostring(result.stage or "?"),
      tostring(result.message or result.error or "error desconocido")
    )
    if buffers ~= "" then
      message = message .. ". Recursos modificados: " .. buffers
    end
    if result.rollback == "failed" then
      message = message .. ". No se pudo verificar la reversión de todos los cambios"
    end
    level = vim.log.levels.ERROR
  else -- failed
    message = string.format(
      "Katana: %s falló (%s): %s",
      display_title(result.title),
      tostring(result.stage or "?"),
      tostring(result.message or result.error or "error desconocido")
    )
    if result.reason == "disabled" then
      level = vim.log.levels.WARN
    else
      level = vim.log.levels.ERROR
    end
    if result.rollback == "restored" then
      message = message .. ". Cambios revertidos"
    end
  end

  local ok, err = pcall(vim.notify, message, level)
  if not ok then
    result.notification_error = tostring(err)
  end

  return ok
end

--- Valida estructuralmente un `WorkspaceEdit`.
---@param edit vim.lsp.WorkspaceEdit|nil
---@return boolean ok
---@return string|nil error
function M.validate_edit(edit)
  if edit == nil then
    return true
  end

  if type(edit) ~= "table" then
    return false, "WorkspaceEdit inválido"
  end

  local entries, err = workspace.extract_edits(edit)
  if err then
    return false, err
  end

  if #entries == 0 then
    return false, "el WorkspaceEdit no contiene cambios aplicables"
  end

  for _, entry in ipairs(entries) do
    if type(entry.edits) ~= "table" or #entry.edits == 0 then
      return false, "el WorkspaceEdit contiene un grupo sin ediciones"
    end
    for _, text_edit in ipairs(entry.edits) do
      if type(text_edit) ~= "table" or type(text_edit.range) ~= "table" then
        return false, "edición sin rango en WorkspaceEdit"
      end
    end
  end

  return true
end

--- Devuelve el cliente LSP asociado a una acción.
---@param action KatanaAction
---@param opts KatanaExecutorOptions
---@return vim.lsp.Client|nil
---@return string|nil error
local function find_client(action, opts)
  local clients = vim.lsp.get_clients({ bufnr = opts.bufnr })

  local function by_id(id)
    for _, client in ipairs(clients) do
      if client.id == id then
        return client
      end
    end
    return nil
  end

  if action.client_id then
    local client = by_id(action.client_id)
    if client then
      return client
    end
    return nil, string.format(
      "el cliente LSP '%s' ya no está disponible para esta acción",
      action._client_name or tostring(action.client_id)
    )
  end

  if opts.client_id then
    local client = by_id(opts.client_id)
    if client then
      return client
    end
    return nil, string.format("el cliente LSP %s indicado en opts.client_id no está disponible", tostring(opts.client_id))
  end

  local source = action.source or ""
  if action._client_name or source:match("^lsp:") then
    local name = action._client_name or source:match("^lsp:(.+)$")
    for _, client in ipairs(clients) do
      if client.name == name then
        return client
      end
    end
    return nil, string.format("el cliente LSP '%s' ya no está disponible para esta acción", tostring(name))
  end

  -- Una acción de un proveedor/usuario con `command` no debe ejecutarse con un
  -- cliente arbitrario si hay varios conectados.
  if #clients == 1 then
    return clients[1]
  end
  if #clients == 0 then
    return nil, "no hay ningún cliente LSP disponible para ejecutar el comando"
  end

  return nil, "hay varios clientes LSP y la acción no indica cuál debe ejecutar el comando"
end

--- Aplica el `WorkspaceEdit` de una acción.
---@param action KatanaAction
---@param opts KatanaExecutorOptions
---@return boolean ok
---@return string|nil error
---@return table|nil info
function M.apply_edit(action, opts)
  local edit = action.edit
  if edit == nil then
    return true, nil, {
      applied_buffers = {},
      failed_buffer = nil,
      rollback = "not_needed",
      rollback_details = {},
    }
  end

  if type(edit) ~= "table" then
    return false, "el WorkspaceEdit no es una tabla", {
      applied_buffers = {},
      failed_buffer = nil,
      rollback = "not_needed",
      rollback_details = {},
    }
  end

  local plan, prepare_err = workspace.prepare_edit(edit, opts.bufnr, action.encoding or "utf-16")
  if not plan then
    return false, prepare_err, {
      applied_buffers = {},
      failed_buffer = nil,
      rollback = "not_needed",
      rollback_details = {},
    }
  end

  return workspace.apply_plan(plan)
end

--- Ejecuta el comando LSP de una acción.
---@param action KatanaAction
---@param opts KatanaExecutorOptions
---@return boolean ok
---@return string|nil error
---@return boolean attempted
function M.run_command(action, opts)
  local command = action.command
  if command == nil then
    return true, nil, false
  end

  -- Algunos servidores envían el comando como una cadena simple (comando Vim).
  if type(command) == "string" then
    local ok_cmd, err_cmd = pcall(vim.cmd, command)
    if not ok_cmd then
      return false, format_error("error al ejecutar comando", err_cmd), true
    end
    return true, nil, true
  end

  if type(command) ~= "table" or type(command.command) ~= "string" or command.command == "" then
    return false, "comando LSP inválido (falta 'command')", true
  end

  local client, err_client = find_client(action, opts)
  if not client then
    return false, err_client or "no hay cliente LSP para ejecutar el comando", true
  end

  -- `Client:exec_cmd(cmd, context, handler)`: `cmd` es el objeto completo y el
  -- contexto aporta `bufnr` y `client_id`. La respuesta del servidor puede
  -- llegar después: aquí sólo se detectan los errores síncronos.
  local ok_exec, err_exec = pcall(function()
    client:exec_cmd(command, { bufnr = opts.bufnr })
  end)
  if not ok_exec then
    return false, format_error(string.format("error al ejecutar comando '%s'", command.command), err_exec), true
  end

  return true, nil, true
end

--- Ejecuta la lógica propia de la acción.
---@param action KatanaAction
---@param opts KatanaExecutorOptions
---@return boolean ok
---@return string|nil error
---@return boolean attempted
function M.run_execute_fn(action, opts)
  if action.execute_fn == nil then
    return true, nil, false
  end

  if type(action.execute_fn) ~= "function" then
    return false, "execute_fn no es una función", true
  end

  -- Las acciones propias también pueden modificar el buffer: se cierra el bloque
  -- de undo para que su reversión sea independiente.
  if opts.bufnr and vim.api.nvim_buf_is_valid(opts.bufnr) then
    workspace.close_undo_block(opts.bufnr)
  end

  local ok_fn, err_fn = pcall(action.execute_fn, action)
  if not ok_fn then
    return false, tostring(err_fn), true
  end

  return true, nil, true
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

---@param buffers string[]
---@param name string|nil
local function add_buffer(buffers, name)
  if not name then
    return
  end
  for _, existing in ipairs(buffers) do
    if existing == name then
      return
    end
  end
  buffers[#buffers + 1] = name
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
      M.notify_result(result)
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

  if action.disabled then
    local reason = type(action.disabled) == "table" and action.disabled.reason or nil
    finish("failed", {
      message = reason or "action is disabled",
      reason = "disabled",
      stage = "validate",
    })
    return execution.result
  end

  local function run(resolved)
    if execution.finished then
      return
    end

    if type(resolved) ~= "table" then
      resolved = action
    end

    if resolved.disabled then
      local reason = type(resolved.disabled) == "table" and resolved.disabled.reason or nil
      finish("failed", {
        message = reason or "action is disabled",
        reason = "disabled",
        stage = "validate",
      })
      return
    end

    local effects = {
      edit = false,
      command = false,
      execute_fn = false,
      buffers = {},
    }

    local ok_edit, edit_err, info = M.apply_edit(resolved, opts)
    if not ok_edit then
      info = info or { applied_buffers = {}, rollback = "not_needed", rollback_details = {} }

      if info.rollback == "failed" then
        for _, name in ipairs(info.applied_buffers or {}) do
          add_buffer(effects.buffers, name)
        end
        add_buffer(effects.buffers, info.failed_buffer)
        effects.edit = true

        finish("partial", {
          message = edit_err,
          error = edit_err,
          stage = "edit",
          rollback = "failed",
          effects = effects,
        })
      else
        finish("failed", {
          message = edit_err,
          error = edit_err,
          stage = "edit",
          rollback = info.rollback or "not_needed",
          effects = effects,
        })
      end
      return
    end

    info = info or { applied_buffers = {}, rollback = "not_needed" }
    effects.buffers = vim.deepcopy(info.applied_buffers or {})
    effects.edit = #effects.buffers > 0

    local ok_cmd, cmd_err, cmd_attempted = M.run_command(resolved, opts)
    effects.command = cmd_attempted

    if not ok_cmd then
      finish(effects.edit and "partial" or "failed", {
        message = cmd_err,
        error = cmd_err,
        stage = "command",
        effects = effects,
      })
      return
    end

    local ok_fn, fn_err, fn_attempted = M.run_execute_fn(resolved, opts)
    effects.execute_fn = fn_attempted

    if not ok_fn then
      finish((effects.edit or effects.command) and "partial" or "failed", {
        message = fn_err,
        error = fn_err,
        stage = "execute_fn",
        effects = effects,
      })
      return
    end

    if not effects.edit and not effects.command and not effects.execute_fn then
      finish("failed", {
        message = "la acción no tiene efectos ejecutables (edit, command ni execute_fn)",
        stage = "validate",
        effects = effects,
      })
      return
    end

    finish("success", { effects = effects })
  end

  local needs_resolve = type(action.resolve_fn) == "function" and not action.edit and not action.command

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

      run(resolved_action or action)
    end)

    -- Si `resolve_fn` llamó al callback de forma síncrona, el resultado ya está
    -- listo: se devuelve el `KatanaResult` en lugar de un handle terminado.
    return execution.finished and execution.result or execution
  end

  run(action)
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
