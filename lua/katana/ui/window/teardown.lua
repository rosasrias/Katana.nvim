---@mod katana.ui.window.teardown Cierre del picker
---
--- Libera ventanas, buffers, autocmds y `guicursor`. Es idempotente: se puede
--- llamar varias veces, con o sin picker abierto, y también después de una
--- apertura que falló a medias. No requiere Volt para limpiar buffers ni
--- ventanas.

local api = vim.api

local state = require("katana.state")
local guicursor = require("katana.ui.window.guicursor")

local M = {}

---@return boolean
function M.close()
  local had_resources = state.open
    or state.buf_main ~= nil
    or state.win_main ~= nil
    or state.buf_preview ~= nil
    or state.win_preview ~= nil
    or state.guicursor_prev ~= nil

  if not had_resources then
    return true
  end

  state.open = false

  if state.au_close then
    pcall(api.nvim_del_autocmd, state.au_close)
    state.au_close = nil
  end

  -- `volt.utils.close` borra el buffer de la lista y lo quita de `volt.events`.
  -- Si Volt no está disponible (por ejemplo, tras un fallo de carga), se sigue
  -- limpiando a mano.
  local list_buf = state.buf_main
  if list_buf and api.nvim_buf_is_valid(list_buf) then
    pcall(function()
      require("volt.utils").close({ bufs = { list_buf } })
    end)
  end

  if state.win_main and api.nvim_win_is_valid(state.win_main) then
    pcall(api.nvim_win_close, state.win_main, true)
  end

  if state.win_preview and api.nvim_win_is_valid(state.win_preview) then
    pcall(api.nvim_win_close, state.win_preview, true)
  end

  if list_buf and api.nvim_buf_is_valid(list_buf) then
    pcall(api.nvim_buf_delete, list_buf, { force = true })
  end

  if state.buf_preview and api.nvim_buf_is_valid(state.buf_preview) then
    pcall(api.nvim_buf_delete, state.buf_preview, { force = true })
  end

  -- Devuelve el foco a la ventana de origen.
  if state.origin_win and api.nvim_win_is_valid(state.origin_win) then
    pcall(api.nvim_set_current_win, state.origin_win)
  end

  guicursor.restore()

  state.reset()
  return true
end

return M
