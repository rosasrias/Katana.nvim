---@mod katana.lsp.text_edit Aplicación de TextEdit
---
--- Aplica listas de `lsp.TextEdit` ya validadas, tanto sobre una copia de líneas
--- (preview) como sobre un buffer real. La validación vive en
--- `katana.lsp.edit_validation`.

local optional = require("katana.core.optional")
local encoding_module = require("katana.lsp.encoding")

local M = {}

--- Ordena las ediciones de abajo arriba para aplicar sin desplazar posiciones.
---@param edits lsp.TextEdit[]
---@return lsp.TextEdit[]
local function sorted_edits(edits)
  local sorted = vim.deepcopy(edits or {})

  table.sort(sorted, function(a, b)
    local a_start = a.range and a.range.start or { line = 0, character = 0 }
    local b_start = b.range and b.range.start or { line = 0, character = 0 }
    if a_start.line ~= b_start.line then
      return a_start.line > b_start.line
    end
    return (a_start.character or 0) > (b_start.character or 0)
  end)

  return sorted
end

--- Aplica las ediciones sobre una copia de las líneas del buffer.
---
--- Devuelve las líneas resultantes sin tocar el buffer real. Se usa para generar
--- el diff de la previsualización.
---@param lines string[]
---@param edits lsp.TextEdit[]
---@param encoding KatanaEncoding
---@return string[]
function M.apply_to_lines(lines, edits, encoding)
  local result = vim.deepcopy(lines)

  for _, edit in ipairs(sorted_edits(edits)) do
    local range = edit.range or {}
    local start = range.start or { line = 0, character = 0 }
    local stop = range["end"] or start

    local start_line = start.line or 0
    local stop_line = stop.line or start_line

    local start_text = result[start_line + 1] or ""
    local stop_text = result[stop_line + 1] or start_text

    local start_col = encoding_module.char_to_byte(start_text, start.character or 0, encoding)
    local stop_col = encoding_module.char_to_byte(stop_text, stop.character or 0, encoding)

    -- Se sustituye sólo el tramo [start_col, stop_col): el prefijo de la línea
    -- inicial y el sufijo de la final se conservan. Reemplazar líneas completas
    -- producía previews falsos en ediciones intra-línea (p. ej. insertar `;`).
    local replacement = vim.split(
      start_text:sub(1, start_col) .. (optional.value(edit.newText) or "") .. stop_text:sub(stop_col + 1),
      "\n",
      { plain = true }
    )

    local head = vim.list_slice(result, 1, start_line)
    local tail = vim.list_slice(result, stop_line + 2, #result)
    result = vim.list_extend(vim.list_extend(head, replacement), tail)
  end

  return result
end

--- Aplica las ediciones directamente sobre un buffer.
---@param bufnr integer
---@param edits lsp.TextEdit[]
---@param encoding KatanaEncoding
function M.apply_to_buffer(bufnr, edits, encoding)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    error("buffer inválido")
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)

  for _, edit in ipairs(sorted_edits(edits)) do
    local range = edit.range or {}
    local start = range.start or { line = 0, character = 0 }
    local stop = range["end"] or start

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local start_line = start.line or 0
    local stop_line = stop.line or start_line

    if start_line < 0 or stop_line < start_line or stop_line >= line_count then
      error(string.format("rango fuera del buffer (%d..%d de %d líneas)", start_line, stop_line, line_count))
    end

    local start_text = lines[start_line + 1] or ""
    local stop_text = lines[stop_line + 1] or start_text

    -- Defensa de bajo nivel: `prepare_edit` ya valida, pero este módulo también
    -- se usa directamente. `char_to_byte` recorta al final de la línea, así que
    -- una columna fuera de rango debe rechazarse antes de convertirla.
    local start_len = encoding_module.byte_to_char(start_text, #start_text, encoding)
    local stop_len = encoding_module.byte_to_char(stop_text, #stop_text, encoding)
    if (start.character or 0) > start_len or (stop.character or 0) > stop_len then
      error(
        string.format(
          "columna fuera de la línea (%d:%d..%d:%d)",
          start_line,
          start.character or 0,
          stop_line,
          stop.character or 0
        )
      )
    end

    local start_col = encoding_module.char_to_byte(start_text, start.character or 0, encoding)
    local stop_col = encoding_module.char_to_byte(stop_text, stop.character or 0, encoding)

    local replacement = vim.split(optional.value(edit.newText) or "", "\n", { plain = true })

    vim.api.nvim_buf_set_text(bufnr, start_line, start_col, stop_line, stop_col, replacement)
  end
end

return M
