---@mod katana.core.action Contrato interno de acciones
---
--- Toda acción, venga de LSP, de Tree-sitter, de un proveedor o de
--- `register_action()`, se convierte a la misma forma (`KatanaAction`) en la
--- frontera de entrada. El resto del plugin (priorización, UI y executor) sólo
--- conoce esa forma.
---
--- Contrato público:
---
---   * `register_action()` acepta `run` (preferido) o `execute_fn` (alias
---     histórico). Ambos reciben la acción normalizada como único argumento.
---   * `register_provider()` devuelve acciones con `execute_fn` o `run`; el
---     proveedor también puede devolver `edit`, `command`, `resolve_fn`, etc.
---
--- `run` y `execute_fn` no se conservan como dos caminos internos: en la
--- normalización se elige uno (`execute_fn` gana si están los dos) y el executor
--- sólo conoce `execute_fn`.

local optional = require("katana.core.optional")

local M = {}

---@class KatanaAction
---@field title string Título legible de la acción
---@field kind string|nil Kind LSP (quickfix, refactor.extract, source.fixAll, ...)
---@field source string Origen (`lsp:lua_ls`, `ts`, `user:mi-plugin`, ...)
---@field raw any Payload original
---@field resolve_fn fun(cb: fun(action: KatanaAction, err: any|nil))|nil Resolución diferida
---@field execute_fn fun(action: KatanaAction)|nil Ejecución personalizada
---@field edit vim.lsp.WorkspaceEdit|nil Cambios a aplicar
---@field command lsp.Command|string|nil Comando a ejecutar
---@field diagnostics lsp.Diagnostic[]|nil Diagnósticos relacionados
---@field sources string[]|nil Orígenes fusionados (tras deduplicar)
---@field client_id integer|nil Cliente LSP propietario
---@field encoding KatanaEncoding|nil Codificación de posiciones del cliente
---@field isPreferred boolean|nil
---@field disabled table|boolean|nil
---@field id string|number|nil Identificador propio de la acción
---@field data any Datos del servidor o del usuario
---@field priority number|nil Prioridad de registro (mayor primero)
---@field variants KatanaAction[]|nil Variantes opcionales
---@field _client_name string|nil Nombre del cliente LSP (compatibilidad)
---@field _client_id integer|nil Cliente LSP (compatibilidad)
---@field _bufnr integer|nil Buffer de origen (compatibilidad)
---@field _provider string|nil Proveedor que creó la acción

---@param value any
---@return boolean
local function is_function(value)
  return type(value) == "function"
end

---@param value any
---@return boolean
local function is_disabled(value)
  if value == nil or type(value) == "boolean" then
    return true
  end
  return type(value) == "table"
end

--- Normaliza una acción de entrada.
---
--- Devuelve `nil, error` en lugar de lanzar para que los proveedores puedan
--- informar de una acción inválida sin tumbar la recogida completa.
---@param spec table
---@param opts table|nil
---   - `source` string|nil origen ya calculado
---   - `raw` any|nil payload original (por defecto, `spec`)
---   - `source_prefix` string|nil prefijo a aplicar si `source` no lo lleva
---   - `default_source` string|nil origen cuando `spec.source` es nil
---@return KatanaAction|nil action
---@return string|nil error
function M.normalize(spec, opts)
  if type(spec) ~= "table" then
    return nil, "la acción no es una tabla"
  end

  if type(spec.title) ~= "string" or spec.title == "" then
    return nil, "la acción no tiene un título válido"
  end

  opts = opts or {}

  -- Los campos opcionales pueden llegar como `vim.NIL` desde JSON. Se
  -- normalizan una sola vez para que el resto del plugin pueda usar `nil`
  -- como "ausente" sin comprobaciones especiales.
  local run = optional.value(spec.run)
  local execute_fn_spec = optional.value(spec.execute_fn)
  local resolve_fn = optional.value(spec.resolve_fn)
  local edit = optional.value(spec.edit)
  local command = optional.value(spec.command)
  local disabled = optional.value(spec.disabled)
  local source_spec = optional.value(spec.source)
  local raw = optional.value(opts.raw)

  if run ~= nil and not is_function(run) then
    return nil, "el campo 'run' debe ser una función"
  end

  if execute_fn_spec ~= nil and not is_function(execute_fn_spec) then
    return nil, "el campo 'execute_fn' debe ser una función"
  end

  if resolve_fn ~= nil and not is_function(resolve_fn) then
    return nil, "el campo 'resolve_fn' debe ser una función"
  end

  if edit ~= nil and type(edit) ~= "table" then
    return nil, "el campo 'edit' debe ser un WorkspaceEdit"
  end

  if command ~= nil and type(command) ~= "table" and type(command) ~= "string" then
    return nil, "el campo 'command' debe ser una tabla o una cadena"
  end

  if not is_disabled(disabled) then
    return nil, "el campo 'disabled' debe ser booleano o una tabla"
  end

  local source = optional.value(opts.source)
  if type(source) ~= "string" or source == "" then
    source = source_spec
  end
  if type(source) ~= "string" or source == "" then
    source = opts.default_source or "user:unknown"
  end
  if opts.source_prefix and source:sub(1, #opts.source_prefix) ~= opts.source_prefix then
    source = opts.source_prefix .. source
  end

  -- `execute_fn` tiene prioridad; `run` es el nombre público recomendado.
  local execute_fn = execute_fn_spec
  if not execute_fn and is_function(run) then
    execute_fn = function(action)
      return run(action)
    end
  end

  if raw == nil then
    raw = spec
  end

  local is_preferred = optional.value(spec.isPreferred)

  local normalized = {
    title = spec.title,
    kind = optional.value(spec.kind),
    source = source,
    raw = raw,
    resolve_fn = resolve_fn,
    execute_fn = execute_fn,
    edit = edit,
    command = command,
    diagnostics = optional.value(spec.diagnostics),
    client_id = optional.value(spec.client_id),
    encoding = optional.value(spec.encoding),
    isPreferred = is_preferred and true or false,
    disabled = disabled,
    id = optional.value(spec.id),
    data = optional.value(spec.data),
    priority = optional.value(spec.priority),
    variants = optional.value(spec.variants),
    _client_name = optional.value(spec._client_name),
    _client_id = optional.value(spec._client_id),
    _bufnr = optional.value(spec._bufnr),
    _provider = optional.value(spec._provider),
  }

  return normalized, nil
end

--- Indica si una acción tiene algún efecto ejecutable.
---@param action KatanaAction|nil
---@return boolean
function M.has_effect(action)
  if type(action) ~= "table" then
    return false
  end

  return optional.value(action.edit) ~= nil
    or optional.value(action.command) ~= nil
    or is_function(optional.value(action.execute_fn))
    or is_function(optional.value(action.resolve_fn))
end

return M
