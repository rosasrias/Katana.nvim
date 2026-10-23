---@mod katana.ui.highlights Grupos de resaltado del picker

local config = require("katana.config")
local state = require("katana.state")

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

--- Colores del tema, con respaldo por clave.
---
--- El tema de NvChad se carga desde `base46_cache`; si el fichero no existe o la
--- clave no está (temas antiguos), se usa el respaldo. Así el picker nunca se
--- queda sin color.
local function palette()
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

--- Convierte `#rrggbb` en `{r, g, b}` (0-255).
local function to_rgb(hex)
  if type(hex) ~= "string" then
    return nil
  end
  local r, g, b = hex:match("^#(%x%x)(%x%x)(%x%x)$")
  if not r then
    return nil
  end
  return tonumber(r, 16), tonumber(g, 16), tonumber(b, 16)
end

--- Aclara (o apaga) un color. `amount` va de -1 a 1.
local function shade(hex, amount)
  local r, g, b = to_rgb(hex)
  if not r then
    return hex
  end
  local function mix(v)
    local target = amount >= 0 and 255 or 0
    local value = v + (target - v) * math.abs(amount)
    return math.floor(math.max(0, math.min(255, value + 0.5)))
  end
  return string.format("#%02x%02x%02x", mix(r), mix(g), mix(b))
end

--- Diferencia de luminosidad entre dos colores (0-1 aproximado).
local function contrast(a, b)
  local ar, ag, ab = to_rgb(a)
  local br, bg, bb = to_rgb(b)
  if not ar or not br then
    return 1
  end
  local function luma(r, g, bl)
    return (0.2126 * r + 0.7152 * g + 0.0722 * bl) / 255
  end
  return math.abs(luma(ar, ag, ab) - luma(br, bg, bb))
end

--- Fondo de la fila seleccionada, garantizando que se distinga del fondo normal.
local function selection_bg(c)
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
  if contrast(base, surface) >= 0.08 then
    return base
  end

  -- Se separa del fondo hacia el lado que más se aleje.
  local lighter = shade(surface, 0.18)
  local darker = shade(surface, -0.40)
  return contrast(lighter, surface) >= contrast(darker, surface) and lighter or darker
end

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

function M.setup()
  if not state.ns_main then
    state.ns_main = vim.api.nvim_create_namespace("KatanaMain")
    state.ns_sel = vim.api.nvim_create_namespace("KatanaSelection")
    state.ns_preview = vim.api.nvim_create_namespace("KatanaPreview")
  end

  local c = palette()
  local hl = vim.api.nvim_set_hl

  local sel_bg = selection_bg(c)
  local accent = config.options.selection_accent or c.blue

  -- Resaltado de la fila seleccionada: se aplica a toda la fila (`KatanaRow`) y
  -- a los tramos con color propio (`KatanaSelectedText`), de modo que la barra
  -- activa se distingue aunque el título tenga otro color.
  hl(state.ns_main, "KatanaRow", {
    bg = sel_bg,
    fg = c.white,
    bold = true,
  })
  -- Barra izquierda de la fila activa: da la señal visual aunque el fondo del
  -- tema sea poco contrastado.
  hl(state.ns_main, "KatanaAccent", {
    fg = accent,
    bg = sel_bg,
    bold = true,
  })
  hl(state.ns_main, "KatanaSelectedText", {
    bg = sel_bg,
    fg = c.white,
    bold = true,
  })
  hl(state.ns_main, "KatanaSelectedNum", {
    bg = sel_bg,
    fg = c.grey_fg,
  })
  hl(state.ns_main, "KatanaSelectedSource", {
    bg = sel_bg,
    fg = c.grey_fg,
    italic = true,
  })
  hl(state.ns_main, "KatanaSelectedPreferred", {
    bg = sel_bg,
    fg = c.yellow,
    bold = true,
  })

  hl(state.ns_main, "KatanaHeader", { fg = c.blue, bold = true })
  hl(state.ns_main, "KatanaHeaderIcon", { fg = c.blue })
  hl(state.ns_main, "KatanaSeparator", { fg = c.grey_fg2 })

  hl(state.ns_main, "KatanaNum", { fg = c.grey_fg })
  hl(state.ns_main, "KatanaServer", { fg = c.grey_fg, italic = true })
  hl(state.ns_main, "KatanaSourceName", { fg = c.grey_fg, italic = true })
  hl(state.ns_main, "KatanaTitle", { fg = c.fg })
  hl(state.ns_main, "KatanaPreferred", { fg = c.yellow, bold = true })
  hl(state.ns_main, "KatanaDisabled", { fg = c.grey_fg2, strikethrough = true })

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
    hl(state.ns_main, name, { fg = color })
    hl(state.ns_main, name .. "Sel", { fg = color, bg = sel_bg })
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

  -- Volt pinta dentro de `ns_main`, y los grupos de un namespace **no** ven los
  -- definidos en otro (los `MiniIcons*` globales viven en el namespace 0). Por
  -- eso se replican aquí: la fila sin seleccionar referencia el grupo base, y la
  -- seleccionada su variante `Sel`, y ambos tienen que resolver en `ns_main`.
  for name, _ in pairs(icons.color_fallbacks) do
    local fg = effective_fg(name)
    if fg then
      hl(state.ns_main, name, { fg = fg })
      hl(state.ns_main, name .. "Sel", { fg = fg, bg = sel_bg })
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
  local def = vim.api.nvim_get_hl(state.ns_main, { name = variant, link = false })
  if def.fg then
    return variant
  end

  -- Sin variante generada (grupo desconocido): se usa el base, que al menos no
  -- pierde el color; el fondo ya lo pone el tramo contiguo.
  return hl_group
end

return M
