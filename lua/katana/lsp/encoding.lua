---@mod katana.lsp.encoding Conversión de posiciones LSP
---
--- `vim.str_byteindex` cambió de firma entre Neovim 0.10 (`s, index,
--- use_utf16`) y 0.11/0.12 (`s, encoding, index, strict`). Para no depender de
--- una versión concreta se implementa la conversión a mano, que funciona igual
--- en todo el rango soportado (>= 0.10).

local M = {}

---@alias KatanaEncoding '"utf-8"'|'"utf-16"'|'"utf-32"'

--- Número de bytes que ocupa el carácter UTF-8 que empieza en el byte `b`.
---@param b integer
---@return integer
local function utf8_len(b)
  if b >= 0xf0 then
    return 4
  elseif b >= 0xe0 then
    return 3
  elseif b >= 0xc0 then
    return 2
  end
  return 1
end

--- Convierte un índice de byte a un índice de carácter en la codificación dada.
---@param line string
---@param byte_idx integer índice de byte (0-based)
---@param encoding KatanaEncoding
---@return integer índice de carácter (0-based)
function M.byte_to_char(line, byte_idx, encoding)
  if encoding == "utf-8" then
    return byte_idx
  end

  if byte_idx <= 0 then
    return 0
  end

  local units = 0
  local i = 1
  local len = #line

  while i <= len and i <= byte_idx do
    local size = utf8_len(line:byte(i))
    -- En utf-16 un carácter astral ocupa dos unidades (surrogate pair).
    if encoding == "utf-16" and size == 4 then
      units = units + 2
    else
      units = units + 1
    end
    i = i + size
  end

  return units
end

--- Convierte un índice de carácter (en la codificación dada) a índice de byte.
---@param line string
---@param char_idx integer índice de carácter (0-based)
---@param encoding KatanaEncoding
---@return integer índice de byte (0-based)
function M.char_to_byte(line, char_idx, encoding)
  if encoding == "utf-8" then
    return char_idx
  end

  if char_idx <= 0 then
    return 0
  end

  local units = 0
  local i = 1
  local len = #line

  while i <= len and units < char_idx do
    local size = utf8_len(line:byte(i))
    local cost = 1
    if encoding == "utf-16" and size == 4 then
      cost = 2
    end

    -- El índice cae dentro de un surrogate pair: se recorta al inicio del carácter.
    if units + cost > char_idx then
      return i - 1
    end

    units = units + cost
    i = i + size
  end

  return i - 1
end

return M
