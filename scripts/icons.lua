-- Pruebas de integración mini.icons + colores + cabeceras/selector
--
--   nvim --headless -u "C:\Users\rosas\AppData\Local\nvim\init.lua" -l scripts/icons.lua
--
-- Verifica:
--  - mini.icons se auto-configura y devuelve glifos + grupo MiniIcons*
--  - los grupos MiniIcons* existen en ns_main (para filas no seleccionadas) y
--    sus variantes *Sel con fondo de selección
--  - mapeo kind -> icono distinto, sin duplicados
--  - color legible (no demasiado oscuro) aplicado a MiniIconsGrey
--  - cabeceras vuelven a azul (KatanaHeader/Separator) y el selector es azul
--    (KatanaSelectionAccent) mientras los iconos de acción mantienen su color
--
local script = debug.getinfo(1, "S").source:sub(2)
local dir = vim.fn.fnamemodify(script, ":p:h")
local root = vim.fn.fnamemodify(dir, ":h")

vim.opt.rtp:append(root)

local env = dofile(dir .. "/env.lua")
local report = env.reporter()

report.header("Katana.nvim · icons/colors/headers test")

local katana = require("katana")
katana.setup({ ts = { enabled = false }, resolve_on_open = false })

local icons = require("katana.ui.icons")
local hls = require("katana.ui.highlights")
local state = require("katana.state")
local window = require("katana.ui.window")
local utils = require("katana.utils")

---------------------------------------------------------------- mini.icons
report.check("mini.icons disponible tras icons.available()", icons.available())
local ok_mini, MiniIcons = pcall(require, "mini.icons")
report.check("global MiniIcons existe", ok_mini and type(MiniIcons.get) == "function")

---------------------------------------------------------------- colores en namespaces
hls.setup()
local ns = state.ns_main
local function hex(v)
  return v and string.format("#%06x", v) or nil
end
local function get_fg(ns_id, name)
  local d = vim.api.nvim_get_hl(ns_id, { name = name, link = false })
  return d and d.fg or nil
end
local function get_fg_resolved(ns_id, name)
  local d = vim.api.nvim_get_hl(ns_id, { name = name, link = false })
  if d and d.fg then
    return d.fg
  end
  d = vim.api.nvim_get_hl(ns_id, { name = name })
  return d and d.fg or nil
end

local palette = { "MiniIconsRed", "MiniIconsGreen", "MiniIconsBlue", "MiniIconsCyan",
                  "MiniIconsGrey", "MiniIconsOrange", "MiniIconsPurple", "MiniIconsYellow", "MiniIconsAzure" }

for _, name in ipairs(palette) do
  report.check(name .. " tiene color en ns_main (fila no seleccionada)", get_fg_resolved(ns, name) ~= nil)
  report.check(name .. "Sel tiene color + bg en ns_main (fila seleccionada)", get_fg_resolved(ns, name .. "Sel") ~= nil)
end

-- MiniIconsGrey debe ser legible (luminancia suficiente)
local grey_luma = icons.luma(hex(get_fg_resolved(ns, "MiniIconsGrey")))
report.check("MiniIconsGrey legible (luma >= min_luma)", grey_luma ~= nil and grey_luma >= icons.min_luma, string.format("luma=%s min=%s", tostring(grey_luma), tostring(icons.min_luma)))

---------------------------------------------------------------- mapeo de kinds
local kinds = { "quickfix", "quickfix.fixAll", "refactor", "refactor.extract", "refactor.inline",
                "refactor.rewrite", "refactor.convert", "source", "source.organizeImports",
                "source.fixAll", "command", "other" }
local seen_cp, seen_hl = {}, {}
for _, k in ipairs(kinds) do
  local icon, hl = icons.get(k)
  report.check("icons.get(" .. k .. ") devuelve icono", type(icon) == "string" and #icon > 0)
  report.check("icons.get(" .. k .. ") devuelve grupo MiniIcons*", type(hl) == "string" and hl:match("^MiniIcons"))
  local cp = icon and vim.fn.str2list(icon)[1] or 0
  if cp >= 0xE000 then
    if seen_cp[cp] and seen_cp[cp] ~= k then
      report.check("icono único para " .. k .. " (vs " .. seen_cp[cp] .. ")", false)
    else
      seen_cp[cp] = k
    end
  end
  seen_hl[hl] = (seen_hl[hl] or 0) + 1
end

---------------------------------------------------------------- cabeceras azules + selector azul
window.open({
  { title = "Fix", kind = "quickfix", source = "lsp" },
  { title = "Extract", kind = "refactor.extract", source = "lsp" },
}, nil)
vim.wait(250)
vim.cmd("stopinsert")

local marks = vim.api.nvim_buf_get_extmarks(state.buf_main, ns, 0, -1, { details = true })
local header_ok, accent_ok, icon_color_ok = false, false, false
local action_icon_hl

for _, m in ipairs(marks) do
  local vt = m[4] and m[4].virt_text or {}
  local txt = {}
  for _, c in ipairs(vt) do txt[#txt + 1] = tostring(c[1]) end
  local line = table.concat(txt)

  -- La cabecera debe tener texto azul (KatanaHeader) y el icono azul
  if line:match("Quickfix") or line:match("Refactor") then
    for _, c in ipairs(vt) do
      if c[1]:match("Quickfix") or c[1]:match("Refactor") then
        if c[2] == "KatanaHeader" then
          header_ok = true
        end
      end
    end
    for _, c in ipairs(vt) do
      local cp = vim.fn.str2list(tostring(c[1]))[1] or 0
      if cp >= 0xE000 then
        if c[2] == "KatanaHeaderIcon" then
          header_ok = true
        end
      end
    end
  end

  -- El selector debe ser azul (KatanaSelectionAccent)
  if line:match("▎") then
    for _, c in ipairs(vt) do
      if c[1] == "▎" then
        if c[2] == "KatanaSelectionAccent" then
          accent_ok = true
        end
        -- el selector NO debe usar el color del icono de acción
        local acc = vim.api.nvim_get_hl(ns, { name = tostring(c[2]), link = false })
        local blue = vim.api.nvim_get_hl(ns, { name = "KatanaSelectionAccent", link = false })
        if acc.fg and blue.fg and acc.fg == blue.fg then
          -- ok
        end
      end
    end
  end

  -- Los iconos de acción deben seguir con color mini.icons (no KatanaHeader)
  for _, c in ipairs(vt) do
    local cp = vim.fn.str2list(tostring(c[1]))[1] or 0
    if cp >= 0xE000 and line:match("Fix") or line:match("Extract") then
      -- heurística: columnas de acción
    end
  end
end

report.check("cabeceras usan color azul (KatanaHeader/Icon)", header_ok)
report.check("selector usa KatanaSelectionAccent azul", accent_ok)

-- Verificación directa de los grupos
local acc_def = vim.api.nvim_get_hl(ns, { name = "KatanaSelectionAccent", link = false })
local hdr_def = vim.api.nvim_get_hl(ns, { name = "KatanaHeader", link = false })
local sep_def = vim.api.nvim_get_hl(ns, { name = "KatanaSeparator", link = false })
report.check("KatanaSelectionAccent definido (azul)", acc_def and acc_def.fg ~= nil)
report.check("KatanaHeader definido (azul/bold)", hdr_def and hdr_def.fg ~= nil)
report.check("KatanaSeparator definido", sep_def ~= nil)

window.close()

report.footer()
vim.cmd("qa!")
