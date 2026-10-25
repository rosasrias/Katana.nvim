---@mod katana.lsp.buffer Buffers de destino de un WorkspaceEdit
---
--- Resuelve el buffer asociado a un fichero sin inventar ficheros nuevos:
--- un `WorkspaceEdit` sólo puede editar recursos que ya existen en disco o que
--- ya están abiertos. También centraliza el cierre del bloque de undo.

local uri = require("katana.lsp.uri")

local M = {}

--- Versión LSP conocida del buffer (la última que Neovim envió al servidor).
---@param bufnr integer
---@return integer|nil
function M.version(bufnr)
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

--- Busca el buffer de un grupo sin crear ni cargar ficheros.
---@param group KatanaEditGroup
---@param bufnr integer|nil buffer de origen
---@return integer|nil
function M.find(group, bufnr)
  if type(group.filename) ~= "string" or group.filename == "" then
    return nil
  end

  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name ~= "" and uri.normalize_path(name) == uri.normalize_path(group.filename) then
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
function M.resolve(group, bufnr)
  local existing = M.find(group, bufnr)
  if existing then
    return existing
  end

  if not uri.is_readable_file(group.filename) then
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
function M.validate_target(target)
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

--- Cierra el bloque de undo actual del buffer.
---
--- Neovim fusiona en un mismo bloque de undo cualquier cambio hecho por API que
--- no esté precedido de un comando en modo normal. Reasignar `undolevels`
--- (incluso al mismo valor) cierra el bloque previo, de modo que los cambios de
--- la acción se deshacen con un único `u` sin arrastrar la edición previa del
--- usuario.
---
--- Referencia: `:help undo-break` ("Setting the value of 'undolevels' also
--- closes the undo block.  Even when the new value is equal to the old value.").
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

return M
