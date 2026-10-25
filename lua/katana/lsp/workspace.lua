---@mod katana.lsp.workspace WorkspaceEdit, conversiones de codificación y diffs
---
--- Este módulo concentra todo el conocimiento "de bajo nivel" relacionado con el
--- protocolo LSP: conversión de posiciones (utf-8 / utf-16 / utf-32), preparación
--- y aplicación de `TextEdit` sobre buffers, cierre del bloque de undo y
--- generación del diff para la previsualización.
---
--- La aplicación de un `WorkspaceEdit` se divide en dos fases:
---
---   1. `prepare_edit` valida el documento completo (URIs, buffers, versiones y
---      rangos) **sin escribir nada** y devuelve un plan.
---   2. `apply_plan` ejecuta el plan. Si un recurso falla a mitad, intenta
---      revertir los buffers ya modificados sólo cuando su `changedtick` sigue
---      siendo el que dejó la propia operación (es decir, nadie más los tocó).
---
--- Esto no es una transacción: no se promete atomicidad entre ficheros. Lo que
--- se garantiza es que los errores detectables antes de escribir no dejan
--- cambios parciales, y que los fallos inesperados se diagnostican e intentan
--- revertir de forma segura.
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
-- URIs
--------------------------------------------------------------------------------

--- Convierte una URI LSP en una ruta local.
---
--- Sólo se aceptan URIs `file:`: una URI `untitled:`, `jdt:` o similar no
--- identifica un fichero editable y no debe acabar creando un buffer con un
--- nombre inventado.
---@param uri string|nil
---@return string|nil filename
---@return string|nil error
function M.uri_to_path(uri)
  if type(uri) ~= "string" or uri == "" then
    return nil, "URI vacía en el WorkspaceEdit"
  end

  local scheme = uri:match("^([%w+.-]+):")
  if scheme ~= "file" then
    return nil, string.format("URI no soportada (esquema '%s'): %s", tostring(scheme or "?"), uri)
  end

  local ok, filename = pcall(vim.uri_to_fname, uri)
  if not ok or type(filename) ~= "string" or filename == "" then
    return nil, "no se pudo convertir la URI en una ruta: " .. uri
  end

  return filename
end

---@param path string
---@return string
local function normalized_path(path)
  local ok, normalized = pcall(vim.fs.normalize, path)
  return ok and normalized or path
end

---@param path string
---@return boolean
local function is_readable_file(path)
  if type(path) ~= "string" or path == "" then
    return false
  end
  return vim.fn.filereadable(path) == 1
end

--------------------------------------------------------------------------------
-- WorkspaceEdit: extracción y validación estructural
--------------------------------------------------------------------------------

---@class KatanaEditEntry
---@field uri string
---@field edits lsp.TextEdit[]
---@field version integer|nil

---@class KatanaEditGroup
---@field uri string
---@field filename string
---@field edits lsp.TextEdit[]
---@field version integer|nil

-- Las operaciones de recurso (`CreateFile`, `RenameFile`, `DeleteFile`) no se
-- aplican: cambiar el sistema de ficheros queda fuera del alcance del executor y
-- aplicarlas a medias sería peor que rechazar la edición completa.
local RESOURCE_OPERATIONS = {
  create = true,
  rename = true,
  delete = true,
}

--- Normaliza un array de `TextEdit` (acepta un único `TextEdit` por tolerancia).
---@param edits any
---@return table[]|nil
---@return string|nil
local function as_edit_list(edits)
  if type(edits) ~= "table" then
    return nil, "las ediciones no son una lista"
  end

  if edits.range ~= nil then
    return { edits }, nil
  end

  return edits, nil
end

--- Extrae y valida las entradas de un `WorkspaceEdit`, sin tocar buffers.
---
--- `documentChanges` tiene prioridad sobre `changes` (LSP 3.16+): si está
--- presente no se procesa también `changes`, porque muchos servidores envían
--- ambos con el mismo contenido y aplicarlo dos veces duplicaría la edición.
--- Varias entradas para la misma URI se fusionan en orden.
---@param edit vim.lsp.WorkspaceEdit|nil
---@return KatanaEditEntry[]
---@return string|nil error
function M.extract_edits(edit)
  if type(edit) ~= "table" then
    return {}, "WorkspaceEdit inválido"
  end

  local entries = {}

  if edit.documentChanges ~= nil then
    if type(edit.documentChanges) ~= "table" then
      return {}, "documentChanges no es una lista"
    end

    for index, change in ipairs(edit.documentChanges) do
      if type(change) ~= "table" then
        return {}, string.format("documentChanges[%d] no es una tabla", index)
      end

      if change.kind ~= nil then
        local kind = tostring(change.kind)
        if RESOURCE_OPERATIONS[kind] or kind == "createFile" or kind == "renameFile" or kind == "deleteFile" then
          return {}, string.format(
            "la operación de recurso '%s' no está soportada (no se modifica el sistema de ficheros)",
            kind
          )
        end
        return {}, string.format("documentChanges[%d] tiene un 'kind' desconocido: %s", index, kind)
      end

      local text_document = change.textDocument
      if type(text_document) ~= "table" then
        return {}, string.format("documentChanges[%d] no incluye textDocument", index)
      end

      local edits, err = as_edit_list(change.edits)
      if not edits then
        return {}, string.format("documentChanges[%d]: %s", index, tostring(err))
      end

      local version = text_document.version
      if version ~= nil and (type(version) ~= "number" or version < 0 or version % 1 ~= 0) then
        return {}, string.format("documentChanges[%d] tiene una versión inválida: %s", index, tostring(version))
      end

      entries[#entries + 1] = {
        uri = text_document.uri,
        edits = edits,
        version = version,
      }
    end
  elseif edit.changes ~= nil then
    if type(edit.changes) ~= "table" then
      return {}, "changes no es una tabla"
    end

    -- `pairs` no tiene orden garantizado; se ordena por URI para que la
    -- preparación y los mensajes de error sean deterministas.
    local uris = {}
    for uri in pairs(edit.changes) do
      uris[#uris + 1] = uri
    end
    table.sort(uris, function(a, b)
      return tostring(a) < tostring(b)
    end)

    for _, uri in ipairs(uris) do
      local edits, err = as_edit_list(edit.changes[uri])
      if not edits then
        return {}, string.format("changes[%s]: %s", tostring(uri), tostring(err))
      end

      entries[#entries + 1] = {
        uri = uri,
        edits = edits,
        version = nil,
      }
    end
  end

  -- Fusiona entradas de la misma URI conservando el orden de llegada.
  local merged = {}
  local by_uri = {}

  for _, entry in ipairs(entries) do
    if type(entry.uri) ~= "string" or entry.uri == "" then
      return {}, "entrada del WorkspaceEdit sin URI"
    end

    local previous = by_uri[entry.uri]
    if previous then
      if previous.version ~= nil and entry.version ~= nil and previous.version ~= entry.version then
        return {}, string.format("versiones incompatibles para %s en el WorkspaceEdit", entry.uri)
      end
      if previous.version == nil then
        previous.version = entry.version
      end
      for _, text_edit in ipairs(entry.edits) do
        previous.edits[#previous.edits + 1] = text_edit
      end
    else
      local copied = {
        uri = entry.uri,
        version = entry.version,
        edits = {},
      }
      for _, text_edit in ipairs(entry.edits) do
        copied.edits[#copied.edits + 1] = text_edit
      end
      by_uri[entry.uri] = copied
      merged[#merged + 1] = copied
    end
  end

  return merged, nil
end

--- Versión LSP conocida del buffer (la última que Neovim envió al servidor).
---@param bufnr integer
---@return integer|nil
function M.buffer_version(bufnr)
  local util = vim.lsp.util
  local versions = util and util.buf_versions
  if type(versions) ~= "table" then
    return nil
  end

  local version = versions[bufnr]
  if type(version) == "number" and version >= 0 then
    return version
  end

  return nil
end

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

---@param edits any
---@param lines string[]
---@param encoding KatanaEncoding
---@return lsp.TextEdit[]|nil
---@return string|nil
local function validate_edit_list(edits, lines, encoding)
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
    local start_len = M.byte_to_char(lines[start.line + 1] or "", #(lines[start.line + 1] or ""), encoding)
    local stop_len = M.byte_to_char(lines[stop.line + 1] or "", #(lines[stop.line + 1] or ""), encoding)
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

    local new_text = text_edit.newText
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

--- Normaliza un `WorkspaceEdit` en grupos por fichero.
---
--- Es la versión tolerante usada por el preview: las URIs no `file:` se omiten
--- en lugar de hacer fallar toda la previsualización.
---@param edit vim.lsp.WorkspaceEdit|nil
---@return KatanaEditGroup[]
function M.collect_edits(edit)
  local entries = M.extract_edits(edit)
  local groups = {}

  for _, entry in ipairs(entries) do
    local filename = M.uri_to_path(entry.uri)
    if filename then
      groups[#groups + 1] = {
        uri = entry.uri,
        filename = filename,
        edits = entry.edits,
        version = entry.version,
      }
    end
  end

  return groups
end

--------------------------------------------------------------------------------
-- Buffers
--------------------------------------------------------------------------------

--- Busca el buffer de un grupo sin crear ni cargar ficheros.
---@param group KatanaEditGroup
---@param bufnr integer|nil buffer de origen
---@return integer|nil
function M.find_buf(group, bufnr)
  if type(group.filename) ~= "string" or group.filename == "" then
    return nil
  end

  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name ~= "" and normalized_path(name) == normalized_path(group.filename) then
      return bufnr
    end
  end

  local existing = vim.fn.bufnr(group.filename)
  if existing > 0 and vim.api.nvim_buf_is_valid(existing) and vim.api.nvim_buf_is_loaded(existing) then
    return existing
  end

  return nil
end

--- Resuelve (y si hace falta carga) el buffer asociado a un grupo de ediciones.
---
--- Sólo se crean buffers para ficheros que existen en disco: un WorkspaceEdit
--- no se usa aquí para inventar ficheros nuevos.
---@param group KatanaEditGroup
---@param bufnr integer|nil buffer actual (se reutiliza si el fichero coincide)
---@return integer|nil
---@return string|nil error
function M.resolve_buf(group, bufnr)
  local existing = M.find_buf(group, bufnr)
  if existing then
    return existing
  end

  if not is_readable_file(group.filename) then
    return nil, string.format("el fichero destino no existe o no es legible: %s", tostring(group.filename))
  end

  local ok_add, loaded = pcall(vim.fn.bufadd, group.filename)
  if not ok_add or type(loaded) ~= "number" or loaded <= 0 then
    return nil, string.format("no se pudo crear el buffer para %s", group.filename)
  end

  if vim.fn.bufloaded(loaded) == 0 then
    local ok_load = pcall(vim.fn.bufload, loaded)
    if not ok_load then
      return nil, string.format("no se pudo cargar el buffer para %s", group.filename)
    end
  end

  if vim.api.nvim_buf_is_valid(loaded) and vim.fn.bufloaded(loaded) == 1 then
    return loaded
  end

  return nil, string.format("el buffer de %s no quedó cargado", group.filename)
end

---@param target integer
---@return string|nil
local function validate_target_buffer(target)
  if not vim.api.nvim_buf_is_valid(target) then
    return "el buffer destino no es válido"
  end

  if vim.fn.bufloaded(target) ~= 1 then
    return "el buffer destino no está cargado"
  end

  local buftype = vim.bo[target].buftype
  if buftype ~= "" then
    return string.format("el buffer destino no es un fichero editable (buftype=%s)", buftype)
  end

  return nil
end

--------------------------------------------------------------------------------
-- Preparación y aplicación
--------------------------------------------------------------------------------

---@class KatanaPreparedGroup
---@field uri string
---@field filename string
---@field bufnr integer
---@field edits lsp.TextEdit[]
---@field version integer|nil
---@field lines string[] copia de las líneas antes de aplicar
---@field encoding KatanaEncoding codificación de posiciones del cliente
---@field changedtick integer
---@field post_tick integer|nil

---@class KatanaEditPlan
---@field groups KatanaPreparedGroup[]
---@field encoding KatanaEncoding
---@field applied boolean

--- Prepara un `WorkspaceEdit` para aplicarlo.
---
--- Valida URIs, ficheros, buffers, versiones de documento y rangos de todas las
--- ediciones antes de escribir en el primer buffer.
---@param edit vim.lsp.WorkspaceEdit|nil
---@param bufnr integer|nil buffer de origen
---@param encoding KatanaEncoding|nil codificación de posiciones (por defecto utf-16)
---@return KatanaEditPlan|nil plan
---@return string|nil error
function M.prepare_edit(edit, bufnr, encoding)
  if type(edit) ~= "table" then
    return nil, "WorkspaceEdit inválido"
  end

  encoding = encoding or "utf-16"

  local entries, extract_err = M.extract_edits(edit)
  if extract_err then
    return nil, extract_err
  end

  if #entries == 0 then
    return nil, "el WorkspaceEdit no contiene cambios aplicables"
  end

  local plan = { groups = {}, encoding = encoding, applied = false }

  for _, entry in ipairs(entries) do
    if #entry.edits == 0 then
      goto continue
    end

    local filename, uri_err = M.uri_to_path(entry.uri)
    if not filename then
      return nil, uri_err
    end

    local group = {
      uri = entry.uri,
      filename = filename,
      edits = entry.edits,
      version = entry.version,
    }

    local target, target_err = M.resolve_buf(group, bufnr)
    if not target then
      return nil, target_err or ("no se pudo resolver el buffer destino de " .. filename)
    end

    local buffer_err = validate_target_buffer(target)
    if buffer_err then
      return nil, string.format("%s (%s)", buffer_err, filename)
    end

    if entry.version ~= nil then
      local current_version = M.buffer_version(target)
      if current_version ~= nil and current_version ~= entry.version then
        return nil, string.format(
          "versión incompatible para %s (edición=%d, buffer=%d); la edición quedó obsoleta",
          filename,
          entry.version,
          current_version
        )
      end
    end

    local lines = vim.api.nvim_buf_get_lines(target, 0, -1, false)
    local validated, range_err = validate_edit_list(entry.edits, lines, encoding)
    if not validated then
      return nil, string.format("%s: %s", filename, range_err)
    end

    plan.groups[#plan.groups + 1] = {
      uri = entry.uri,
      filename = filename,
      bufnr = target,
      edits = validated,
      version = entry.version,
      lines = lines,
      encoding = encoding,
      changedtick = vim.api.nvim_buf_get_changedtick(target),
      post_tick = nil,
    }

    ::continue::
  end

  if #plan.groups == 0 then
    return nil, "el WorkspaceEdit no contiene cambios aplicables"
  end

  return plan, nil
end

---@param lines_a string[]
---@param lines_b string[]
---@return boolean
local function lines_equal(lines_a, lines_b)
  if #lines_a ~= #lines_b then
    return false
  end
  for i = 1, #lines_a do
    if lines_a[i] ~= lines_b[i] then
      return false
    end
  end
  return true
end

--- Intenta revertir un grupo aplicado.
---
--- Sólo se revierte si el buffer sigue exactamente en el `changedtick` que dejó
--- la operación. Si el usuario (o otro plugin) lo modificó, se conserva su
--- cambio y se informa de que no se pudo revertir.
---@param group KatanaPreparedGroup
---@return boolean restored
---@return string method
---@return string|nil error
local function rollback_group(group)
  if not vim.api.nvim_buf_is_valid(group.bufnr) then
    return false, "none", "el buffer ya no es válido"
  end

  local tick = vim.api.nvim_buf_get_changedtick(group.bufnr)
  if group.post_tick == nil or tick ~= group.post_tick then
    return false, "none", "el buffer cambió después de la edición; no se revierte para no pisar cambios concurrentes"
  end

  -- Preferimos `undo` porque revierte también metadatos (marks, undo tree) de
  -- forma coherente. Si no deja el contenido esperado, se usa el snapshot de
  -- líneas como respaldo. La reversión no es transaccional entre ficheros: sólo
  -- se intenta y se verifica buffer a buffer.
  local levels = vim.bo[group.bufnr].undolevels
  if levels ~= -1 then
    local ok_undo = pcall(vim.api.nvim_buf_call, group.bufnr, function()
      vim.cmd("silent undo")
    end)
    local current = vim.api.nvim_buf_get_lines(group.bufnr, 0, -1, false)
    if ok_undo and lines_equal(current, group.lines) then
      return true, "undo", nil
    end
  end

  -- El `undo` pudo cambiar el `changedtick` (es un cambio más). No se usa como
  -- condición: el tick ya se comprobó al entrar, así que cualquier cambio desde
  -- entonces lo ha hecho esta misma reversión.
  local ok_restore = pcall(vim.api.nvim_buf_set_lines, group.bufnr, 0, -1, false, group.lines)
  if not ok_restore then
    return false, "none", "no se pudo restaurar el contenido anterior"
  end

  if lines_equal(vim.api.nvim_buf_get_lines(group.bufnr, 0, -1, false), group.lines) then
    return true, "snapshot", nil
  end

  return false, "none", "la restauración no se pudo verificar"
end

---@class KatanaApplyInfo
---@field applied_buffers string[]
---@field failed_buffer string|nil
---@field rollback '"not_needed"'|'"restored"'|'"failed"'
---@field rollback_details string[]

--- Aplica un plan preparado.
---
--- No es una transacción entre ficheros. Si falla un grupo, intenta revertir los
--- grupos ya aplicados y devuelve información verificable sobre lo ocurrido.
---@param plan KatanaEditPlan
---@return boolean ok
---@return string|nil error
---@return KatanaApplyInfo info
function M.apply_plan(plan)
  local info = {
    applied_buffers = {},
    failed_buffer = nil,
    rollback = "not_needed",
    rollback_details = {},
  }

  if type(plan) ~= "table" or type(plan.groups) ~= "table" or #plan.groups == 0 then
    return false, "plan de edición inválido", info
  end

  if plan.applied then
    return false, "el plan de edición ya se aplicó (se evita duplicarlo)", info
  end

  plan.applied = true

  local applied = {}

  local function fail(message, group)
    info.failed_buffer = group and group.filename or nil
    info.rollback = "failed"

    local rolled_back = 0
    local attempted = 0

    for index = #applied, 1, -1 do
      local entry = applied[index]
      -- `post_tick == nil` significa que la escritura ni siquiera empezó: no
      -- hay nada que revertir en ese buffer.
      if entry.post_tick ~= nil then
        attempted = attempted + 1
        local restored, method, rollback_err = rollback_group(entry)
        if restored then
          rolled_back = rolled_back + 1
          info.rollback_details[#info.rollback_details + 1] = string.format("%s: revertido (%s)", entry.filename, method)
        else
          info.rollback_details[#info.rollback_details + 1] = string.format(
            "%s: NO revertido (%s)",
            entry.filename,
            tostring(rollback_err)
          )
        end
      end
    end

    if attempted == 0 then
      info.rollback = "not_needed"
    elseif rolled_back == attempted then
      info.rollback = "restored"
    else
      info.rollback = "failed"
    end

    return false, message, info
  end

  for _, group in ipairs(plan.groups) do
    -- Revalida lo que puede haber cambiado entre la preparación y la escritura
    -- (autocommands de carga, por ejemplo).
    if not vim.api.nvim_buf_is_valid(group.bufnr) then
      return fail(string.format("el buffer de %s dejó de ser válido", group.filename), group)
    end

    if vim.api.nvim_buf_get_changedtick(group.bufnr) ~= group.changedtick then
      return fail(
        string.format("el buffer de %s cambió durante la preparación; edición cancelada", group.filename),
        group
      )
    end

    if group.version ~= nil then
      local current_version = M.buffer_version(group.bufnr)
      if current_version ~= nil and current_version ~= group.version then
        return fail(
          string.format(
            "versión incompatible para %s (edición=%d, buffer=%d)",
            group.filename,
            group.version,
            current_version
          ),
          group
        )
      end
    end

    M.close_undo_block(group.bufnr)

    -- El grupo entra en la lista de reversión antes de escribir: si
    -- `nvim_buf_set_text` falla a mitad, el buffer puede haber quedado
    -- parcialmente modificado y también hay que intentar restaurarlo.
    applied[#applied + 1] = group

    local ok_apply, apply_err = pcall(
      M.apply_edits_to_buffer,
      group.bufnr,
      group.edits,
      group.encoding or plan.encoding or "utf-16"
    )
    if not ok_apply then
      local tick_after_failure = vim.api.nvim_buf_get_changedtick(group.bufnr)
      if tick_after_failure ~= group.changedtick then
        group.post_tick = tick_after_failure
      end
      return fail(string.format("error al aplicar cambios en %s: %s", group.filename, tostring(apply_err)), group)
    end

    group.post_tick = vim.api.nvim_buf_get_changedtick(group.bufnr)
    info.applied_buffers[#info.applied_buffers + 1] = group.filename
  end

  -- Cierra el bloque de undo para que un único `u` revierta la acción completa.
  for _, group in ipairs(applied) do
    M.close_undo_block(group.bufnr)
  end

  return true, nil, info
end

--------------------------------------------------------------------------------
-- Aplicación de bajo nivel
--------------------------------------------------------------------------------

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

    -- Se sustituye sólo el tramo [start_col, stop_col): el prefijo de la línea
    -- inicial y el sufijo de la final se conservan. Reemplazar líneas completas
    -- producía previews falsos en ediciones intra-línea (p. ej. insertar `;`).
    local replacement = vim.split(
      start_text:sub(1, start_col) .. (edit.newText or "") .. stop_text:sub(stop_col + 1),
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
function M.apply_edits_to_buffer(bufnr, edits, encoding)
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
    local start_len = M.byte_to_char(start_text, #start_text, encoding)
    local stop_len = M.byte_to_char(stop_text, #stop_text, encoding)
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
---
--- No crea buffers ni carga ficheros: si el destino no está abierto se lee del
--- disco para el diff (sólo si existe). La previsualización no debe tener
--- efectos secundarios sobre el estado de Neovim.
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
    local target = M.find_buf(group, bufnr)
    local before

    if target then
      before = vim.api.nvim_buf_get_lines(target, 0, -1, false)
    elseif is_readable_file(group.filename) then
      local ok_read, lines = pcall(vim.fn.readfile, group.filename)
      if ok_read and type(lines) == "table" then
        before = lines
      end
    end

    if before then
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
    else
      output[#output + 1] = string.format("# (destino no disponible: %s)", group.filename)
    end
  end

  if #output == 0 then
    output = { "(no changes)" }
  end

  return output
end

return M
