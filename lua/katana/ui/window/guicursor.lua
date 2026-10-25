---@mod katana.ui.window.guicursor Cursor del picker
---
--- `guicursor` es global: mientras el picker está abierto se usa un bloque con
--- el grupo `KatanaCursor` y se guarda el valor del usuario para restaurarlo al
--- cerrar. Si el usuario lo cambia con el picker abierto, se respeta su cambio.

local state = require("katana.state")

local M = {}

--- Valor de `guicursor` que usa el picker mientras está abierto.
M.plugin_value = "a:block-KatanaCursor"

--- Activa el cursor del picker guardando el valor anterior.
function M.activate()
  local current = vim.o.guicursor
  if current ~= M.plugin_value then
    state.guicursor_prev = current
  end

  pcall(function()
    vim.o.guicursor = M.plugin_value
  end)
end

--- Restaura el cursor del usuario si nadie lo cambió mientras tanto.
function M.restore()
  if state.guicursor_prev and vim.o.guicursor == M.plugin_value then
    pcall(function()
      vim.o.guicursor = state.guicursor_prev
    end)
  end
end

return M
