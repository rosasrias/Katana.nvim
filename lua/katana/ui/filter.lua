---@mod katana.ui.filter Filtrado en vivo de las acciones
---
--- El filtro se aplica sobre el texto que el usuario escribe en la ventana de
--- prompt. Se usa un "fuzzy" simple (subsecuencia de caracteres) que puntúa las
--- coincidencias: las mejores quedan arriba y se conserva el orden de prioridad
--- original entre coincidencias de la misma calidad.

local state = require("katana.state")

local M = {}

--- Filtro "fuzzy": subsecuencia de caracteres, sin distinguir mayúsculas.
---@param text string
---@param pattern string
---@return number|nil score `nil` si no coincide
local function fuzzy_score(text, pattern)
  if pattern == "" then
    return 0
  end

  local haystack = text:lower()
  local needle = pattern:lower()

  local score = 0
  local position = 1
  local first = nil

  for i = 1, #needle do
    local char = needle:sub(i, i)
    local found = haystack:find(char, position, true)
    if not found then
      return nil
    end
    if not first then
      first = found
    end
    score = score + (found - position)
    position = found + 1
  end

  return (first or 1) + score
end

--- Texto por el que se busca (título + kind + origen).
---@param action KatanaAction
---@return string
local function haystack(action)
  local sources = action.source or ""
  if type(action.sources) == "table" and #action.sources > 1 then
    sources = table.concat(action.sources, ", ")
  end

  return table.concat({ action.title or "", action.kind or "", sources }, " ")
end

--- Aplica el filtro de texto y reconstruye la lista.
---@param query string
function M.apply(query)
  state.query = query or ""

  local scored = {}

  for index, action in ipairs(state.actions) do
    local score = fuzzy_score(haystack(action), state.query)
    if score then
      scored[#scored + 1] = { action = action, score = score, index = index }
    end
  end

  -- Ordena por calidad de coincidencia y, a igualdad, conserva el orden original
  -- (que es el de prioridad calculado por el motor). `table.sort` no es estable,
  -- por eso se incluye el índice original en la comparación.
  table.sort(scored, function(a, b)
    if a.score ~= b.score then
      return a.score < b.score
    end
    return a.index < b.index
  end)

  local filtered = {}
  for _, entry in ipairs(scored) do
    filtered[#filtered + 1] = entry.action
  end

  state.filtered = filtered

  require("katana.ui.window").rebuild()
end

--- Restablece el filtro (muestra todas las acciones).
function M.reset()
  M.apply("")
end

return M
