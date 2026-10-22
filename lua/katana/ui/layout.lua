---@mod katana.ui.layout Geometría de las ventanas del picker
---
--- `nvim_win_get_position` devuelve la posición del *contenido* de la ventana, por
--- lo que el borde (1 celda por lado) se contabiliza aparte.
---
--- Disposición (ancho `total_width`, alto `total_height`):
---
--- ```
---      ┌ prompt (1 fila, sin borde) ──────────────┐
---      │  > filtro en vivo                         │
---      ├──────────────────────────────────────────┤
---      │  lista de acciones (Volt)      │ preview  │
---      │                                │  diff    │
---      └────────────────────────────────┴─────────┘
--- ```

local config = require("katana.config")

local M = {}

--- Calcula la geometría de las ventanas del picker.
---@return table
function M.compute()
  local opts = config.options

  local total_width = math.max(30, math.floor(vim.o.columns * (opts.width or 0.8)))
  total_width = math.min(total_width, vim.o.columns - 2)

  local total_height = math.max(6, math.floor(vim.o.lines * (opts.height or 0.7)))
  total_height = math.min(total_height, vim.o.lines - 4)

  -- Ancho útil: se descuentan los bordes de las dos ventanas (2 columnas cada una)
  -- y la columna separadora.
  local content = total_width - 5

  local preview_width = 0
  if opts.preview and total_width >= 60 then
    preview_width = math.floor(content * 0.45)
  end

  local list_width = math.max(20, content - preview_width)

  -- Alto de la lista: se reserva 1 fila para el prompt y 2 para los bordes.
  local list_height = math.max(1, total_height - 3)

  local left = math.max(0, math.floor((vim.o.columns - total_width) / 2))
  -- El prompt vive una fila por encima del borde superior de la lista.
  local top = math.max(1, math.floor((vim.o.lines - total_height) / 2))

  return {
    list_width = list_width,
    list_height = list_height,
    preview_width = preview_width,
    left = left,
    top = top,
    border = opts.border,
    list = {
      row = top,
      col = left,
      width = list_width,
      height = list_height,
    },
    prompt = {
      row = top - 1,
      -- Alineado con el contenido de la lista (la lista tiene borde).
      col = left + 1,
      width = list_width,
      height = 1,
    },
    preview = {
      row = top,
      col = left + list_width + 3,
      width = preview_width,
      height = list_height,
    },
  }
end

return M
