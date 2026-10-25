---@mod katana.core.providers Registro de proveedores de acciones
---
--- Un proveedor es una función que recibe el contexto de la petición y devuelve
--- una lista de acciones. Se aceptan tanto `execute_fn` como `run`; la
--- normalización (y la elección entre ambos) ocurre aquí, en la frontera de
--- entrada:
---
--- ```lua
--- require("katana").register_provider(function(ctx)
---   return {
---     {
---       title = "Mi acción",
---       kind = "source",
---       source = "mi-plugin",
---       execute_fn = function(action) end,
---     },
---   }
--- end, "mi-plugin")
--- ```

local action_module = require("katana.core.action")

local M = {}

---@class KatanaProvider
---@field name string
---@field fn fun(ctx: KatanaContext): KatanaAction[]|nil
---@field priority number|nil

---@class KatanaProviderError
---@field source string
---@field err any

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
---@return string|nil error
local function normalize_action(action, provider)
  if type(action) ~= "table" then
    return nil, "la acción no es una tabla"
  end

  local source = action.source
  if type(source) ~= "string" or source == "" then
    source = provider.name
  end

  -- Compatibilidad: se conserva el `provider:` explícito y se añade cuando el
  -- proveedor devuelve un origen legible sin prefijo.
  if source:sub(1, 9) ~= "provider:" then
    source = "provider:" .. source
  end

  local normalized, err = action_module.normalize(action, {
    source = source,
    raw = action.raw or action,
  })

  if not normalized then
    return nil, err
  end

  normalized._provider = provider.name
  return normalized, nil
end

--- Ejecuta los proveedores registrados y normaliza su resultado.
---@param ctx KatanaContext
---@return KatanaAction[]
---@return KatanaProviderError[] errors
function M.collect(ctx)
  local result = {}
  local errors = {}

  for _, provider in ipairs(M.providers) do
    local ok, actions = pcall(provider.fn, ctx)

    if ok and type(actions) == "table" then
      for index, action in ipairs(actions) do
        local normalized, err = normalize_action(action, provider)
        if normalized then
          result[#result + 1] = normalized
        else
          errors[#errors + 1] = {
            source = string.format("proveedor '%s' (acción %d)", tostring(provider.name), index),
            err = err,
          }
        end
      end
    elseif not ok then
      errors[#errors + 1] = {
        source = "proveedor '" .. tostring(provider.name) .. "'",
        err = actions,
      }
    end
  end

  for _, error_entry in ipairs(errors) do
    pcall(function()
      vim.notify(
        "Katana: " .. error_entry.source .. " falló: " .. tostring(error_entry.err),
        vim.log.levels.DEBUG
      )
    end)
  end

  return result, errors
end

return M
