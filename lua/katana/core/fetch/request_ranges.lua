---@mod katana.core.fetch.request_ranges Política de rangos de codeAction
---
--- Decide qué rangos se envían al servidor. El rango del cursor (de ancho
--- cero) es demasiado estricto para los servidores que asocian sus acciones a
--- un token o a un diagnóstico: "Generar método Suma" (Roslyn) sólo aparece si
--- el cursor cae *exactamente* sobre el identificador.

local config = require("katana.config")
local encoding_module = require("katana.lsp.encoding")
local ranges = require("katana.core.fetch.ranges")

local M = {}

--- Calcula los rangos que se piden al servidor en `textDocument/codeAction`.
---
--- En modo "auto" se piden varios rangos:
---
---  1. El rango exacto de los diagnósticos de la línea del cursor (es lo que
---     el servidor usa para decidir qué *code action* ofrece).
---  2. Si no hay diagnósticos, el identificador bajo el cursor.
---  3. Siempre la línea completa: es la red de seguridad que hace que Roslyn
---     ofrezca "Generar método X" aunque el cursor esté en otra palabra de la
---     línea (por ejemplo sobre `Console` en `Console.WriteLine(Suma(7,5.2))`).
---
--- Las respuestas de todos los rangos se fusionan, así que en la práctica el
--- usuario ve la unión de las acciones (los duplicados se eliminan al ordenar).
---
--- Se puede forzar con `code_action_range = "cursor"` o `"line"`.
---@param ctx KatanaContext
---@param encoding KatanaEncoding
---@param diagnostics lsp.Diagnostic[]
---@return lsp.Range[]
function M.for_context(ctx, encoding, diagnostics)
  local mode = config.options.code_action_range or "auto"

  if ctx.scope == "visual" then
    return {
      ranges.visual(ctx.bufnr, ctx.win, encoding)
        or vim.lsp.util.make_given_range_params(nil, nil, ctx.bufnr, encoding).range,
    }
  end

  if mode == "line" or ctx.scope == "line" then
    return { ranges.line(ctx.bufnr, ctx.cursor.row, encoding) }
  end

  if mode == "cursor" then
    return { vim.lsp.util.make_range_params(ctx.win, encoding).range }
  end

  -- "auto": primero el rango real de los diagnósticos.
  local request_ranges = {}
  local union = ranges.union(diagnostics)

  if union then
    request_ranges[#request_ranges + 1] = union
  else
    -- Después, el identificador bajo el cursor.
    local start_col, stop_col = ranges.word(ctx.bufnr, ctx.cursor.row, ctx.cursor.col)
    if start_col then
      local text = vim.api.nvim_buf_get_lines(ctx.bufnr, ctx.cursor.row, ctx.cursor.row + 1, false)[1] or ""
      request_ranges[#request_ranges + 1] = {
        start = { line = ctx.cursor.row, character = encoding_module.byte_to_char(text, start_col, encoding) },
        ["end"] = { line = ctx.cursor.row, character = encoding_module.byte_to_char(text, stop_col, encoding) },
      }
    else
      request_ranges[#request_ranges + 1] = vim.lsp.util.make_range_params(ctx.win, encoding).range
    end
  end

  -- Y la línea completa, que es la que garantiza las acciones ligadas al error
  -- de la línea (Roslyn, entre otros).
  local line = ranges.line(ctx.bufnr, ctx.cursor.row, encoding)
  if not ranges.ranges_equal(request_ranges[#request_ranges], line) then
    request_ranges[#request_ranges + 1] = line
  end

  return request_ranges
end

--- Calcula el rango principal de la petición (el primero de `for_context`).
---@param ctx KatanaContext
---@param encoding KatanaEncoding
---@param diagnostics lsp.Diagnostic[]
---@return lsp.Range
function M.primary(ctx, encoding, diagnostics)
  return M.for_context(ctx, encoding, diagnostics)[1]
end

return M
