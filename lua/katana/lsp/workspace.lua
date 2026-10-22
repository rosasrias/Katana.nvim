---@mod katana.lsp.workspace WorkspaceEdit, conversiones de codificación y diffs
---
--- Este módulo concentra todo el conocimiento "de bajo nivel" relacionado con el
--- protocolo LSP: conversión de posiciones (utf-8 / utf-16 / utf-32), aplicación
--- de `TextEdit` sobre buffers, cierre del bloque de undo y generación del diff
--- para la previsualización.
---
--- Nota sobre las conversiones: `vim.str_byteindex` cambió de firma entre
--- Neovim 0.10 (`s, index, use_utf16`) y 0.11/0.12 (`s, encoding, index, strict`).
--- Para no depender de una versión concreta se implementa la conversión a mano,
--- que funciona igual en todo el rango soportado (>= 0.10).

local M = {}

---@alias KatanaEncoding '"utf-8"'|'"utf-16"'|'"utf-32"'

--------------------------------------------------------------------------------
-- Conversión de posiciones
--------------------------------------------------------------------------------

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

--------------------------------------------------------------------------------
-- WorkspaceEdit
--------------------------------------------------------------------------------

---@class KatanaEditGroup
---@field uri string
---@field filename string
---@field edits lsp.TextEdit[]

--- Normaliza un `WorkspaceEdit` en grupos por fichero.
---@param edit vim.lsp.WorkspaceEdit|nil
---@return KatanaEditGroup[]
function M.collect_edits(edit)
  local groups = {}

  if type(edit) ~= "table" then
    return groups
  end

  local function push(uri, edits)
    if type(uri) ~= "string" or type(edits) ~= "table" or #edits == 0 then
      return
    end
    table.insert(groups, {
      uri = uri,
      filename = vim.uri_to_fname(uri),
      edits = edits,
    })
  end

  -- LSP 3.16 y anteriores.
  for uri, edits in pairs(edit.changes or {}) do
    push(uri, edits)
  end

  -- LSP 3.17 (`documentChanges`): sólo interesan los `TextDocumentEdit`.
  for _, change in ipairs(edit.documentChanges or {}) do
    if type(change) == "table" and change.textDocument and change.edits then
      push(change.textDocument.uri, change.edits)
    end
  end

  return groups
end

--- Resuelve el buffer asociado a un grupo de ediciones.
---@param group KatanaEditGroup
---@param bufnr integer|nil buffer actual (se reutiliza si el fichero coincide)
---@return integer|nil
function M.resolve_buf(group, bufnr)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name ~= "" and vim.fs.normalize(name) == vim.fs.normalize(group.filename) then
      return bufnr
    end
  end

  local existing = vim.fn.bufnr(group.filename)
  if existing > 0 and vim.api.nvim_buf_is_valid(existing) then
    return existing
  end

  -- `bufadd` + `bufload` carga el fichero sin robar la ventana actual.
  local loaded = vim.fn.bufadd(group.filename)
  if loaded > 0 and vim.fn.bufloaded(loaded) == 0 then
    vim.fn.bufload(loaded)
  end

  if loaded > 0 and vim.api.nvim_buf_is_valid(loaded) then
    return loaded
  end

  return nil
end

---@param edits lsp.TextEdit[]
---@return lsp.TextEdit[]
local function sorted_edits(edits)
  local sorted = vim.deepcopy(edits or {})

  -- Se aplican de abajo arriba para que las posiciones de los edits anteriores
  -- sigan siendo válidas.
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

    local start_col = M.char_to_byte(start_text, start.character or 0, encoding)
    local stop_col = M.char_to_byte(stop_text, stop.character or 0, encoding)

    local replacement = vim.split(edit.newText or "", "\n", { plain = true })

    -- Sustituye las líneas [start_line, stop_line] (0-based) por `replacement`.
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
function M.apply_edits_to_buffer(bufnr, edits, encoding)
  for _, edit in ipairs(sorted_edits(edits)) do
    local range = edit.range or {}
    local start = range.start or { line = 0, character = 0 }
    local stop = range["end"] or start

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local start_line = start.line or 0
    local stop_line = stop.line or start_line

    local start_text = lines[start_line + 1] or ""
    local stop_text = lines[stop_line + 1] or start_text

    local start_col = M.char_to_byte(start_text, start.character or 0, encoding)
    local stop_col = M.char_to_byte(stop_text, stop.character or 0, encoding)

    local replacement = vim.split(edit.newText or "", "\n", { plain = true })

    vim.api.nvim_buf_set_text(bufnr, start_line, start_col, stop_line, stop_col, replacement)
  end
end

--------------------------------------------------------------------------------
-- Undo agrupado
--------------------------------------------------------------------------------

--- Cierra el bloque de undo actual del buffer.
---
--- Neovim fusiona en un mismo bloque de undo cualquier cambio hecho por API que no
--- esté precedido de un comando en modo normal. Reasignar `undolevels` (incluso al
--- mismo valor) cierra el bloque previo, de modo que los cambios de la acción se
--- deshacen con un único `u` sin arrastrar la edición previa del usuario.
---
--- Referencia: `:help undo-break` ("Setting the value of 'undolevels' also closes
--- the undo block.  Even when the new value is equal to the old value.").
---@param bufnr integer
---@return boolean ok
function M.close_undo_block(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  return pcall(function()
    local levels = vim.bo[bufnr].undolevels
    -- `-1` desactivaría el undo por completo: nunca lo tocamos. El valor por
    -- defecto (`-1000` = ilimitado) sí se puede reasignar.
    if levels and levels ~= -1 then
      vim.bo[bufnr].undolevels = levels
    end
  end)
end

--------------------------------------------------------------------------------
-- Diff
--------------------------------------------------------------------------------

--- Genera un diff unificado entre `before` y `after`.
---
--- `vim.diff` no incluye las cabeceras `--- a/fichero` / `+++ b/fichero`, así que
--- se añaden manualmente para que el buffer de previsualización (`filetype=diff`)
--- los coloree como corresponde.
---@param before string[]
---@param after string[]
---@param filename string
---@return string
function M.unified_diff(before, after, filename)
  -- Neovim no incluye el salto final en `nvim_buf_get_lines`, pero el fichero sí
  -- suele acabarlo: se añade para que el diff no muestre
  -- "\ No newline at end of file" de forma engañosa.
  local before_text = table.concat(before, "\n") .. "\n"
  local after_text = table.concat(after, "\n") .. "\n"

  local diff = vim.diff(before_text, after_text, { result_type = "unified", ctxlen = 3 })
  if diff == "" then
    return ""
  end

  return string.format("--- a/%s\n+++ b/%s\n%s", filename, filename, diff)
end

--- Ejecuta una herramienta externa de diff sobre dos ficheros temporales.
---@param before string[]
---@param after string[]
---@param backend '"delta"'|'"difftastic"'
---@return string|nil diff `nil` si la herramienta no está disponible
function M.external_diff(before, after, backend)
  local commands = {
    delta = { "delta", "--paging=never", "--color=never" },
    difftastic = { "difftastic", "--color=never", "--output=short" },
  }

  local base = commands[backend]
  if not base then
    return nil
  end

  local before_file = vim.fn.tempname()
  local after_file = vim.fn.tempname()

  vim.fn.writefile(before, before_file)
  vim.fn.writefile(after, after_file)

  local cmd = vim.list_extend(vim.deepcopy(base), { before_file, after_file })

  local ok, output = pcall(function()
    if vim.system then
      local result = vim.system(cmd, { text = true }):wait()
      if result.code ~= 0 then
        return nil
      end
      return result.stdout
    end
    local out = vim.fn.system(cmd)
    if vim.v.shell_error ~= 0 then
      return nil
    end
    return out
  end)

  pcall(vim.fn.delete, before_file)
  pcall(vim.fn.delete, after_file)

  if not ok or not output or output == "" then
    return nil
  end

  return output
end

--- Calcula el diff de un `WorkspaceEdit` para la previsualización.
---@param edit vim.lsp.WorkspaceEdit|nil
---@param bufnr integer|nil buffer actual
---@param encoding KatanaEncoding
---@param backend '"vim"'|'"delta"'|'"difftastic"'
---@return string[]
function M.preview_lines(edit, bufnr, encoding, backend)
  backend = backend or "vim"

  local groups = M.collect_edits(edit)
  local output = {}

  for _, group in ipairs(groups) do
    local target = M.resolve_buf(group, bufnr)
    if target and vim.fn.bufloaded(target) == 1 then
      local before = vim.api.nvim_buf_get_lines(target, 0, -1, false)
      local after = M.apply_to_lines(before, group.edits, encoding)

      local text
      if backend == "vim" then
        text = M.unified_diff(before, after, group.filename)
      else
        text = M.external_diff(before, after, backend)
        if not text then
          -- La herramienta externa no está disponible: fallback al diff interno.
          text = M.unified_diff(before, after, group.filename)
        end
      end

      if text and text ~= "" then
        vim.list_extend(output, vim.split(text, "\n", { plain = true }))
      end
    end
  end

  if #output == 0 then
    output = { "(no changes)" }
  end

  return output
end

return M
