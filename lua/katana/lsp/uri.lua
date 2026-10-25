---@mod katana.lsp.uri URIs y rutas de fichero
---
--- Aísla las peculiaridades de `vim.uri_to_fname` y de la normalización de
--- rutas. Sólo se aceptan URIs `file:`: una URI `untitled:`, `jdt:` o similar
--- no identifica un fichero editable y no debe acabar creando un buffer con un
--- nombre inventado.

local M = {}

--- Convierte una URI LSP en una ruta local.
---@param uri string|nil
---@return string|nil filename
---@return string|nil error
function M.to_path(uri)
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

--- Normaliza una ruta para comparar nombres de buffer.
---@param path string
---@return string
function M.normalize_path(path)
  local ok, normalized = pcall(vim.fs.normalize, path)
  return ok and normalized or path
end

--- Indica si la ruta corresponde a un fichero que se puede leer.
---@param path string
---@return boolean
function M.is_readable_file(path)
  if type(path) ~= "string" or path == "" then
    return false
  end
  return vim.fn.filereadable(path) == 1
end

return M
