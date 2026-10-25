---@mod katana.ui.icons Iconos del picker
---
--- Los iconos se obtienen de **mini.icons** (categoría `lsp`), que ya trae glifos
--- `nf-md-*` y un grupo de color `MiniIcons*` por icono. NvChad define esos
--- grupos en su caché de base46, así que los colores encajan con el tema sin
--- configuración extra.
---
--- Si `mini.icons` no está disponible, se usan los glifos de `config.options.icons`
--- con los colores `Katana*` de siempre.

local color = require("katana.ui.color")

local M = {}

--- Kind de code action -> kind de LSP de mini.icons.
---
--- No hay correspondencia exacta (los *code action kinds* y los *LSP symbol
--- kinds* son cosas distintas), así que se elige el icono que mejor representa
--- cada acción.
---@type table<string, string>
M.kind_map = {
  quickfix = "snippet",
  ["quickfix.fixAll"] = "text",
  ["refactor.extract"] = "package",
  ["refactor.inline"] = "function",
  ["refactor.rewrite"] = "reference",
  ["refactor.convert"] = "enummember",
  refactor = "method",
  ["source.organizeImports"] = "array",
  ["source.fixAll"] = "struct",
  source = "file",
  command = "keyword",
  other = "object",
}

--- Color de respaldo por clave de `MiniIcons*`, por si el tema no la define.
---
--- Los temas de NvChad sí las definen (base46 las genera), pero un tema ajeno
--- puede no hacerlo: en ese caso el icono saldría sin color.
---@type table<string, string>
M.color_fallbacks = {
  MiniIconsRed = "#e06c75",
  MiniIconsGreen = "#98c379",
  MiniIconsBlue = "#61afef",
  MiniIconsCyan = "#56b6c2",
  MiniIconsGrey = "#abb2bf",
  MiniIconsOrange = "#d19a66",
  MiniIconsPurple = "#c678dd",
  MiniIconsYellow = "#e7c787",
  MiniIconsAzure = "#61afef",
}

--- Luminancia relativa (0 = negro, 1 = blanco) de un color `#rrggbb`.
---@param hex string|nil
---@return number|nil
function M.luma(hex)
  return color.luma(hex)
end

--- Colores por debajo de esta luminancia son ilegibles sobre el fondo oscuro
--- (y sobre el resaltado de selección). Por ejemplo, base46 define
--- `MiniIconsGrey` como `#42464e`, casi igual que el fondo de la fila activa.
M.min_luma = 0.12

--- ¿Está mini.icons listo?
---
--- `MiniIcons` es un global que sólo existe tras `require('mini.icons').setup()`.
--- Para no depender de que el usuario lo haya configurado (y para que el picker
--- funcione aunque el plugin se cargue tarde), aquí se configura si hace falta.
---@return boolean
function M.available()
  if _G.MiniIcons ~= nil and type(MiniIcons.get) == "function" then
    return true
  end

  -- Se intenta configurar una sola vez.
  if M._tried then
    return false
  end
  M._tried = true

  local ok, mini = pcall(require, "mini.icons")
  if not ok then
    return false
  end

  -- `pcall`: otro plugin pudo configurarlo ya y `setup` avisa por duplicado.
  pcall(mini.setup, {})

  return _G.MiniIcons ~= nil and type(MiniIcons.get) == "function"
end

--- Icono y grupo de color para una acción.
---
--- Devuelve `nil` si no se puede resolver con mini.icons, para que el llamante
--- use el respaldo de `config.options.icons`.
---@param kind string|nil
---@return string|nil icon
---@return string|nil hl_group
function M.get(kind)
  if not M.available() then
    return nil, nil
  end

  local key = kind and require("katana.utils").kind_group_key(kind) or "other"
  local lsp_kind = M.kind_map[key] or M.kind_map.other

  local ok, icon, hl = pcall(MiniIcons.get, "lsp", lsp_kind)
  if not ok or type(icon) ~= "string" or icon == "" or type(hl) ~= "string" then
    return nil, nil
  end

  return icon, hl
end

return M
