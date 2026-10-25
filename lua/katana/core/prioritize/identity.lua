---@mod katana.core.prioritize.identity Deduplicación de acciones
---
--- Dos acciones con el mismo título y kind pero con distinto `edit`, `command`,
--- `resolve_fn` o `execute_fn` **no** son equivalentes: aplicarlas tiene efectos
--- distintos. La firma de contenido evita descartar una acción con efectos
--- diferentes.

local M = {}

--- Serializa un payload para la firma de deduplicación.
---
--- Las tablas se codifican como JSON (determinista para los payloads LSP). Si
--- no se pueden codificar (por ejemplo, porque contienen funciones), se usa una
--- representación de respaldo estable dentro de la misma sesión.
---@param value any
---@return string
local function serialize(value)
  if type(value) == "string" then
    return value
  end

  if type(value) == "table" then
    local ok, encoded = pcall(vim.json.encode, value)
    if ok and type(encoded) == "string" then
      return encoded
    end
  end

  return tostring(value)
end

--- Firma del contenido ejecutable de una acción.
---
--- Para acciones con `resolve_fn` no se usa la identidad de la función (dos
--- clientes LSP crean closures distintas para la misma acción): se firma el
--- payload original (`data`/`raw`), que es lo que determina la resolución.
--- Para `execute_fn` sí se usa la identidad, porque dos callbacks distintos
--- pueden hacer cosas distintas aunque compartan título.
---
--- Para payloads grandes (un `WorkspaceEdit` completo) se usa el hash del
--- serializado, no el texto, para que la clave no crezca sin límite.
---@param action KatanaAction
---@return string
function M.action_signature(action)
  if not action then
    return "nil"
  end

  local parts = {}

  if type(action.edit) == "table" then
    parts[#parts + 1] = "edit:" .. serialize(action.edit)
  end

  if type(action.command) == "string" then
    parts[#parts + 1] = "cmd:" .. action.command
  elseif type(action.command) == "table" then
    parts[#parts + 1] = "cmd:" .. serialize(action.command)
  end

  if action.data ~= nil then
    parts[#parts + 1] = "data:" .. serialize(action.data)
  end

  if action.resolve_fn then
    -- `data` es lo que el servidor usa para resolver; `raw` es el respaldo
    -- cuando la acción no trae `data` (por ejemplo, acciones propias).
    local payload = action.data
    if payload == nil then
      payload = action.raw
    end
    parts[#parts + 1] = "resolve:" .. (payload ~= nil and serialize(payload) or tostring(action.resolve_fn))
  end

  if action.execute_fn then
    parts[#parts + 1] = "exec:" .. tostring(action.execute_fn)
  end
  if action.id ~= nil then
    parts[#parts + 1] = "id:" .. tostring(action.id)
  end
  if action.disabled then
    parts[#parts + 1] = "disabled"
  end

  if #parts == 0 then
    return "noop"
  end

  local payload = table.concat(parts, "|")

  -- El payload puede ser enorme (un WorkspaceEdit completo). Se resume a un
  -- hash corto: la firma sólo tiene que distinguir acciones, no ser reversible.
  local ok_hash, hash = pcall(vim.fn.sha256, payload)
  if ok_hash and type(hash) == "string" and hash ~= "" then
    return hash:sub(1, 16)
  end

  return tostring(#payload) .. ":" .. payload:sub(1, 64)
end

--- Elimina duplicados sólo cuando `title`, `kind` y el payload son equivalentes.
---
--- La acción conservada es la primera encontrada (ya ordenada por prioridad) y
--- acumula en `sources` todos los orígenes que la generaron. Si el payload
--- difiere, ambas acciones se conservan como filas independientes: descartar una
--- cambiaría el resultado de aplicar la acción.
---@param actions KatanaAction[]
---@return KatanaAction[]
function M.dedupe(actions)
  local seen = {}
  local result = {}

  for _, action in ipairs(actions or {}) do
    local signature = M.action_signature(action)
    local key = table.concat({
      action.title or "",
      action.kind or "",
      signature,
    }, "\0")

    local previous = seen[key]

    if previous then
      local sources = previous.sources or { previous.source }
      if action.source and not vim.tbl_contains(sources, action.source) then
        table.insert(sources, action.source)
      end
      previous.sources = sources

      -- Conservamos los diagnósticos si la acción original no traía ninguno.
      if not previous.diagnostics and action.diagnostics then
        previous.diagnostics = action.diagnostics
      end
      if not previous.isPreferred and action.isPreferred then
        previous.isPreferred = action.isPreferred
      end
    else
      action.sources = { action.source }
      action._dedupe_sig = signature
      seen[key] = action
      table.insert(result, action)
    end
  end

  return result
end

return M
