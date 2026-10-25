---@mod katana.ui.color Utilidades de color
---
--- Conversiones y cálculos de color independientes de Neovim: no leen opciones
--- ni estado del plugin. Se usan para derivar el fondo de la selección a partir
--- del tema.

local M = {}

--- Convierte `#rrggbb` en `{r, g, b}` (0-255).
---@param hex string|nil
---@return integer|nil r
---@return integer|nil g
---@return integer|nil b
function M.to_rgb(hex)
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
---@param hex string
---@param amount number
---@return string
function M.shade(hex, amount)
  local r, g, b = M.to_rgb(hex)
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
---
--- Es una aproximación barata: no aplica la corrección gamma de la luminancia
--- relativa, sólo compara el brillo percibido. Sirve para decidir si dos colores
--- se distinguen a simple vista.
---@param a string
---@param b string
---@return number
function M.contrast(a, b)
  local ar, ag, ab = M.to_rgb(a)
  local br, bg, bb = M.to_rgb(b)
  if not ar or not br then
    return 1
  end

  local function luma(r, g, bl)
    return (0.2126 * r + 0.7152 * g + 0.0722 * bl) / 255
  end

  return math.abs(luma(ar, ag, ab) - luma(br, bg, bb))
end

--- Luminancia relativa (0 = negro, 1 = blanco) de un color `#rrggbb`.
---
--- A diferencia de `contrast`, aplica la corrección gamma de la WCAG, así que
--- sirve para decidir si un color es legible sobre un fondo oscuro.
---@param hex string|nil
---@return number|nil
function M.luma(hex)
  local r, g, b = M.to_rgb(hex)
  if not r then
    return nil
  end

  local function channel(v)
    v = v / 255
    return v <= 0.03928 and v / 12.92 or ((v + 0.055) / 1.055) ^ 2.4
  end

  return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
end

return M
