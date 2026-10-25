---@mod katana.apply.notifications Notificación de resultados
---
--- Único punto que decide el nivel y el texto de la notificación de una
--- ejecución. Un fallo al notificar no oculta el resultado: se guarda en
--- `notification_error`.

local M = {}

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

return M
