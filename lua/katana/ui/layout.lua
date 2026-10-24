---@mod katana.ui.layout Geometría de las ventanas del picker
---
--- `nvim_win_get_position` devuelve la posición del *contenido* de la ventana, por
--- lo que el borde (1 celda por lado) se contabiliza aparte.
---
--- Disposición por defecto (`preview_split = "horizontal"`):
---
--- ```
---      ┌ lista de acciones (Volt) ─────────────────┐
---      │  ... alto fijo: list_max_height           │
---      ├───────────────────────────────────────────┤
---      │  preview (alto máximo: preview_max_height)│
---      │  ... scroll si el diff es más largo       │
---      └───────────────────────────────────────────┘
--- ```
---
--- `preview_split = "vertical"` pone el preview a la derecha de la lista.

local config = require("katana.config")

local M = {}

--- Calcula la geometría de las ventanas del picker.
---@return table
function M.compute()
  local opts = config.options

  local total_width = math.max(30, math.floor(vim.o.columns * (opts.width or 0.8)))
  total_width = math.min(total_width, vim.o.columns - 2)

  local total_height = math.max(6, math.floor(vim.o.lines * (opts.height or 0.7)))
  total_height = math.min(total_height, vim.o.lines - 2)

  local split = opts.preview_split == "horizontal" and "horizontal" or "vertical"
  local left = math.max(0, math.floor((vim.o.columns - total_width) / 2))

  -- Alto fijo de la lista: el panel no crece con el número de acciones (da
  -- igual que haya 2 o 40) y el sobrante se recorre con la ventana.
  local max_list = math.max(3, opts.list_max_height or 20)

  if split == "horizontal" then
    -- Lista arriba, preview abajo. Cada ventana aporta 2 filas de borde.
    local content_height = total_height - 4
    local preview_height = 0

    if opts.preview and content_height >= 6 then
      -- El preview tiene un alto máximo: si el diff es más largo, se desplaza
      -- dentro de su ventana en vez de hacer crecer el picker.
      local max_preview = math.max(3, opts.preview_max_height or 12)
      preview_height = math.min(math.max(3, math.floor(content_height * 0.5)), max_preview)
      preview_height = math.min(preview_height, math.max(3, content_height - 3))
    end

    local list_height = math.max(3, math.min(content_height - preview_height, max_list))

    -- El panel se ajusta a la altura real (lista + preview + bordes) y se
    -- centra: sin hueco muerto cuando la lista no usa toda la pantalla.
    local used_height = list_height + preview_height + 4
    local top = math.max(1, math.floor((vim.o.lines - used_height) / 2))

    return {
      -- Sin relleno a la izquierda: el texto empieza en la primera columna.
      list_width = total_width - 2,
      list_height = list_height,
      preview_width = total_width - 2,
      preview_height = preview_height,
      left = left,
      top = top,
      border = opts.border,
      list = {
        row = top,
        col = left,
        width = total_width - 2,
        height = list_height,
      },
      preview = {
        row = top + list_height + 2,
        col = left,
        width = total_width - 2,
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
  local list_height = math.max(3, math.min(total_height - 2, max_list))

  -- Centrado con el alto real de la lista (no con el máximo de la pantalla).
  local top = math.max(1, math.floor((vim.o.lines - (list_height + 2)) / 2))

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
    preview = {
      row = top,
      col = left + list_width + 3,
      width = preview_width,
      height = list_height,
    },
  }
end

return M
