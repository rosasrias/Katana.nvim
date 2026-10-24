---@mod katana.core.prioritize Priorización, ordenación y deduplicación
---
--- El filtro es intencionadamente agnóstico respecto al origen de la acción: sólo
--- consume la forma normalizada (`KatanaAction`). Esto permite reusarlo tanto para
--- acciones de LSP como para las registradas por el usuario o los proveedores.
---
--- El orden final se decide en tres niveles:
---   1. Kind (jerárquico: `refactor.extract.function` hereda de `refactor.extract`).
---   2. Diagnóstico bajo el cursor (las quickfix del error que estás viendo).
---   3. Origen (LSP > Tree-sitter > acciones del usuario > proveedores).
---
--- Dentro del mismo nivel se desempata con los pesos configurados por el usuario
--- (`kind_weights`, `lsp_weights`) y, a igualdad, alfabéticamente.

local config = require("katana.config")

local M = {}

--- Prioridad por origen. El número más bajo gana.
---@type table<string, integer>
local ORIGIN_RANK = {
  lsp = 0,
  ts = 1,
  user = 2,
  provider = 3,
}

---@param kind string|nil
---@param priority string[]
---@return integer rank `0` = máxima prioridad
function M.kind_rank(kind, priority)
  if not kind or kind == "" then
    return #priority
  end

  -- Coincidencia exacta.
  for i, known in ipairs(priority) do
    if known == kind then
      return i - 1
    end
  end

  -- Coincidencia por jerarquía: "refactor.extract.function" hereda el rango de
  -- "refactor.extract" y, en su defecto, el de "refactor".
  for i, known in ipairs(priority) do
    local len = #known
    if kind:sub(1, len) == known and (kind:len() == len or kind:sub(len + 1, len + 1) == ".") then
      return i - 1
    end
  end

  return #priority
end

---@param source string|nil
---@return integer rank
function M.origin_rank(source)
  if not source or source == "" then
    return #ORIGIN_RANK
  end

  local origin = source:match("^(%a+)")
  return ORIGIN_RANK[origin or ""] or #ORIGIN_RANK
end

--- Comprueba si una acción está relacionada con un diagnóstico bajo el cursor.
---
--- La comparación se hace a nivel de línea: las posiciones de los diagnósticos
--- vienen en unidades de codificación LSP (utf-16 por defecto) mientras que el
--- cursor usa bytes, y mezclar ambas unidades produciría falsos negativos.
---@param action KatanaAction
---@param ctx KatanaContext|nil
---@return boolean
function M.touches_cursor_diagnostic(action, ctx)
  local diagnostics = action.diagnostics
  if not diagnostics or #diagnostics == 0 then
    return false
  end

  local row = ctx and ctx.cursor and ctx.cursor.row or 0

  for _, diagnostic in ipairs(diagnostics) do
    local range = diagnostic.range
    if range and range.start then
      local start_line = range.start.line or 0
      local end_line = range["end"] and range["end"].line or start_line
      if row >= start_line and row <= end_line then
        return true
      end
    end
  end

  return false
end

--- Calcula el nivel de prioridad de una acción. Menor número = mejor posición.
---@param action KatanaAction
---@param ctx KatanaContext|nil
---@return integer
function M.score(action, ctx)
  local opts = config.options
  local priority = opts.kinds_priority or opts.group_order or {}

  local kind = M.kind_rank(action.kind, priority)
  local diagnostic = M.touches_cursor_diagnostic(action, ctx) and 0 or 1
  local origin = M.origin_rank(action.source)

  -- El kind manda (multiplicador 100), el diagnóstico desempata dentro del mismo
  -- kind y el origen es el último criterio.
  return kind * 100 + diagnostic * 10 + origin
end

---@param action KatanaAction
---@return number
local function kind_weight(action)
  local opts = config.options
  local weights = opts.kind_weights or {}
  return weights[action.kind] or weights[require("katana.utils").kind_group_key(action.kind)] or 0
end

---@param action KatanaAction
---@return number
local function lsp_weight(action)
  local opts = config.options
  local weights = opts.lsp_weights or {}
  return weights[action._client_name or ""] or 0
end

--- Ordena las acciones por prioridad.
---@param actions KatanaAction[]
---@param ctx KatanaContext|nil
---@return KatanaAction[]
function M.sort(actions, ctx)
  local scored = {}

  for _, action in ipairs(actions or {}) do
    scored[#scored + 1] = {
      action = action,
      score = M.score(action, ctx),
      kind_weight = kind_weight(action),
      lsp_weight = lsp_weight(action),
    }
  end

  table.sort(scored, function(a, b)
    if a.score ~= b.score then
      return a.score < b.score
    end
    if a.kind_weight ~= b.kind_weight then
      return a.kind_weight > b.kind_weight
    end
    if a.lsp_weight ~= b.lsp_weight then
      return a.lsp_weight > b.lsp_weight
    end
    -- Orden alfabético estable como criterio de desempate.
    local title_a = a.action.title or ""
    local title_b = b.action.title or ""
    if title_a ~= title_b then
      return title_a < title_b
    end
    return (a.action.source or "") < (b.action.source or "")
  end)

  local sorted = {}
  for _, entry in ipairs(scored) do
    sorted[#sorted + 1] = entry.action
  end

  return sorted
end

--- Firma del contenido ejecutable de una acción.
---
--- Dos acciones con el mismo título y kind pero con distinto `edit`, `command`,
--- `resolve_fn` o `execute_fn` **no** son equivalentes: aplicarlas tiene efectos
--- distintos. La deduplicación usa esta firma para no descartar ninguna.
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
    local ok, encoded = pcall(vim.json.encode, action.edit)
    parts[#parts + 1] = "edit:" .. (ok and encoded or tostring(action.edit))
  end

  if type(action.command) == "string" then
    parts[#parts + 1] = "cmd:" .. action.command
  elseif type(action.command) == "table" then
    local ok, encoded = pcall(vim.json.encode, action.command)
    parts[#parts + 1] = "cmd:" .. (ok and encoded or tostring(action.command.command))
  end

  if action.resolve_fn then
    parts[#parts + 1] = "resolve:" .. tostring(action.resolve_fn)
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

--- Filtra (deduplica) y ordena las acciones.
---@param actions KatanaAction[]
---@param ctx KatanaContext|nil
---@return KatanaAction[]
function M.filter_and_sort(actions, ctx)
  local opts = config.options
  local sorted = M.sort(actions, ctx)

  if opts.dedupe then
    sorted = M.dedupe(sorted)
  end

  return sorted
end

return M
