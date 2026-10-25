---@mod katana.ui.highlights Grupos de resaltado del picker

local config = require("katana.config")
local state = require("katana.state")
local theme = require("katana.ui.theme")

local M = {}

local group_hls = {
  quickfix = "KatanaQuickfix",
  ["refactor.extract"] = "KatanaRefactorExtract",
  ["refactor.inline"] = "KatanaRefactorInline",
  ["refactor.rewrite"] = "KatanaRefactorRewrite",
  ["refactor.convert"] = "KatanaRefactorConvert",
  refactor = "KatanaRefactor",
  ["source.organizeImports"] = "KatanaSourceImports",
  ["source.fixAll"] = "KatanaSourceFixAll",
  source = "KatanaSource",
  command = "KatanaCommand",
  other = "KatanaOther",
}

function M.setup()
  if not state.ns_main then
    state.ns_main = vim.api.nvim_create_namespace("KatanaMain")
    state.ns_sel = vim.api.nvim_create_namespace("KatanaSelection")
    state.ns_preview = vim.api.nvim_create_namespace("KatanaPreview")
  end

  local c = theme.palette()
  local hl = vim.api.nvim_set_hl

  local sel_bg = theme.selection_bg(c)
  local accent = config.options.selection_accent or c.blue

  -- Resaltado de la fila seleccionada: se aplica a toda la fila (`KatanaRow`) y
  -- a los tramos con color propio (`KatanaSelected*`). La señal de selección es
  -- el **texto en azul** (`selection_accent`), no una barra ni un glifo.
  hl(0, "KatanaRow", {
    bg = sel_bg,
    fg = c.white,
    bold = true,
  })
  -- Cursor de la lista: en el TUI el color del cursor sale del fondo del grupo,
  -- así que con el mismo fondo que la fila activa queda invisible (no hay raya
  -- gris junto al número).
  hl(0, "KatanaCursor", { bg = sel_bg, fg = sel_bg })
  hl(0, "KatanaSelectedText", {
    bg = sel_bg,
    fg = accent,
    bold = true,
  })
  hl(0, "KatanaSelectedNum", {
    bg = sel_bg,
    fg = accent,
    bold = true,
  })
  hl(0, "KatanaSelectedSource", {
    bg = sel_bg,
    fg = accent,
    italic = true,
  })
  hl(0, "KatanaSelectedPreferred", {
    bg = sel_bg,
    fg = c.yellow,
    bold = true,
  })

  hl(0, "KatanaHeader", { fg = c.blue, bold = true })
  hl(0, "KatanaHeaderIcon", { fg = c.blue })
  hl(0, "KatanaSeparator", { fg = c.grey_fg2 })

  hl(0, "KatanaNum", { fg = c.grey_fg })
  hl(0, "KatanaSourceName", { fg = c.grey_fg, italic = true })
  hl(0, "KatanaTitle", { fg = c.fg })
  hl(0, "KatanaPreferred", { fg = c.yellow, bold = true })
  hl(0, "KatanaDisabled", { fg = c.grey_fg2, strikethrough = true })

  -- Un color por kind: es lo que da color propio a cada icono. Se eligen colores
  -- distintos dentro de cada familia (extra/inline/rewrite/convert no comparten
  -- color) para que dos iconos no se confundan.
  --
  -- Para cada grupo se crea además su variante sobre la fila seleccionada
  -- (`<grupo>Sel`), con el mismo color y el fondo del resaltado: así el icono no
  -- pierde su color cuando la fila está activa.
  local kind_colors = {
    KatanaQuickfix = c.red,
    KatanaRefactor = c.purple,
    KatanaRefactorExtract = c.magenta,
    KatanaRefactorInline = c.teal,
    KatanaRefactorRewrite = c.yellow,
    KatanaRefactorConvert = c.orange,
    KatanaSource = c.green,
    KatanaSourceImports = c.teal,
    KatanaSourceFixAll = c.yellow,
    KatanaCommand = c.orange,
    KatanaOther = c.blue,
  }

  for name, color in pairs(kind_colors) do
    hl(0, name, { fg = color })
    hl(0, name .. "Sel", { fg = color, bg = sel_bg })
  end

  ------------------------------------------------------------------ mini.icons
  -- Los iconos de `mini.icons` se colorean con los grupos `MiniIcons*`. NvChad
  -- los define en su caché de base46, así que se respetan tal cual. Si el tema
  -- no los define —o los deja sin `fg` efectivo— se asigna un color de respaldo
  -- para que el icono nunca salga sin color.
  --
  -- Ojo: `mini.icons` define esos grupos como `default = true` con `link`, así
  -- que hay que seguir el enlace para saber si tienen color de verdad.
  local icons = require("katana.ui.icons")

  -- Fuerza la configuración de mini.icons antes de leer sus grupos.
  icons.available()

  --- `fg` efectivo de un grupo, siguiendo enlaces.
  ---@param name string
  ---@return integer|nil
  local function effective_fg(name)
    local def = vim.api.nvim_get_hl(0, { name = name, link = false })
    if def.fg then
      return def.fg
    end

    local linked = vim.api.nvim_get_hl(0, { name = name })
    return linked and linked.fg or nil
  end

  for name, fallback in pairs(icons.color_fallbacks) do
    local fg = effective_fg(name)
    local lum = fg and icons.luma(string.format("#%06x", fg))

    -- El tema puede no definir el grupo, o definirlo con un color tan oscuro
    -- que se pierde sobre el fondo: en ambos casos se usa el respaldo.
    if not fg or (lum or 0) < icons.min_luma then
      hl(0, name, { fg = fallback })
    end
  end

  -- Los grupos se definen en el namespace global (0), que es el que usan los
  -- extmarks al resolver el resaltado. La fila sin seleccionar referencia el
  -- grupo base del tema y la seleccionada su variante `Sel`.
  for name, _ in pairs(icons.color_fallbacks) do
    local fg = effective_fg(name)
    if fg then
      hl(0, name, { fg = fg })
      hl(0, name .. "Sel", { fg = fg, bg = sel_bg })
    end
  end
end

function M.hl_group_for(key)
  return group_hls[key] or "KatanaOther"
end

--- Grupo del icono para una fila, según esté seleccionada o no.
---
--- Se acepta cualquier grupo (tanto `Katana*` como `MiniIcons*`). El fondo de la
--- fila activa se aplica con una variante `<grupo>Sel` generada en `setup()`.
---@param hl_group string grupo base (`MiniIconsRed`, `KatanaQuickfix`, ...)
---@param selected boolean
---@return string
function M.selected_hl_for(hl_group, selected)
  if not selected then
    return hl_group
  end

  local variant = hl_group .. "Sel"
  local def = vim.api.nvim_get_hl(0, { name = variant, link = false })
  if def.fg then
    return variant
  end

  -- Sin variante generada (grupo desconocido): se usa el base, que al menos no
  -- pierde el color; el fondo ya lo pone el tramo contiguo.
  return hl_group
end

return M
