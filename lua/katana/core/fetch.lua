---@mod katana.core.fetch Motor de recogida de acciones
---
--- Fachada pública del motor. La implementación está separada por
--- responsabilidades en `katana.core.fetch.*`:
---
---   * `generation`   tokens para descartar respuestas viejas.
---   * `context`      captura del buffer, cursor, codificación y diagnósticos.
---   * `diagnostics`  sanitización y *pull diagnostics*.
---   * `ranges`       rangos de cursor/línea/selección/diagnóstico.
---   * `normalizer`   respuesta LSP -> `KatanaAction` + `resolve_fn`.
---   * `request`      `textDocument/codeAction`, timeouts y fusión.
---   * `orchestrator` combina proveedores, Tree-sitter, registro y LSP.
---
--- Se mantiene esta fachada porque `:KatanaDebug`, la UI y los tests la usan
--- como contrato estable.

local generation = require("katana.core.fetch.generation")
local context = require("katana.core.fetch.context")
local diagnostics = require("katana.core.fetch.diagnostics")
local ranges = require("katana.core.fetch.ranges")
local request_ranges = require("katana.core.fetch.request_ranges")
local normalizer = require("katana.core.fetch.normalizer")
local orchestrator = require("katana.core.fetch.orchestrator")

local M = {}

-- Generaciones.
M.new_generation = generation.new
M.is_current = generation.is_current
M.cancel = generation.cancel

-- Contexto y diagnósticos.
M.build_context = context.build
M.sanitize_diagnostic = diagnostics.sanitize
M.collect_diagnostics = diagnostics.collect
M.pull_diagnostics = diagnostics.pull

-- Rangos.
M.visual_range = ranges.visual
M.make_range = ranges.for_context
M.word_range = ranges.word
M.union_range = ranges.union
M.line_range = ranges.line
M.ranges_equal = ranges.ranges_equal
M.make_request_ranges = request_ranges.for_context
M.make_request_range = request_ranges.primary
M.diagnostics_on_row = ranges.diagnostics_on_row

-- Normalización y orquestación.
M.normalize_lsp_actions = normalizer.normalize
M.get_all_actions = orchestrator.get_all_actions
M.get = orchestrator.get

return M
