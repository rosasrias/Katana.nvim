---@mod katana.apply.pipeline Efectos de una acción
---
--- Ejecuta, en orden, la edición, el comando y el callback de una acción ya
--- resuelta. Devuelve el estado resultante y los campos que el executor
--- convierte en `KatanaResult`; no notifica ni gestiona timeouts.

local command = require("katana.apply.command")
local edit = require("katana.apply.edit")
local run = require("katana.apply.run")

local M = {}

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

--- Ejecuta los efectos de una acción resuelta.
---@param action KatanaAction
---@param opts KatanaExecutorOptions
---@return KatanaResultStatus status
---@return table fields
function M.run(action, opts)
  local effects = {
    edit = false,
    command = false,
    execute_fn = false,
    buffers = {},
  }

  local ok_edit, edit_err, info = edit.apply(action, opts)
  if not ok_edit then
    info = info or { applied_buffers = {}, rollback = "not_needed", rollback_details = {} }

    if info.rollback == "failed" then
      for _, name in ipairs(info.applied_buffers or {}) do
        add_buffer(effects.buffers, name)
      end
      add_buffer(effects.buffers, info.failed_buffer)
      effects.edit = true

      return "partial", {
        message = edit_err,
        error = edit_err,
        stage = "edit",
        rollback = "failed",
        effects = effects,
      }
    end

    return "failed", {
      message = edit_err,
      error = edit_err,
      stage = "edit",
      rollback = info.rollback or "not_needed",
      effects = effects,
    }
  end

  info = info or { applied_buffers = {}, rollback = "not_needed" }
  effects.buffers = vim.deepcopy(info.applied_buffers or {})
  effects.edit = #effects.buffers > 0

  local ok_cmd, cmd_err, cmd_attempted = command.run(action, opts)
  effects.command = cmd_attempted

  if not ok_cmd then
    return effects.edit and "partial" or "failed", {
      message = cmd_err,
      error = cmd_err,
      stage = "command",
      effects = effects,
    }
  end

  local ok_fn, fn_err, fn_attempted = run.execute_fn(action, opts)
  effects.execute_fn = fn_attempted

  if not ok_fn then
    return (effects.edit or effects.command) and "partial" or "failed", {
      message = fn_err,
      error = fn_err,
      stage = "execute_fn",
      effects = effects,
    }
  end

  if not effects.edit and not effects.command and not effects.execute_fn then
    return "failed", {
      message = "la acción no tiene efectos ejecutables (edit, command ni execute_fn)",
      stage = "validate",
      effects = effects,
    }
  end

  return "success", { effects = effects }
end

return M
