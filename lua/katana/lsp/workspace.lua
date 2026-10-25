---@mod katana.lsp.workspace WorkspaceEdit, codificación y diffs
---
--- Fachada pública del conocimiento LSP de bajo nivel. La implementación vive
--- en módulos cohesivos:
---
---   * `katana.lsp.encoding`      conversión de posiciones (utf-8/16/32).
---   * `katana.lsp.uri`           URIs y rutas locales.
---   * `katana.lsp.workspace_edit` extracción/validación estructural.
---   * `katana.lsp.buffer`        resolución de buffers y undo.
---   * `katana.lsp.text_edit`     validación/aplicación de TextEdit.
---   * `katana.lsp.edit_plan`     preparación, aplicación y rollback.
---   * `katana.lsp.diff`          diffs de previsualización.
---
--- Se mantiene esta fachada para no romper a los consumidores existentes
--- (`katana.apply`, `katana.preview.diff`, tests y usuarios que hayan requerido
--- el módulo directamente). `apply_plan` inyecta explícitamente las funciones
--- públicas de aplicación/undo para que sigan siendo sustituibles, como ya
--- hacían las pruebas del executor.

local encoding = require("katana.lsp.encoding")
local uri = require("katana.lsp.uri")
local workspace_edit = require("katana.lsp.workspace_edit")
local buffer = require("katana.lsp.buffer")
local text_edit = require("katana.lsp.text_edit")
local edit_plan = require("katana.lsp.edit_plan")
local edit_apply = require("katana.lsp.edit_apply")
local diff = require("katana.lsp.diff")

local M = {}

-- Codificación de posiciones.
M.byte_to_char = encoding.byte_to_char
M.char_to_byte = encoding.char_to_byte

-- URIs.
M.uri_to_path = uri.to_path

-- Extracción de WorkspaceEdit.
M.extract_edits = workspace_edit.extract
M.collect_edits = workspace_edit.collect

-- Buffers.
M.buffer_version = buffer.version
M.find_buf = buffer.find
M.resolve_buf = buffer.resolve
M.close_undo_block = buffer.close_undo_block

-- Preparación y aplicación.
M.prepare_edit = edit_plan.prepare

--- Aplica un plan preparado.
---
--- La fachada conserva la posibilidad de sustituir `apply_edits_to_buffer` y
--- `close_undo_block` desde fuera (las pruebas lo hacen para simular fallos).
---@param plan KatanaEditPlan
---@return boolean ok
---@return string|nil error
---@return KatanaApplyInfo info
function M.apply_plan(plan)
  return edit_apply.apply(plan, {
    apply_edits = M.apply_edits_to_buffer,
    close_undo = M.close_undo_block,
  })
end

-- Aplicación de bajo nivel.
M.apply_to_lines = text_edit.apply_to_lines
M.apply_edits_to_buffer = text_edit.apply_to_buffer

-- Diff.
M.unified_diff = diff.unified
M.external_diff = diff.external
M.preview_lines = diff.preview_lines

return M
