---@mod katana.core.fetch.ranges Rangos de una petición codeAction
---
--- Calcula los rangos que se envían al servidor. Un rango de cursor de ancho
--- cero es demasiado estricto para servidores que asocian sus acciones a un
--- token o a un diagnóstico; por eso el modo "auto" pide varios rangos y fusiona
--- las respuestas.

local encoding_module = require("katana.lsp.encoding")
local optional = require("katana.core.optional")

local M = {}

--- Devuelve el rango de la selección visual actual.
---
--- Las marcas `'<` y `'>` sólo se actualizan **al salir** del modo visual, así
--- que `vim.lsp.util.make_given_range_params()` devuelve la selección *anterior*
--- (o un rango vacío si nunca se ha hecho ninguna). Para pedir las acciones de la
--- selección actual hay que forzar la salida del modo visual (las marcas se
--- actualizan) y devolver afterwards el cursor a su sitio.
---@param bufnr integer
---@param win integer
---@param encoding KatanaEncoding
---@return lsp.Range|nil
function M.visual(bufnr, win, encoding)
  local mode = vim.api.nvim_get_mode().mode

  if mode == "v" or mode == "V" or mode == "\22" then
    local cursor = vim.api.nvim_win_get_cursor(win)

    -- ESC: cierra la selección visual y actualiza las marcas '< y '>.
    pcall(vim.cmd, "normal! \27")

    -- El cursor se queda donde estaba (al final de la selección).
    pcall(vim.api.nvim_win_set_cursor, win, cursor)
  end

  local start_mark = vim.api.nvim_buf_get_mark(bufnr, "<")
  local end_mark = vim.api.nvim_buf_get_mark(bufnr, ">")

  if not start_mark or not end_mark or start_mark[1] == 0 or end_mark[1] == 0 then
    return nil
  end

  local start_line = vim.api.nvim_buf_get_lines(bufnr, start_mark[1] - 1, start_mark[1], false)[1] or ""
  local end_line = vim.api.nvim_buf_get_lines(bufnr, end_mark[1] - 1, end_mark[1], false)[1] or ""

  -- `nvim_buf_get_mark` devuelve la fila en base 1 y la columna en base 0.
  local start_char = encoding_module.byte_to_char(start_line, start_mark[2], encoding)
  local end_char = encoding_module.byte_to_char(end_line, end_mark[2], encoding)

  -- El final del rango LSP es exclusivo: la marca '> apunta al último carácter
  -- seleccionado, así que (salvo con 'selection' = "exclusive") hay que sumarle
  -- uno.
  if vim.o.selection ~= "exclusive" then
    end_char = end_char + 1
  end

  return {
    start = { line = start_mark[1] - 1, character = start_char },
    ["end"] = { line = end_mark[1] - 1, character = end_char },
  }
end

--- Calcula el rango principal de una petición (según el ámbito).
---@param ctx KatanaContext
---@param encoding KatanaEncoding
---@return lsp.Range
function M.for_context(ctx, encoding)
  if ctx.scope == "visual" then
    return M.visual(ctx.bufnr, ctx.win, encoding)
      or vim.lsp.util.make_given_range_params(nil, nil, ctx.bufnr, encoding).range
  end

  if ctx.scope == "line" then
    local row = ctx.cursor.row
    local text = vim.api.nvim_buf_get_lines(ctx.bufnr, row, row + 1, false)[1] or ""
    return {
      start = { line = row, character = 0 },
      ["end"] = { line = row, character = #text },
    }
  end

  return vim.lsp.util.make_range_params(ctx.win, encoding).range
end

--- ¿Es un carácter válido de identificador?
---@param ch string
---@return boolean
local function is_word_char(ch)
  return ch ~= "" and ch:match("[%w_]") ~= nil
end

--- Devuelve el rango (en bytes) de la palabra bajo una posición.
---
--- Los servidores que enlazan sus *code actions* a un token concreto (Roslyn con
--- "Generar método", por ejemplo) sólo las ofrecen si el rango pedido corta ese
--- token. Con el rango del cursor (de ancho cero) eso sólo ocurre si el cursor
--- cae exactamente sobre el identificador, así que se ensancha al identificador.
---
--- Si el cursor no está sobre un identificador pero justo detrás de uno, se
--- toma ese identificador (igual que hace el editor al pulsar `cw`).
---@param bufnr integer
---@param row integer fila (0-based)
---@param col integer columna en bytes (0-based)
---@return integer|nil start_col byte inicial
---@return integer|nil stop_col byte final (excluido)
function M.word(bufnr, row, col)
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, row, row + 1, false)
  if not ok then
    return nil, nil
  end

  local line = lines and lines[1] or ""
  if line == "" then
    return nil, nil
  end

  --- Carácter en un offset de byte (0-based).
  ---@param offset integer
  ---@return string
  local function char_at(offset)
    if offset < 0 or offset >= #line then
      return ""
    end
    return line:sub(offset + 1, offset + 1)
  end

  local start_col, stop_col

  if is_word_char(char_at(col)) then
    start_col, stop_col = col, col + 1
  elseif col > 0 and is_word_char(char_at(col - 1)) then
    start_col, stop_col = col - 1, col
  else
    return nil, nil
  end

  while start_col > 0 and is_word_char(char_at(start_col - 1)) do
    start_col = start_col - 1
  end

  while stop_col < #line and is_word_char(char_at(stop_col)) do
    stop_col = stop_col + 1
  end

  if start_col >= stop_col then
    return nil, nil
  end

  return start_col, stop_col
end

--- Devuelve el rango que cubre todos los diagnósticos indicados.
---@param diagnostics lsp.Diagnostic[]
---@return lsp.Range|nil
function M.union(diagnostics)
  local start_line, start_char, stop_line, stop_char

  for _, diagnostic in ipairs(optional.value(diagnostics) or {}) do
    local range = diagnostic and diagnostic.range
    if range and range.start and range["end"] then
      local s_line = range.start.line or 0
      local e_line = range["end"].line or s_line
      local s_char = range.start.character or 0
      local e_char = range["end"].character or 0

      if start_line == nil then
        start_line, start_char, stop_line, stop_char = s_line, s_char, e_line, e_char
      else
        if s_line < start_line or (s_line == start_line and s_char < start_char) then
          start_line, start_char = s_line, s_char
        end
        if e_line > stop_line or (e_line == stop_line and e_char > stop_char) then
          stop_line, stop_char = e_line, e_char
        end
      end
    end
  end

  if start_line == nil then
    return nil
  end

  return {
    start = { line = start_line, character = start_char },
    ["end"] = { line = stop_line, character = stop_char },
  }
end

--- Calcula el rango completo de una línea del buffer.
---@param bufnr integer
---@param row integer fila (0-based)
---@param encoding KatanaEncoding
---@return lsp.Range
function M.line(bufnr, row, encoding)
  local text = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  return {
    start = { line = row, character = 0 },
    ["end"] = { line = row, character = encoding_module.byte_to_char(text, #text, encoding) },
  }
end

--- Compara dos rangos LSP.
---@param a lsp.Range|nil
---@param b lsp.Range|nil
---@return boolean
function M.ranges_equal(a, b)
  if not a or not b then
    return a == b
  end

  return a.start.line == b.start.line
    and a.start.character == b.start.character
    and a["end"].line == b["end"].line
    and a["end"].character == b["end"].character
end

--- Filtra los diagnósticos que caen en una fila.
---@param diagnostics lsp.Diagnostic[]|nil
---@param row integer fila (0-based)
---@return lsp.Diagnostic[]
function M.diagnostics_on_row(diagnostics, row)
  local result = {}

  for _, diagnostic in ipairs(optional.value(diagnostics) or {}) do
    local range = diagnostic and diagnostic.range
    if range and range.start then
      local start_line = range.start.line or 0
      local end_line = range["end"] and range["end"].line or start_line
      if start_line <= row and end_line >= row then
        result[#result + 1] = diagnostic
      end
    end
  end

  return result
end

return M
