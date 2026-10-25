---@mod katana.core.fetch.context Contexto de una petición de acciones
---
--- Captura el buffer, ventana, cursor, codificación y diagnósticos en el
--- momento de abrir el picker. El resto de módulos consume esta forma
--- (`KatanaContext`) sin volver a consultar el estado del editor.

local diagnostics = require("katana.core.fetch.diagnostics")
local ranges = require("katana.core.fetch.ranges")

local M = {}

---@class KatanaContext
---@field bufnr integer
---@field win integer
---@field uri string
---@field range lsp.Range
---@field encoding KatanaEncoding
---@field diagnostics lsp.Diagnostic[]
---@field cursor { row: integer, col: integer }
---@field scope '"cursor"'|'"line"'|'"visual"'

--- Construye el contexto de una petición de acciones.
---@param bufnr integer|nil
---@param win integer|nil
---@param opts table|nil
---@return KatanaContext
function M.build(bufnr, win, opts)
  opts = opts or {}

  bufnr = bufnr or vim.api.nvim_get_current_buf()
  win = win or vim.api.nvim_get_current_win()

  if not vim.api.nvim_win_is_valid(win) then
    win = vim.api.nvim_get_current_win()
  end

  -- La codificación de posiciones la fija el cliente LSP; si hay varios se usa la
  -- del primero (Neovim tampoco puede hacer mejor: una misma acción puede estar
  -- dirigida a un único cliente).
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  local encoding = "utf-16"
  for _, client in ipairs(clients) do
    if client.offset_encoding then
      encoding = client.offset_encoding
      break
    end
  end

  local scope = opts.scope or "cursor"
  local cursor = vim.api.nvim_win_get_cursor(win)

  local ctx = {
    bufnr = bufnr,
    win = win,
    uri = vim.uri_from_bufnr(bufnr),
    encoding = encoding,
    diagnostics = {},
    cursor = { row = cursor[1] - 1, col = cursor[2] },
    scope = scope,
  }

  ctx.range = ranges.for_context(ctx, encoding)
  ctx.diagnostics = diagnostics.collect(bufnr, ctx.range, encoding, ctx.scope, ctx.cursor)

  return ctx
end

return M
