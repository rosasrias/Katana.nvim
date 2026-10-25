---@mod katana.core.optional Campos opcionales de JSON
---
--- Los servidores LSP envían `null` para los campos opcionales que no están
--- presentes. `vim.json.decode` representa `null` como `vim.NIL`, que en Lua es
--- *truthy* y no es una tabla ni una cadena. Comparar sólo contra `nil` deja
--- pasar ese valor a la validación (por ejemplo, una versión de documento) y
--- produce errores como "versión inválida: vim.NIL".
---
--- Este módulo es la frontera única para interpretar `null` como ausencia. No
--- convierte `false` ni `0`: ambos son valores JSON válidos y con significado.

local M = {}

--- Devuelve `nil` para `nil`/`vim.NIL` y el valor original para el resto.
---@param value any
---@return any
function M.value(value)
  if value == nil or value == vim.NIL then
    return nil
  end
  return value
end

--- Igual que `value`, pero sólo conserva tablas (listas u objetos JSON).
---@param value any
---@return table|nil
function M.table(value)
  local present = M.value(value)
  if type(present) ~= "table" then
    return nil
  end
  return present
end

--- Indica si un campo opcional está realmente presente.
---@param value any
---@return boolean
function M.present(value)
  return M.value(value) ~= nil
end

return M
