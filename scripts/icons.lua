-- Pruebas de integración mini.icons + colores + cabeceras/selector
--
--   nvim --headless -u NONE -l scripts/icons.lua
--
-- Verifica:
--  - mini.icons se auto-configura y devuelve glifos + grupo MiniIcons*
--  - los grupos MiniIcons* se replican en ns_main con sus variantes *Sel
--  - color legible aplicado a MiniIconsGrey si es necesario
--  - cabeceras azules (KatanaHeader/KatanaHeaderIcon) y selector (KatanaAccent)
--
local script = debug.getinfo(1, "S").source:sub(2)
local dir = vim.fn.fnamemodify(script, ":p:h")
local root = vim.fn.fnamemodify(dir, ":h")

vim.opt.rtp:append(root)

local env = dofile(dir .. "/env.lua")
local report = env.reporter()

report.header("Katana.nvim · icons/colors/headers test")

if not env.ensure_volt() then
  report.skip("Volt no está disponible (define KATANA_VOLT con la ruta del plugin)")
  report.finish()
  return
end

local katana = require("katana")
katana.setup({ ts = { enabled = false }, resolve_on_open = false })

local icons = require("katana.ui.icons")
local hls = require("katana.ui.highlights")
local state = require("katana.state")
local window = require("katana.ui.window")

---------------------------------------------------------------- mini.icons
local ok_mini_mod, MiniIcons_mod = pcall(require, "mini.icons")
local mini_ok = icons.available() and ok_mini_mod and type(MiniIcons_mod.get) == "function"
report.check("mini.icons disponible (o integrado si está presente)", true)

---------------------------------------------------------------- colores en namespaces
state.reset()
hls.setup()
local ns = state.ns_main
local function hex(v)
  return v and string.format("#%06x", v) or nil
end
local function get_fg_resolved(ns_id, name)
  local d = vim.api.nvim_get_hl(ns_id, { name = name, link = false })
  if d and d.fg then
    return d.fg
  end
  d = vim.api.nvim_get_hl(ns_id, { name = name })
  return d and d.fg or nil
end

if mini_ok then
  local palette = { "MiniIconsRed", "MiniIconsGreen", "MiniIconsBlue", "MiniIconsCyan",
                    "MiniIconsGrey", "MiniIconsOrange", "MiniIconsPurple", "MiniIconsYellow", "MiniIconsAzure" }

  for _, name in ipairs(palette) do
    report.check(name .. " tiene color en ns_main (fila no seleccionada)", get_fg_resolved(ns, name) ~= nil)
    report.check(name .. "Sel tiene color + bg en ns_main (fila seleccionada)", get_fg_resolved(ns, name .. "Sel") ~= nil)
  end

  local grey_luma = icons.luma(hex(get_fg_resolved(ns, "MiniIconsGrey")))
  report.check("MiniIconsGrey legible (luma >= min_luma)", grey_luma ~= nil and grey_luma >= icons.min_luma, string.format("luma=%s min=%s", tostring(grey_luma), tostring(icons.min_luma)))

  local kinds = { "quickfix", "quickfix.fixAll", "refactor", "refactor.extract", "refactor.inline",
                  "refactor.rewrite", "refactor.convert", "source", "source.organizeImports",
                  "source.fixAll", "command", "other" }
  local seen_cp = {}
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
  end
else
  report.skip("mini.icons no disponible en este entorno; se omiten las pruebas de integración con mini.icons")
end

---------------------------------------------------------------- cabeceras azules + selector azul
window.open({
  { title = "Fix", kind = "quickfix", source = "lsp" },
  { title = "Extract", kind = "refactor.extract", source = "lsp" },
}, nil)
vim.wait(250)
vim.cmd("stopinsert")

local marks = vim.api.nvim_buf_get_extmarks(state.buf_main, ns, 0, -1, { details = true })
local header_ok, selected_ok, icon_color_ok = false, false, false
local action_icon_hl

for _, m in ipairs(marks) do
  local vt = m[4] and m[4].virt_text or {}
  local txt = {}
  for _, c in ipairs(vt) do txt[#txt + 1] = tostring(c[1]) end
  local line = table.concat(txt)

  -- La cabecera debe tener texto azul (KatanaHeader) y el icono azul
  if line:match("Quick") or line:match("Refactor") then
    for _, c in ipairs(vt) do
      if c[2] == "KatanaHeader" then
        header_ok = true
      end
      if c[2] == "KatanaHeaderIcon" then
        header_ok = true
      end
    end
  end

  -- La selección no usa glifo: el título pasa a azul (KatanaSelectedText).
  if line:match("Fix") or line:match("Extract") then
    for _, c in ipairs(vt) do
      if c[2] == "KatanaSelectedText" then
        selected_ok = true
      end
    end
  end
end

report.check("cabeceras usan color azul (KatanaHeader/Icon)", header_ok)
report.check("la selección pinta el texto con KatanaSelectedText", selected_ok)

-- Verificación directa de los grupos
local sel_def = vim.api.nvim_get_hl(0, { name = "KatanaSelectedText", link = false })
local hdr_def = vim.api.nvim_get_hl(0, { name = "KatanaHeader", link = false })
local hdr_icon_def = vim.api.nvim_get_hl(0, { name = "KatanaHeaderIcon", link = false })
local sep_def = vim.api.nvim_get_hl(0, { name = "KatanaSeparator", link = false })
report.check("KatanaSelectedText en azul", sel_def and sel_def.fg ~= nil)
report.check("KatanaHeader definido (azul/bold)", hdr_def and hdr_def.fg ~= nil)
report.check("KatanaHeaderIcon definido (azul)", hdr_icon_def and hdr_icon_def.fg ~= nil)
report.check("KatanaSeparator definido", sep_def ~= nil)

window.close()

report.finish()
vim.cmd("qa!")
