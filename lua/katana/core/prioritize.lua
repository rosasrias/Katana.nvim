---@mod katana.core.prioritize Priorización, ordenación y deduplicación
---
--- Fachada del filtro, intencionadamente agnóstica respecto al origen de la
--- acción: sólo consume la forma normalizada (`KatanaAction`). Esto permite
--- reusarlo tanto para acciones de LSP como para las registradas por el usuario
--- o los proveedores.
---
---   * `ranking`  decide el orden (kind, diagnóstico y origen).
---   * `identity` decide cuándo dos acciones son equivalentes.

local config = require("katana.config")
local identity = require("katana.core.prioritize.identity")
local ranking = require("katana.core.prioritize.ranking")

local M = {}

M.kind_rank = ranking.kind_rank
M.origin_rank = ranking.origin_rank
M.touches_cursor_diagnostic = ranking.touches_cursor_diagnostic
M.score = ranking.score
M.sort = ranking.sort

M.action_signature = identity.action_signature
M.dedupe = identity.dedupe

--- Filtra (deduplica) y ordena las acciones.
---@param actions KatanaAction[]
---@param ctx KatanaContext|nil
---@return KatanaAction[]
function M.filter_and_sort(actions, ctx)
  local opts = config.options
  local sorted = ranking.sort(actions, ctx)

  if opts.dedupe then
    sorted = identity.dedupe(sorted)
  end

  return sorted
end

return M
