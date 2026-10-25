---@mod katana.lsp.edit_validation Validación de TextEdit
---
--- Valida forma de rangos, límites del buffer y solapamientos antes de escribir
--- nada. No aplica ediciones ni conoce el executor.

local optional = require("katana.core.optional")
local encoding_module = require("katana.lsp.encoding")

local M = {}

---@param range any
---@return boolean ok
---@return string|nil error
local function validate_range_shape(range)
  if type(range) ~= "table" then
    return false, "edición sin rango"
  end

  local start = range.start
  local stop = range["end"]
  if type(start) ~= "table" or type(stop) ~= "table" then
    return false, "rango sin start/end"
  end

  for _, position in ipairs({ start, stop }) do
    if type(position.line) ~= "number" or position.line < 0 or position.line % 1 ~= 0 then
      return false, "línea de rango inválida"
    end
    if type(position.character) ~= "number" or position.character < 0 or position.character % 1 ~= 0 then
      return false, "columna de rango inválida"
    end
  end

  if start.line > stop.line or (start.line == stop.line and start.character > stop.character) then
    return false, "el rango termina antes de empezar"
  end

  return true
end

---@param a lsp.Position
---@param b lsp.Position
---@return boolean
local function position_before(a, b)
  return a.line < b.line or (a.line == b.line and a.character < b.character)
end

--- Valida una lista de ediciones contra las líneas actuales del buffer.
---@param edits any
---@param lines string[]
---@param encoding KatanaEncoding
---@return lsp.TextEdit[]|nil
---@return string|nil
function M.validate_list(edits, lines, encoding)
  if type(edits) ~= "table" then
    return nil, "las ediciones no son una lista"
  end

  if #edits == 0 then
    return nil, "grupo sin ediciones"
  end

  local line_count = #lines
  local result = {}

  for index, text_edit in ipairs(edits) do
    if type(text_edit) ~= "table" then
      return nil, string.format("edición %d inválida", index)
    end

    local range_ok, range_err = validate_range_shape(text_edit.range)
    if not range_ok then
      return nil, string.format("edición %d: %s", index, range_err)
    end

    local start = text_edit.range.start
    local stop = text_edit.range["end"]
    if start.line >= line_count or stop.line >= line_count then
      return nil, string.format(
        "edición %d fuera del buffer (línea %d..%d, buffer de %d líneas)",
        index,
        start.line,
        stop.line,
        line_count
      )
    end

    -- Una columna más allá del final de la línea no es una posición válida.
    -- `char_to_byte` recorta, así que sin esta comprobación una edición
    -- corrupta se aplicaría en el sitio equivocado (el final de la línea).
    local start_text = lines[start.line + 1] or ""
    local stop_text = lines[stop.line + 1] or ""
    local start_len = encoding_module.byte_to_char(start_text, #start_text, encoding)
    local stop_len = encoding_module.byte_to_char(stop_text, #stop_text, encoding)
    if start.character > start_len then
      return nil, string.format(
        "edición %d: columna inicial %d fuera de la línea %d (longitud %d)",
        index,
        start.character,
        start.line,
        start_len
      )
    end
    if stop.character > stop_len then
      return nil, string.format(
        "edición %d: columna final %d fuera de la línea %d (longitud %d)",
        index,
        stop.character,
        stop.line,
        stop_len
      )
    end

    local new_text = optional.value(text_edit.newText)
    if new_text == nil then
      new_text = ""
    elseif type(new_text) ~= "string" then
      return nil, string.format("edición %d: newText no es una cadena", index)
    end

    result[#result + 1] = {
      range = {
        start = { line = start.line, character = start.character },
        ["end"] = { line = stop.line, character = stop.character },
      },
      newText = new_text,
    }
  end

  -- Comprueba solapamientos (el orden de llegada no está garantizado). No basta
  -- con comparar con la edición anterior ordenada por inicio: una edición larga
  -- puede contener a varias cortas, así que se guarda el final máximo visto.
  local ordered = vim.deepcopy(result)
  table.sort(ordered, function(a, b)
    if a.range.start.line ~= b.range.start.line then
      return a.range.start.line < b.range.start.line
    end
    return a.range.start.character < b.range.start.character
  end)

  local starts = {}
  local max_end = nil
  local max_end_index = nil

  for i, current in ipairs(ordered) do
    local current_start = current.range.start
    local key = string.format("%d:%d", current_start.line, current_start.character)

    -- Dos ediciones que empiezan en el mismo punto tienen un orden ambiguo
    -- (aunque sean dos inserciones de ancho cero): se rechazan.
    if starts[key] then
      return nil, string.format(
        "las ediciones %d y %d empiezan en el mismo punto %d:%d",
        starts[key],
        i,
        current_start.line,
        current_start.character
      )
    end
    starts[key] = i

    if max_end and position_before(current_start, max_end) then
      return nil, string.format(
        "las ediciones %d y %d se solapan en %d:%d",
        max_end_index,
        i,
        current_start.line,
        current_start.character
      )
    end

    local current_end = current.range["end"]
    if not max_end or position_before(max_end, current_end) then
      max_end = current_end
      max_end_index = i
    end
  end

  return result, nil
end

return M
