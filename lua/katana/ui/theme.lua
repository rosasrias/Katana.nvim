---@mod katana.ui.theme Colores del tema para el picker
---
--- Resuelve la paleta del tema de NvChad (base46) y deriva el fondo de la fila
--- seleccionada. No define grupos de resaltado: eso vive en
--- `katana.ui.highlights`.

local config = require("katana.config")
local color = require("katana.ui.color")

local M = {}

--- Respaldo de cada clave del tema (por si el tema no la define).
---@type table<string, string>
M.fallbacks = {
  fg = "#c0caf5",
  white = "#ffffff",
  red = "#f38ba8",
  green = "#a6e3a1",
  blue = "#89b4fa",
  purple = "#cba6f7",
  magenta = "#f5c2e7",
  teal = "#94e2d5",
  orange = "#fab387",
  yellow = "#f9e2af",
  grey_fg = "#7f8490",
  grey_fg2 = "#6c7086",
  one_bg = "#1e1e2e",
  one_bg2 = "#313244",
  one_bg3 = "#45475a",
}

--- Colores del tema, con respaldo por clave.
---
--- El tema de NvChad se carga desde `base46_cache`; si el fichero no existe o la
--- clave no está (temas antiguos), se usa el respaldo. Así el picker nunca se
--- queda sin color.
---@return table<string, string>
function M.palette()
  local colors = {}
  pcall(function()
    colors = dofile(vim.g.base46_cache .. "colors")
  end)
  colors = type(colors) == "table" and colors or {}

  return setmetatable({}, {
    __index = function(_, key)
      local value = colors[key]
      if type(value) == "string" then
        return value
      end
      return M.fallbacks[key]
    end,
  })
end

--- Fondo de la fila seleccionada, garantizando que se distinga del fondo normal.
---@param c table<string, string>
---@return string
function M.selection_bg(c)
  if config.options.selection_color then
    return config.options.selection_color
  end

  -- `one_bg3` es el candidato natural, pero en muchos temas queda pegadísimo a
  -- `one_bg2`/`black` (fondos de las flotantes) y la selección no se ve.
  local surface = c.black

  -- Fondo real de la ventana flotante, si el tema lo define.
  local normal = vim.api.nvim_get_hl(0, { name = "NormalFloat", link = false })
  local current = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local real = normal.bg or current.bg
  if real then
    surface = string.format("#%06x", real)
  end

  local base = c.one_bg3
  if color.contrast(base, surface) >= 0.08 then
    return base
  end

  -- Se separa del fondo hacia el lado que más se aleje.
  local lighter = color.shade(surface, 0.18)
  local darker = color.shade(surface, -0.40)
  return color.contrast(lighter, surface) >= color.contrast(darker, surface) and lighter or darker
end

return M
