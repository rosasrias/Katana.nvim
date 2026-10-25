---@mod katana.apply.edit Validación y aplicación de WorkspaceEdit
---
--- Envuelve al adapter `katana.lsp.workspace`: valida el payload y aplica el
--- plan preparado. No ejecuta comandos ni callbacks.

local optional = require("katana.core.optional")
local workspace = require("katana.lsp.workspace")

local M = {}

---@param info table|nil
---@return table
local function empty_info(info)
  return info
    or {
      applied_buffers = {},
      failed_buffer = nil,
      rollback = "not_needed",
      rollback_details = {},
    }
end

--- Valida estructuralmente un `WorkspaceEdit`.
---@param edit vim.lsp.WorkspaceEdit|nil
---@return boolean ok
---@return string|nil error
function M.validate(edit)
  edit = optional.value(edit)
  if edit == nil then
    return true
  end

  if type(edit) ~= "table" then
    return false, "WorkspaceEdit inválido"
  end

  local entries, err = workspace.extract_edits(edit)
  if err then
    return false, err
  end

  if #entries == 0 then
    return false, "el WorkspaceEdit no contiene cambios aplicables"
  end

  for _, entry in ipairs(entries) do
    if type(entry.edits) ~= "table" or #entry.edits == 0 then
      return false, "el WorkspaceEdit contiene un grupo sin ediciones"
    end
    for _, text_edit in ipairs(entry.edits) do
      if type(text_edit) ~= "table" or type(text_edit.range) ~= "table" then
        return false, "edición sin rango en WorkspaceEdit"
      end
    end
  end

  return true
end

--- Aplica el `WorkspaceEdit` de una acción.
---@param action KatanaAction
---@param opts KatanaExecutorOptions
---@return boolean ok
---@return string|nil error
---@return table|nil info
function M.apply(action, opts)
  local edit = optional.value(action.edit)
  if edit == nil then
    return true, nil, empty_info()
  end

  if type(edit) ~= "table" then
    return false, "el WorkspaceEdit no es una tabla", empty_info()
  end

  local plan, prepare_err = workspace.prepare_edit(edit, opts.bufnr, action.encoding or "utf-16")
  if not plan then
    return false, prepare_err, empty_info()
  end

  return workspace.apply_plan(plan)
end

return M
