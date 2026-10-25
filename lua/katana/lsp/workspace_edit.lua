---@mod katana.lsp.workspace_edit Extracción de WorkspaceEdit
---
--- Convierte el payload LSP en grupos de ediciones por documento, sin tocar
--- buffers ni ficheros. `documentChanges` tiene prioridad sobre `changes`
--- (LSP 3.16+): si está presente no se procesa también `changes`, porque muchos
--- servidores envían ambos con el mismo contenido y aplicarlo dos veces
--- duplicaría la edición. Varias entradas para la misma URI se fusionan en
--- orden.

local optional = require("katana.core.optional")
local uri = require("katana.lsp.uri")

local M = {}

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
  local value = optional.value(edits)

  if type(value) ~= "table" then
    return nil, "las ediciones no son una lista"
  end

  if optional.value(value.range) ~= nil then
    return { value }, nil
  end

  return value, nil
end

--- Extrae y valida las entradas de un `WorkspaceEdit`, sin tocar buffers.
---@param edit vim.lsp.WorkspaceEdit|nil
---@return KatanaEditEntry[]
---@return string|nil error
function M.extract(edit)
  if type(edit) ~= "table" then
    return {}, "WorkspaceEdit inválido"
  end

  local entries = {}
  local document_changes = optional.value(edit.documentChanges)
  local changes = optional.value(edit.changes)

  if document_changes ~= nil then
    if type(document_changes) ~= "table" then
      return {}, "documentChanges no es una lista"
    end

    for index, change in ipairs(document_changes) do
      if type(change) ~= "table" then
        return {}, string.format("documentChanges[%d] no es una tabla", index)
      end

      local kind = optional.value(change.kind)
      if kind ~= nil then
        kind = tostring(kind)
        if RESOURCE_OPERATIONS[kind] or kind == "createFile" or kind == "renameFile" or kind == "deleteFile" then
          return {}, string.format(
            "la operación de recurso '%s' no está soportada (no se modifica el sistema de ficheros)",
            kind
          )
        end
        return {}, string.format("documentChanges[%d] tiene un 'kind' desconocido: %s", index, kind)
      end

      local text_document = optional.value(change.textDocument)
      if type(text_document) ~= "table" then
        return {}, string.format("documentChanges[%d] no incluye textDocument", index)
      end

      local edits, err = as_edit_list(change.edits)
      if not edits then
        return {}, string.format("documentChanges[%d]: %s", index, tostring(err))
      end

      local version = optional.value(text_document.version)
      if version ~= nil and (type(version) ~= "number" or version < 0 or version % 1 ~= 0) then
        return {}, string.format("documentChanges[%d] tiene una versión inválida: %s", index, tostring(version))
      end

      entries[#entries + 1] = {
        uri = optional.value(text_document.uri),
        edits = edits,
        version = version,
      }
    end
  elseif changes ~= nil then
    if type(changes) ~= "table" then
      return {}, "changes no es una tabla"
    end

    -- `pairs` no tiene orden garantizado; se ordena por URI para que la
    -- preparación y los mensajes de error sean deterministas.
    local uris = {}
    for change_uri in pairs(changes) do
      uris[#uris + 1] = change_uri
    end
    table.sort(uris, function(a, b)
      return tostring(a) < tostring(b)
    end)

    for _, change_uri in ipairs(uris) do
      local edits, err = as_edit_list(changes[change_uri])
      if not edits then
        return {}, string.format("changes[%s]: %s", tostring(change_uri), tostring(err))
      end

      entries[#entries + 1] = {
        uri = change_uri,
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

--- Normaliza un `WorkspaceEdit` en grupos por fichero.
---
--- Es la versión tolerante usada por el preview: las URIs no `file:` se omiten
--- en lugar de hacer fallar toda la previsualización.
---@param edit vim.lsp.WorkspaceEdit|nil
---@return KatanaEditGroup[]
function M.collect(edit)
  local entries = M.extract(edit)
  local groups = {}

  for _, entry in ipairs(entries) do
    local filename = uri.to_path(entry.uri)
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

return M
