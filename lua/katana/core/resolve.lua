---@mod katana.core.resolve Resolución de acciones
---
--- Algunas acciones llegan del servidor sin `edit` ni `command`: hay que pedirselas
--- con `codeAction/resolve`. La acción normalizada guarda su propia función de
--- resolución (`resolve_fn`), de modo que este módulo funciona igual para LSP,
--- proveedores y acciones del usuario.
---
--- Una acción se resuelve **una sola vez**. Si la resolución ya está en curso
--- (por ejemplo, porque `resolve_on_open` la lanzó y el usuario confirmó antes de
--- que terminara), los nuevos interesados se enganchan a la misma petición en
--- lugar de lanzar otra. `resolve_fn` puede llamar a su callback con un error:
--- en ese caso la acción queda marcada como resuelta y el executor lo notifica
--- como fallo, en vez de fingir que no había nada que hacer.

local M = {}

---@class KatanaResolveState
---@field started boolean
---@field done boolean
---@field error any
---@field waiters (fun(action: KatanaAction, err: any|nil))[]

---@param action KatanaAction
---@return KatanaResolveState
local function resolve_state(action)
  if type(action._katana_resolve) ~= "table" then
    action._katana_resolve = {
      started = false,
      done = false,
      error = nil,
      waiters = {},
    }
  end
  return action._katana_resolve
end

--- Actualiza el preview sólo si la acción resuelta es la que está seleccionada.
---
--- Una respuesta tardía no debe tocar una selección distinta ni reabrir una UI
--- cerrada. Un error al repintar se registra, pero no cambia el resultado de la
--- resolución.
---@param action KatanaAction
local function refresh_preview(action)
  local ok, err = pcall(function()
    local state = require("katana.state")
    if not state.open then
      return
    end

    local item = state.flat[state.index]
    if item and item.type == "action" and item.action == action then
      require("katana.preview.diff").update()
    end
  end)

  if not ok then
    pcall(function()
      local state = require("katana.state")
      state.last = state.last or {}
      state.last.error = "preview.update: " .. tostring(err)
      vim.notify("Katana: error al actualizar el preview: " .. tostring(err), vim.log.levels.DEBUG)
    end)
  end
end

---@param action KatanaAction
---@param state KatanaResolveState
---@param resolved KatanaAction|nil
---@param err any|nil
local function finish(action, state, resolved, err)
  if state.done then
    return
  end

  state.done = true
  state.error = err
  action._resolved = true
  action._resolve_error = err

  local waiters = state.waiters
  state.waiters = {}

  for _, waiter in ipairs(waiters) do
    -- Un callback defectuoso no debe impedir que los demás reciban el
    -- resultado. El error se registra para que sea diagnosticable.
    local ok, callback_err = pcall(waiter, resolved or action, err)
    if not ok then
      pcall(function()
        vim.notify("Katana: callback de resolución falló: " .. tostring(callback_err), vim.log.levels.DEBUG)
      end)
    end
  end

  refresh_preview(resolved or action)
end

--- Resuelve una acción concreta.
---
--- Si la acción ya se resolvió, o no necesita resolución, el callback se invoca
--- inmediatamente (también si hubo un error previo).
---@param action KatanaAction|nil
---@param cb fun(action: KatanaAction, err: any|nil)|nil
function M.resolve_single(action, cb)
  if type(action) ~= "table" then
    if cb then
      cb(action, "acción nula")
    end
    return
  end

  if action.edit ~= nil or action.command ~= nil then
    action._resolved = true
    if cb then
      cb(action, action._resolve_error)
    end
    return
  end

  if type(action.resolve_fn) ~= "function" then
    action._resolved = true
    if cb then
      cb(action, action._resolve_error)
    end
    return
  end

  local state = resolve_state(action)

  if state.done then
    if cb then
      cb(action, state.error)
    end
    return
  end

  if state.started then
    if cb then
      state.waiters[#state.waiters + 1] = cb
    end
    return
  end

  state.started = true
  if cb then
    state.waiters[#state.waiters + 1] = cb
  end

  local function done(resolved, err)
    finish(action, state, resolved, err)
  end

  local ok, result = pcall(action.resolve_fn, done)

  if not ok then
    done(action, result)
    return
  end

  -- Si la función de resolución devuelve la acción (estilo síncrono), se usa
  -- sólo si no ha llamado ya a `done`.
  if type(result) == "table" and not state.done then
    done(result, nil)
  end
end

--- Resuelve un lote de acciones (resolución en segundo plano al abrir el picker).
---@param actions KatanaAction[]
---@param limit integer|nil número máximo de acciones a resolver
function M.resolve_batch(actions, limit)
  limit = limit or 0
  local count = 0

  for _, action in ipairs(actions or {}) do
    if limit > 0 and count >= limit then
      break
    end

    local needs_resolve = type(action.resolve_fn) == "function" and not action.edit and not action.command

    if needs_resolve then
      local state = type(action._katana_resolve) == "table" and action._katana_resolve or nil

      -- No se lanza una segunda petición si ya está en curso o terminó.
      if not state or not state.started then
        count = count + 1
        M.resolve_single(action, function(resolved, err)
          if err ~= nil then
            pcall(function()
              vim.notify(
                string.format("Katana: no se pudo resolver '%s': %s", tostring(resolved and resolved.title), tostring(err)),
                vim.log.levels.DEBUG
              )
            end)
          end
        end)
      end
    else
      action._resolved = true
    end
  end
end

--- Indica si una acción tiene una resolución en curso.
---@param action KatanaAction|nil
---@return boolean
function M.is_pending(action)
  local state = type(action) == "table" and action._katana_resolve or nil
  return type(state) == "table" and state.started and not state.done
end

return M
