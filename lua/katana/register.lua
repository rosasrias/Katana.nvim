---@mod katana.register Registro de acciones propias del usuario
---
--- Permite añadir acciones al mismo menú que las de LSP sin depender de ningún
--- servidor:
---
--- ```lua
--- require("katana").register_action({
---   title = "Convertir a snake_case",
---   kind = "refactor.rewrite",
---   source = "mi-plugin",
---   run = function() end,
--- })
--- ```

local M = {}

---@class KatanaRegisteredAction
---@field title string
---@field kind string|nil
---@field source string|nil
---@field run fun()|nil
---@field when fun(ctx: KatanaContext): boolean|nil

---@type KatanaRegisteredAction[]
M.actions = {}

--- Registra una acción.
---@param spec KatanaRegisteredAction
---@return KatanaRegisteredAction
function M.register(spec)
  assert(type(spec) == "table", "katana: register_action expects a table")
  assert(type(spec.title) == "string" and spec.title ~= "", "katana: register_action requires a title")
  assert(spec.run == nil or type(spec.run) == "function", "katana: register_action 'run' must be a function")

  local action = {
    title = spec.title,
    kind = spec.kind,
    source = spec.source,
    run = spec.run,
    when = spec.when,
  }

  table.insert(M.actions, action)

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

    if spec.when then
      local ok, value = pcall(spec.when, ctx)
      allowed = ok and value and true or false
    end

    if allowed then
      result[#result + 1] = {
        title = spec.title,
        kind = spec.kind,
        source = "user:" .. (spec.source or "registered"),
        raw = spec,
        execute_fn = function()
          if spec.run then
            spec.run(spec)
          end
        end,
      }
    end
  end

  return result
end

return M
