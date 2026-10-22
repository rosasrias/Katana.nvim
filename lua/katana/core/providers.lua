---@mod katana.core.providers Registro de proveedores de acciones
---
--- Un proveedor es una función que recibe el contexto de la petición y devuelve
--- una lista de acciones normalizadas. Permite mezclar acciones propias con las
--- de LSP sin tocar el motor:
---
--- ```lua
--- require("katana").register_provider(function(ctx)
---   return {
---     {
---       title = "Mi acción",
---       kind = "source",
---       source = "mi-plugin",
---       execute_fn = function() end,
---     },
---   }
--- end, "mi-plugin")
--- ```

local M = {}

---@class KatanaProvider
---@field name string
---@field fn fun(ctx: KatanaContext): KatanaAction[]|nil

---@type KatanaProvider[]
M.providers = {}

--- Registra un proveedor de acciones.
---@param fn fun(ctx: KatanaContext): KatanaAction[]|nil
---@param name string|nil Nombre legible del proveedor
---@return KatanaProvider
function M.register(fn, name)
  assert(type(fn) == "function", "katana: register_provider expects a function")

  local provider = {
    name = name or ("provider:" .. tostring(#M.providers + 1)),
    fn = fn,
  }

  table.insert(M.providers, provider)

  return provider
end

--- Elimina todos los proveedores registrados.
function M.clear()
  M.providers = {}
end

--- Ejecuta los proveedores registrados y normaliza su resultado.
---@param ctx KatanaContext
---@return KatanaAction[]
function M.collect(ctx)
  local result = {}

  for _, provider in ipairs(M.providers) do
    local ok, actions = pcall(provider.fn, ctx)

    if ok and type(actions) == "table" then
      for _, action in ipairs(actions) do
        if type(action) == "table" and action.title then
          -- El prefijo permite saber de dónde viene la acción (y priorizarla).
          if not action.source or action.source:sub(1, 9) ~= "provider:" then
            action.source = "provider:" .. (action.source or provider.name)
          end
          action.raw = action.raw or action
          result[#result + 1] = action
        end
      end
    end
  end

  return result
end

return M
