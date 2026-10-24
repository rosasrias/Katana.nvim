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
---@field priority number|nil

---@type KatanaProvider[]
M.providers = {}

--- Registra un proveedor de acciones.
---@param fn fun(ctx: KatanaContext): KatanaAction[]|nil
---@param name string|nil Nombre legible del proveedor
---@param opts table|nil
---@return KatanaProvider
function M.register(fn, name, opts)
  assert(type(fn) == "function", "katana: register_provider expects a function")

  opts = opts or {}
  local provider = {
    name = name or ("provider:" .. tostring(#M.providers + 1)),
    fn = fn,
    priority = opts.priority or 0,
  }

  table.insert(M.providers, provider)
  table.sort(M.providers, function(a, b)
    if a.priority ~= b.priority then
      return (a.priority or 0) > (b.priority or 0)
    end
    return (a.name or "") < (b.name or "")
  end)

  return provider
end

--- Elimina todos los proveedores registrados.
function M.clear()
  M.providers = {}
end

--- Valida y normaliza una acción devuelta por un proveedor.
---@param action table
---@param provider KatanaProvider
---@return KatanaAction|nil
local function normalize_action(action, provider)
  if type(action) ~= "table" then
    return nil
  end
  if type(action.title) ~= "string" or action.title == "" then
    return nil
  end

  local normalized = vim.deepcopy(action)
  if not normalized.source or type(normalized.source) ~= "string" or normalized.source:sub(1, 9) ~= "provider:" then
    normalized.source = "provider:" .. (normalized.source or provider.name)
  end
  normalized.raw = normalized.raw or action
  normalized._provider = provider.name
  return normalized
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
        local norm = normalize_action(action, provider)
        if norm then
          result[#result + 1] = norm
        end
      end
    elseif not ok then
      pcall(function()
        vim.notify("Katana: provider '" .. tostring(provider.name) .. "' failed: " .. tostring(actions), vim.log.levels.DEBUG)
      end)
    end
  end

  return result
end

return M
