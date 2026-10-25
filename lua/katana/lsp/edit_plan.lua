---@mod katana.lsp.edit_plan Preparación de un WorkspaceEdit
---
--- `prepare` valida el documento completo (URIs, buffers, versiones y rangos)
--- **sin escribir nada** y devuelve un plan verificable. La ejecución del plan
--- vive en `katana.lsp.edit_apply`.

local workspace_edit = require("katana.lsp.workspace_edit")
local buffer = require("katana.lsp.buffer")
local validation = require("katana.lsp.edit_validation")
local uri = require("katana.lsp.uri")

local M = {}

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
function M.prepare(edit, bufnr, encoding)
  if type(edit) ~= "table" then
    return nil, "WorkspaceEdit inválido"
  end

  encoding = encoding or "utf-16"

  local entries, extract_err = workspace_edit.extract(edit)
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

    local filename, uri_err = uri.to_path(entry.uri)
    if not filename then
      return nil, uri_err
    end

    local group = {
      uri = entry.uri,
      filename = filename,
      edits = entry.edits,
      version = entry.version,
    }

    local target, target_err = buffer.resolve(group, bufnr)
    if not target then
      return nil, target_err or ("no se pudo resolver el buffer destino de " .. filename)
    end

    local buffer_err = buffer.validate_target(target)
    if buffer_err then
      return nil, string.format("%s (%s)", buffer_err, filename)
    end

    if entry.version ~= nil then
      local current_version = buffer.version(target)
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
    local validated, range_err = validation.validate_list(entry.edits, lines, encoding)
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

return M
