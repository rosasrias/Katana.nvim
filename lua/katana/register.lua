---@mod katana.register Registro de acciones propias del usuario
---
--- Permite añadir acciones al mismo menú que las de LSP sin depender de ningún
--- servidor. El contrato se normaliza aquí (frontera de entrada) y el resto del
--- plugin sólo ve un `KatanaAction`:
---
--- ```lua
--- require("katana").register_action({
---   title = "Convertir a snake_case",
---   kind = "refactor.rewrite",
---   source = "mi-plugin",
---   run = function(action) end, -- recibe la acción normalizada
--- })
--- ```
---
--- `execute_fn` es el alias histórico de `run`. Si se pasan ambos, gana
--- `execute_fn`. Una acción puede no tener callback si trae `edit` o `command`.

local action_module = require("katana.core.action")

local M = {}

---@class KatanaRegisteredAction
---@field title string
---@field kind string|nil
---@field source string|nil
---@field run fun(action: KatanaAction)|nil
---@field when fun(ctx: KatanaContext): boolean|nil
---@field execute_fn fun(action: KatanaAction)|nil
---@field edit vim.lsp.WorkspaceEdit|nil
---@field command table|string|nil
---@field resolve_fn fun(cb: fun(action: KatanaAction, err: any|nil))|nil
---@field diagnostics table[]|nil
---@field disabled boolean|table|nil
---@field id string|number|nil
---@field data any
---@field priority number
---@field raw any

---@type KatanaRegisteredAction[]
M.actions = {}

---@param value any
---@return boolean
local function optional_function(value)
  return value == nil or type(value) == "function"
end

--- Registra una acción.
---@param spec KatanaRegisteredAction
---@param opts table|nil
---@return KatanaRegisteredAction
function M.register(spec, opts)
  assert(type(spec) == "table", "katana: register_action expects a table")
  assert(type(spec.title) == "string" and spec.title ~= "", "katana: register_action requires a title")
  assert(optional_function(spec.run), "katana: register_action 'run' must be a function")
  assert(optional_function(spec.execute_fn), "katana: register_action 'execute_fn' must be a function")
  assert(optional_function(spec.when), "katana: register_action 'when' must be a function")
  assert(optional_function(spec.resolve_fn), "katana: register_action 'resolve_fn' must be a function")
  assert(spec.edit == nil or type(spec.edit) == "table", "katana: register_action 'edit' must be a WorkspaceEdit")
  assert(
    spec.command == nil or type(spec.command) == "table" or type(spec.command) == "string",
    "katana: register_action 'command' must be a table or a string"
  )
  assert(
    spec.disabled == nil or type(spec.disabled) == "boolean" or type(spec.disabled) == "table",
    "katana: register_action 'disabled' must be a boolean or a table"
  )
  assert(
    spec.id == nil or type(spec.id) == "string" or type(spec.id) == "number",
    "katana: register_action 'id' must be a string or a number"
  )

  opts = opts or {}

  local action = {
    title = spec.title,
    kind = spec.kind,
    source = spec.source,
    run = spec.run,
    when = spec.when,
    execute_fn = spec.execute_fn,
    resolve_fn = spec.resolve_fn,
    edit = spec.edit,
    command = spec.command,
    diagnostics = spec.diagnostics,
    disabled = spec.disabled,
    id = spec.id,
    data = spec.data,
    priority = opts.priority or 0,
    raw = spec,
  }

  table.insert(M.actions, action)
  table.sort(M.actions, function(a, b)
    if a.priority ~= b.priority then
      return (a.priority or 0) > (b.priority or 0)
    end
    return (a.title or "") < (b.title or "")
  end)

  return action
end

--- Elimina todas las acciones registradas.
function M.clear()
  M.actions = {}
end

--- Convierte las acciones registradas en acciones normalizadas.
---@param ctx KatanaContext
---@return KatanaAction[]
function M.get_actions(ctx)
  local result = {}

  for _, spec in ipairs(M.actions) do
    local allowed = true
    local when_error = nil

    if spec.when then
      local ok, value = pcall(spec.when, ctx)
      if not ok then
        allowed = false
        when_error = value
      else
        allowed = value and true or false
      end
    end

    if allowed then
      local normalized, err = action_module.normalize(spec, {
        source = "user:" .. (spec.source or "registered"),
        raw = spec,
      })

      if normalized then
        result[#result + 1] = normalized
      else
        pcall(function()
          vim.notify(
            string.format("Katana: acción registrada '%s' ignorada: %s", tostring(spec.title), tostring(err)),
            vim.log.levels.WARN
          )
        end)
      end
    elseif when_error then
      -- Un `when` defectuoso no debe ocultar el problema en silencio, pero
      -- tampoco romper la recogida del resto de acciones.
      pcall(function()
        vim.notify(
          string.format("Katana: 'when' de la acción '%s' falló: %s", tostring(spec.title), tostring(when_error)),
          vim.log.levels.DEBUG
        )
      end)
    end
  end

  return result
end

return M
