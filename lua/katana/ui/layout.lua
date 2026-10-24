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
---      │───────────────────────────────────────────│
---      │  lista de acciones (Volt)                 │
---      │───────────────────────────────────────────│
---      │  preview (alto máximo: preview_max_height)│
---      │  ... scroll si el diff es más largo       │
---      └───────────────────────────────────────────┘
--- ```
---
--- `preview_split = "vertical"` cambia la parte inferior por una columna a la
--- derecha de la lista.

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

  local split = opts.preview_split == "horizontal" and "horizontal" or "vertical"
  local left = math.max(0, math.floor((vim.o.columns - total_width) / 2))
  local top = math.max(1, math.floor((vim.o.lines - total_height) / 2))

  if split == "horizontal" then
    -- Distribución vertical: prompt arriba, lista arriba/centro, preview abajo.
    local content_height = total_height - 5 -- descontar bordes + prompt
    local preview_height = 0
    if opts.preview and total_height >= 12 then
      -- El preview tiene un alto máximo: si el diff es más largo, se desplaza
      -- dentro de su ventana en vez de hacer crecer el picker.
      local max_preview = math.max(3, opts.preview_max_height or 12)
      preview_height = math.min(math.max(3, math.floor(content_height * 0.5)), max_preview)
      preview_height = math.min(preview_height, math.max(3, content_height - 3))
    end
    local list_height = math.max(3, content_height - preview_height)

    local list_width = total_width - 2 -- bordes laterales
    local prompt_width = list_width

    return {
      list_width = list_width - 2,
      list_height = list_height,
      preview_width = list_width,
      preview_height = preview_height,
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
        col = left + 1,
        width = prompt_width - 2,
        height = 1,
      },
      preview = {
        row = top + list_height + 2,
        col = left,
        width = list_width,
        height = preview_height,
      },
    }
  end

  -- Vertical: lista | preview (a la derecha).
  local content = total_width - 5
  local preview_width = 0
  if opts.preview and total_width >= 60 then
    preview_width = math.floor(content * 0.45)
  end

  local list_width = math.max(20, content - preview_width)
  local list_height = math.max(1, total_height - 3)

  return {
    list_width = list_width,
    list_height = list_height,
    preview_width = preview_width,
    preview_height = list_height,
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
