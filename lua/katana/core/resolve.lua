---@mod katana.core.resolve Resolución de acciones
---
--- Algunas acciones llegan del servidor sin `edit` ni `command`: hay que pedirselas
--- con `codeAction/resolve`. La acción normalizada guarda su propia función de
--- resolución (`resolve_fn`), de modo que este módulo funciona igual para LSP,
--- proveedores y acciones del usuario.

local M = {}

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

    if type(action.resolve_fn) == "function" and not action.edit and not action.command then
      count = count + 1
      local ok_res, err_res = pcall(M.resolve_single, action)
      if not ok_res then
        pcall(function()
          vim.notify("Katana: error al resolver acción: " .. tostring(err_res), vim.log.levels.DEBUG)
        end)
      end
    else
      action._resolved = true
    end
  end
end

--- Resuelve una acción concreta.
---@param action KatanaAction|nil
---@param cb fun(action: KatanaAction)|nil
function M.resolve_single(action, cb)
  if not action then
    if cb then
      cb(action)
    end
    return
  end

  if action.edit or action.command then
    action._resolved = true
    if cb then
      cb(action)
    end
    return
  end

  if type(action.resolve_fn) ~= "function" then
    action._resolved = true
    if cb then
      cb(action)
    end
    return
  end

  local finished = false
  local done_called = false
  local function done(resolved)
    if done_called then
      return
    end
    done_called = true
    if finished then
      return
    end
    finished = true
    action._resolved = true

    -- La acción puede haber cambiado (edit/command): si el picker está abierto, el
    -- preview se recalcula para reflejar el nuevo contenido.
    pcall(function()
      if require("katana.ui.window").is_open() then
        require("katana.preview.diff").update()
      end
    end)

    if cb then
      cb(resolved or action)
    end
  end

  local ok, result = pcall(action.resolve_fn, done)

  if not ok then
    done(action)
    return
  end

  -- Si la función de resolución devuelve la acción (estilo síncrono), se usa
  -- solo si no se ha llamado a done() ya.
  if type(result) == "table" and not done_called then
    done(result)
  end
end

return M
