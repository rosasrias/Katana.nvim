---@mod katana.apply.run Callbacks propios de una acción
---
--- Ejecuta `execute_fn` (la lógica del usuario o del proveedor). Las acciones
--- propias también pueden modificar el buffer, así que se cierra el bloque de
--- undo antes de invocarlas.

local optional = require("katana.core.optional")
local workspace = require("katana.lsp.workspace")

local M = {}

--- Ejecuta la lógica propia de la acción.
---@param action KatanaAction
---@param opts KatanaExecutorOptions
---@return boolean ok
---@return string|nil error
---@return boolean attempted
function M.execute_fn(action, opts)
  local execute_fn = optional.value(action.execute_fn)
  if execute_fn == nil then
    return true, nil, false
  end

  if type(execute_fn) ~= "function" then
    return false, "execute_fn no es una función", true
  end

  if opts.bufnr and vim.api.nvim_buf_is_valid(opts.bufnr) then
    workspace.close_undo_block(opts.bufnr)
  end

  local ok_fn, err_fn = pcall(execute_fn, action)
  if not ok_fn then
    return false, tostring(err_fn), true
  end

  return true, nil, true
end

return M
