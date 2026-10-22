---@mod katana.preview.diff Previsualización de la acción seleccionada
---
--- Muestra el diff que producirá la acción (recalculado con el estado actual del
--- buffer) o, si la acción no modifica el buffer, información sobre ella.

local state = require("katana.state")
local config = require("katana.config")
local workspace = require("katana.lsp.workspace")

local M = {}

--- Líneas informativas para acciones sin cambios de texto.
---@param action KatanaAction
---@return string[]
local function info_lines(action)
  local lines = {
    "# " .. (action.title or ""),
    "",
    "Source: " .. (action.source or "n/a"),
    "Kind:   " .. (action.kind or "n/a"),
  }

  if action._client_name then
    table.insert(lines, "Client: " .. action._client_name)
  end
  if action.isPreferred then
    table.insert(lines, "Preferred: true")
  end
  if action.disabled then
    local reason = type(action.disabled) == "table" and action.disabled.reason or nil
    table.insert(lines, "Disabled: " .. (reason or "true"))
  end
  if action.command then
    local command = type(action.command) == "table" and action.command.command or action.command
    table.insert(lines, "Command: " .. tostring(command))
  end

  table.insert(lines, "")
  table.insert(lines, "(no workspace edit to preview)")

  return lines
end

--- Actualiza el buffer de previsualización.
function M.update()
  local buf = state.buf_preview
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local opts = config.options
  local item = state.flat[state.index]
  local lines

  if not item or item.type ~= "action" then
    lines = { "Select a code action to preview its changes" }
  else
    local action = item.action

    if action.edit then
      lines = workspace.preview_lines(
        action.edit,
        state.origin_buf,
        action.encoding or "utf-16",
        opts.diff_backend
      )
    else
      lines = info_lines(action)
    end
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "diff"
end

return M
