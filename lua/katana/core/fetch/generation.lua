---@mod katana.core.fetch.generation Generaciones de peticiones
---
--- Cada llamada a `fetch.get()` incrementa el contador. Las respuestas
--- asíncronas llevan el token de su generación y se descartan si ya hay una
--- petición más reciente: una respuesta lenta no debe reabrir la UI ni pisar el
--- resultado nuevo.

local M = {}

---@type integer
local generation = 0

--- Empieza una petición nueva y devuelve su token.
---@return integer
function M.new()
  generation = generation + 1
  return generation
end

--- ¿Sigue siendo actual el token?
---@param token integer|nil
---@return boolean
function M.is_current(token)
  return token == nil or token == generation
end

--- Invalida las peticiones en curso (sus respuestas se descartarán).
function M.cancel()
  generation = generation + 1
end

return M
