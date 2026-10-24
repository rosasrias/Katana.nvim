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

  -- Cada acción empieza a previsualizarse desde arriba, aunque la anterior
  -- estuviera desplazada.
  local win = state.win_preview
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_call, win, function()
      vim.cmd("normal! ggzt")
    end)
  end
end

--- Desplaza el contenido del preview sin cambiar la selección.
---
--- El preview tiene un alto máximo (`preview_max_height`); cuando el diff no
--- cabe, se navega dentro de su ventana con la rueda del ratón, `j`/`k` (si
--- tiene el foco) o estos atajos desde la lista.
---@param delta integer líneas a desplazar (positivo = hacia abajo)
function M.scroll(delta)
  local win = state.win_preview
  if not win or not vim.api.nvim_win_is_valid(win) or delta == 0 then
    return
  end

  local key = delta > 0 and "\5" or "\25" -- <C-e> / <C-y>
  local count = math.abs(delta)

  pcall(vim.api.nvim_win_call, win, function()
    vim.cmd(("normal! %d%s"):format(count, key))
  end)
end

return M
