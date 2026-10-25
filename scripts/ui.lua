-- Prueba de la UI del picker de Katana (Volt): ventanas, render, agrupación,
-- preview reactivo, confirmación y undo agrupado.
--
--   nvim --headless -u NONE -l scripts/ui.lua
--
-- Requiere el plugin Volt. Se busca en el `runtimepath` y, si no está, en las
-- rutas habituales de lazy.nvim. Se puede forzar con `KATANA_VOLT=/ruta`.

local script = debug.getinfo(1, "S").source:sub(2)
local dir = vim.fn.fnamemodify(script, ":p:h")
local root = vim.fn.fnamemodify(dir, ":h")

vim.opt.rtp:append(root)

local env = dofile(dir .. "/env.lua")
local report = env.reporter()

report.header("Katana.nvim · UI test")

if not env.ensure_volt() then
  report.skip("Volt no está disponible (define KATANA_VOLT con la ruta del plugin)")
  report.finish()
  return
end

local katana = require("katana")
katana.setup({ ts = { enabled = false }, resolve_on_open = false })

local state = require("katana.state")
local window = require("katana.ui.window")
local apply = require("katana.apply")

-- Buffer de trabajo con contenido para el preview.
local tmp = vim.fn.tempname() .. ".lua"
vim.fn.writefile({ "uno", "dos", "tres" }, tmp)
vim.cmd("edit " .. vim.fn.fnameescape(tmp))
local bufnr = vim.api.nvim_get_current_buf()
local origin_win = vim.api.nvim_get_current_win()

local function make_action(title, kind, source, newtext)
  return {
    title = title,
    kind = kind,
    source = source,
    encoding = "utf-16",
    _client_name = (source:gsub("^lsp:", "")),
    edit = {
      changes = {
        [vim.uri_from_fname(tmp)] = {
          {
            range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 3 } },
            newText = newtext or "UNO",
          },
        },
      },
    },
  }
end

local actions = {
  make_action("Fix typo", "quickfix", "lsp:lua_ls", "UNO"),
  make_action("Extract function", "refactor.extract", "lsp:lua_ls"),
  make_action("Organize imports", "source.organizeImports", "lsp:lua_ls"),
  make_action("Provider action", "source", "provider:mi"),
}

local gcr_before = vim.o.guicursor

local selected = nil
window.open(actions, function(action)
  selected = action
  apply.execute(action, { bufnr = bufnr, win = origin_win })
end)

report.check("picker abierto", window.is_open())
report.check("3 ventanas (original, lista, preview)", #vim.api.nvim_list_wins() == 3, #vim.api.nvim_list_wins())
report.check("buffer de lista creado", state.buf_main ~= nil and vim.api.nvim_buf_is_valid(state.buf_main))
report.check("lista enfocada", vim.api.nvim_get_current_win() == state.win_main)
report.check("sin ventana de filtro", state.win_prompt == nil and state.buf_prompt == nil)
report.check("buffer de preview creado", state.buf_preview ~= nil and vim.api.nvim_buf_is_valid(state.buf_preview))

--- Los grupos `Katana*` se definen en el namespace global: es el que usan los
--- extmarks al resolver el resaltado (definirlos en un namespace propio sin
--- asignarlo a la ventana dejaría la lista sin color).
report.check(
  "los grupos del picker son globales",
  vim.api.nvim_get_hl(0, { name = "KatanaSelectedText", link = false }).fg ~= nil
)

--- Sin cursor visible en la lista: `guicursor` apunta a un grupo con el fondo
--- de la fila activa, así no queda una raya gris junto al número.
report.check("cursor oculto en la lista", vim.o.guicursor:find("KatanaCursor") ~= nil, vim.o.guicursor)
local cursor_hl = vim.api.nvim_get_hl(0, { name = "KatanaCursor", link = false })
local row_hl = vim.api.nvim_get_hl(0, { name = "KatanaRow", link = false })
report.check(
  "el cursor usa el fondo de la fila activa",
  cursor_hl.bg ~= nil and cursor_hl.bg == row_hl.bg,
  string.format("cursor=%s fila=%s", tostring(cursor_hl.bg), tostring(row_hl.bg))
)

--- Texto renderizado por Volt en cada fila.
local function rows_text()
  local marks = vim.api.nvim_buf_get_extmarks(state.buf_main, state.ns_main, 0, -1, { details = true })
  local rows = {}
  for _, m in ipairs(marks) do
    local chunks = m[4] and m[4].virt_text or {}
    local text = {}
    for _, chunk in ipairs(chunks) do
      text[#text + 1] = chunk[1]
    end
    rows[m[2] + 1] = table.concat(text)
  end
  return rows
end

--- Sin margen a la izquierda: la fila empieza en el número.
local all_rows = rows_text()
report.check("la fila empieza en el número", (all_rows[2] or ""):sub(1, 2) == "1.", string.format("%q", (all_rows[2] or ""):sub(1, 8)))
report.check("la cabecera no lleva margen", (all_rows[1] or ""):sub(1, 1) ~= " ", string.format("%q", (all_rows[1] or ""):sub(1, 8)))
report.check(
  "el cursor no queda junto al número",
  vim.api.nvim_win_get_cursor(state.win_main)[2] > 0,
  vim.api.nvim_win_get_cursor(state.win_main)[2]
)

local function rows_contain(needle)
  for _, text in ipairs(rows_text()) do
    if text and text:find(needle, 1, true) then
      return true
    end
  end
  return false
end

local rows = rows_text()
report.check("filas renderizadas", rows and #rows > 0, rows and #rows or 0)
report.check("cabecera de grupo quickfix", (rows[1] or ""):find("Quick Fix") ~= nil, rows[1])
report.check("icono + título en la acción", (rows[2] or ""):find("Fix typo") ~= nil, rows[2])
report.check("origen visible", (rows[2] or ""):find("lsp:lua_ls") ~= nil, rows[2])
report.check("agrupación: 4 acciones + 4 cabeceras", #state.flat == 8, #state.flat)

--- Aspecto: selección en azul, colores por kind y regla de las cabeceras.
---@return table[] marcas de la fila `row` (1-based)
local function row_marks(row)
  local marks = vim.api.nvim_buf_get_extmarks(state.buf_main, state.ns_main, 0, -1, { details = true })
  for _, m in ipairs(marks) do
    if m[2] + 1 == row then
      return m[4] and m[4].virt_text or {}
    end
  end
  return {}
end

--- Grupos de resaltado presentes en una fila.
local function row_hls(row)
  local names = {}
  for _, chunk in ipairs(row_marks(row)) do
    names[#names + 1] = chunk[2]
  end
  return names
end

local function has_hl(row, name)
  for _, n in ipairs(row_hls(row)) do
    if n == name then
      return true
    end
  end
  return false
end

--- Fila de la acción seleccionada (la que pinta el texto en azul).
local function active_row()
  for i = 1, #state.flat do
    if has_hl(i, "KatanaSelectedText") then
      return i
    end
  end
  return nil
end

local function row_text(row)
  local text = {}
  for _, chunk in ipairs(row_marks(row)) do
    text[#text + 1] = tostring(chunk[1])
  end
  return table.concat(text)
end

local active = active_row()
report.check("la fila activa usa KatanaSelectedText", active ~= nil, tostring(active))
report.check("la fila activa no lleva selector ▎", not row_text(active):find("▎"), row_text(active))
report.check("el fondo de la fila activa está en el texto", has_hl(active, "KatanaRow"))
report.check("la fila activa no es una cabecera", state.flat[state.index].type == "action")

--- El icono conserva su color propio en la fila seleccionada.
local icon_sel = nil
for _, n in ipairs(row_hls(active)) do
  if n and n:match("^Katana%w+Sel$") then
    icon_sel = n
  end
end
report.check("el icono usa su variante seleccionada", icon_sel ~= nil, tostring(icon_sel))

--- El texto de la fila activa va en azul (no en blanco como el resto).
local sel_text = vim.api.nvim_get_hl(0, { name = "KatanaSelectedText", link = false })
local title_def = vim.api.nvim_get_hl(0, { name = "KatanaTitle", link = false })
report.check(
  "el texto de la fila activa es azul",
  sel_text.fg ~= nil and sel_text.fg ~= title_def.fg,
  string.format("sel=%s title=%s", tostring(sel_text.fg), tostring(title_def.fg))
)
report.check("la fila activa conserva el fondo propio", sel_text.bg ~= nil, tostring(sel_text.bg))

--- Cada kind tiene un color distinto para el icono.
local hl = require("katana.ui.highlights")
local seen = {}
local distinct = true
for _, key in ipairs({ "quickfix", "refactor.extract", "refactor.rewrite", "source", "command", "other" }) do
  local group = hl.hl_group_for(key)
  if seen[group] then
    distinct = false
  end
  seen[group] = true
end
report.check("cada kind tiene su grupo de color", distinct)

--- Las cabeceras llevan la regla separadora.
local header_row = nil
for i = 1, #state.flat do
  if state.flat[i].type == "header" then
    header_row = i
    break
  end
end
report.check("la cabecera lleva la regla KatanaSeparator", has_hl(header_row, "KatanaSeparator"), tostring(header_row))

--- La selección se repinta al moverse.
local before = active_row()
require("katana.ui.mappings").move(1)
local after = active_row()
report.check("mover la selección mueve el texto azul", before ~= after, string.format("%s -> %s", tostring(before), tostring(after)))
report.check("el fondo sigue a la fila nueva", has_hl(after, "KatanaSelectedText"))
require("katana.ui.mappings").move(-1)

--- Geometría: las ventanas no se solapan.
---@return integer[] {fila, columna, alto, ancho}
local function rect(win)
  local pos = vim.api.nvim_win_get_position(win)
  return { pos[1], pos[2], vim.api.nvim_win_get_height(win), vim.api.nvim_win_get_width(win) }
end

local function overlaps(a, b)
  return a[1] < b[1] + b[3] and b[1] < a[1] + a[3] and a[2] < b[2] + b[4] and b[2] < a[2] + a[4]
end

local rl, rr = rect(state.win_main), rect(state.win_preview)
report.check("lista y preview no se solapan", not overlaps(rl, rr), vim.inspect({ rl, rr }))

--- Disposición por defecto: el preview va **debajo** de la lista.
local cfg = require("katana.config").options
report.check("preview_split por defecto horizontal", cfg.preview_split == "horizontal", cfg.preview_split)
report.check(
  "preview debajo de la lista (misma columna, fila posterior)",
  rr[2] == rl[2] and rr[1] >= rl[1] + rl[3],
  vim.inspect({ list = rl, preview = rr })
)
report.check(
  "preview respeta preview_max_height",
  rr[3] <= cfg.preview_max_height,
  string.format("%d <= %d", rr[3], cfg.preview_max_height)
)
report.check(
  "lista con alto acotado (list_max_height)",
  rl[3] <= cfg.list_max_height,
  string.format("%d <= %d", rl[3], cfg.list_max_height)
)

--- Con pantalla de sobra, la lista usa exactamente `list_max_height` filas: el
--- alto no depende del número de acciones.
local saved_lines = vim.o.lines
vim.o.lines = 60
local big = require("katana.ui.layout").compute()
vim.o.lines = saved_lines
report.check(
  "alto de lista estable en pantalla grande",
  big.list_height == cfg.list_max_height,
  string.format("%d == %d", big.list_height, cfg.list_max_height)
)
report.check(
  "preview debajo también con panel máximo",
  big.preview.row > big.list.row + big.list.height - 1,
  vim.inspect({ list = big.list, preview = big.preview })
)

--- El preview hace scroll dentro de su ventana si el diff no cabe.
local function preview_top()
  return vim.api.nvim_win_call(state.win_preview, function()
    return vim.fn.line("w0")
  end)
end

local preview = require("katana.preview.diff")
local long_lines = {}
for i = 1, 80 do
  long_lines[i] = "+line " .. i
end
vim.bo[state.buf_preview].modifiable = true
vim.api.nvim_buf_set_lines(state.buf_preview, 0, -1, false, long_lines)
vim.bo[state.buf_preview].modifiable = false

local top_before = preview_top()
preview.scroll(3)
local top_after = preview_top()
report.check("preview.scroll desplaza el contenido", top_after == top_before + 3, string.format("%d -> %d", top_before, top_after))

preview.update()
report.check("preview.update vuelve al principio", preview_top() == 1, preview_top())

--- Preview reactivo: muestra el diff de la acción seleccionada.
local preview_text = table.concat(vim.api.nvim_buf_get_lines(state.buf_preview, 0, -1, false), "\n")
report.check("preview con diff", preview_text:find("UNO") ~= nil, preview_text:sub(1, 80))
report.check("preview con cabeceras unified", preview_text:find("--- a/") ~= nil)

--- Sin filtro: todas las acciones están siempre en la lista.
local total_actions = 0
for _, item in ipairs(state.flat) do
  if item.type == "action" then
    total_actions = total_actions + 1
  end
end
report.check("sin filtro: todas las acciones visibles", total_actions == 4, total_actions)
report.check("la lista no expone ventana de filtro", state.win_prompt == nil)

--- La selección siempre cae en una acción (nunca en una cabecera).
local function selected_title()
  local item = state.flat[state.index]
  return item and item.type == "action" and item.action.title or "<cabecera>"
end

report.check("selección inicial en una acción", selected_title() == "Fix typo", selected_title())
require("katana.ui.mappings").move(1)
report.check("movimiento de selección (salta cabeceras)", selected_title() == "Extract function", selected_title())

--- Confirmación: cierra el picker y ejecuta la acción.
window.confirm()
vim.wait(200, function()
  return selected ~= nil
end)
report.check("acción ejecutada", selected ~= nil and selected.title == "Extract function", selected and selected.title)
report.check("picker cerrado", not window.is_open())
local after = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
report.check("edit aplicado en el buffer", after[1] == "UNO", vim.inspect(after))
report.check("foco devuelto al buffer original", vim.api.nvim_get_current_buf() == bufnr)
report.check("ventanas cerradas", #vim.api.nvim_list_wins() == 1, #vim.api.nvim_list_wins())
report.check("guicursor restaurado al cerrar", vim.o.guicursor == gcr_before, vim.o.guicursor)

vim.cmd("undo")
report.check("un solo `u` revierte la acción", vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1] == "uno")

--- Reapertura: el picker se puede volver a abrir tras cerrarlo.
window.open(actions, function() end)
report.check("reapertura del picker", window.is_open() and #vim.api.nvim_list_wins() == 3, #vim.api.nvim_list_wins())
window.close()
report.check("cierre del picker", not window.is_open() and #vim.api.nvim_list_wins() == 1, #vim.api.nvim_list_wins())

--------------------------------------------------------------------------------
-- Ciclo de vida: reapertura, cierre idempotente y apertura fallida.
--------------------------------------------------------------------------------

--- Reabrir con el picker ya abierto desmonta el anterior: no quedan ventanas
--- ni buffers huérfanos.
window.open(actions, function() end)
local first_buf = state.buf_main
local first_win = state.win_main
window.open(actions, function() end)
report.check(
  "reapertura con picker abierto no duplica ventanas",
  window.is_open() and #vim.api.nvim_list_wins() == 3,
  #vim.api.nvim_list_wins()
)
report.check(
  "reapertura reemplaza buffer y ventana anteriores",
  state.buf_main ~= first_buf and state.win_main ~= first_win and not vim.api.nvim_buf_is_valid(first_buf),
  string.format("buf %s -> %s", tostring(first_buf), tostring(state.buf_main))
)
report.check("reapertura enfoca la lista nueva", vim.api.nvim_get_current_win() == state.win_main)
window.close()
report.check("tras reabrir, el foco vuelve al origen", vim.api.nvim_get_current_win() == origin_win)

--- Cerrar dos veces (o sin picker) no debe fallar ni tocar nada.
report.check("close es idempotente", window.close() == true and window.close() == true)
report.check(
  "close sin picker no deja ventanas extra",
  not window.is_open() and #vim.api.nvim_list_wins() == 1,
  #vim.api.nvim_list_wins()
)

--- Un fallo a mitad de apertura (Volt) no deja ventanas, buffers ni guicursor.
local volt = require("volt")
local volt_run = volt.run
volt.run = function()
  error("fallo de Volt forzado por el test")
end
local open_ok, open_err = window.open(actions, function() end)
volt.run = volt_run

report.check("apertura fallida devuelve false y error", open_ok == false and type(open_err) == "string", tostring(open_err))
report.check("apertura fallida cierra el picker", not window.is_open())
report.check(
  "apertura fallida no deja ventanas",
  #vim.api.nvim_list_wins() == 1,
  #vim.api.nvim_list_wins()
)
report.check("apertura fallida no deja buffers de lista", state.buf_main == nil and state.buf_preview == nil)
report.check("apertura fallida restaura guicursor", vim.o.guicursor == gcr_before, vim.o.guicursor)
report.check("apertura fallida devuelve el foco al origen", vim.api.nvim_get_current_win() == origin_win)

--------------------------------------------------------------------------------
-- Atajos numéricos: una sola ejecución por pulsación.
--------------------------------------------------------------------------------

local shortcut_runs = {}
window.open(actions, function(action)
  shortcut_runs[#shortcut_runs + 1] = action.title
end)
require("katana.ui.mappings").select(2)
report.check(
  "atajo numérico ejecuta una sola acción",
  #shortcut_runs == 1 and shortcut_runs[1] == "Extract function",
  vim.inspect(shortcut_runs)
)
report.check("atajo numérico cierra el picker antes de ejecutar", not window.is_open() and #vim.api.nvim_list_wins() == 1)

-- Una segunda pulsación (o un callback que reentre) no vuelve a ejecutar.
require("katana.ui.mappings").select(2)
report.check("segunda pulsación no reejecuta", #shortcut_runs == 1, #shortcut_runs)

--------------------------------------------------------------------------------
-- Generaciones: una respuesta vieja no abre la UI ni avisa.
--------------------------------------------------------------------------------

local fetch = require("katana.core.fetch")

local function capture_notifications(fn)
  local messages = {}
  local notify = vim.notify
  vim.notify = function(msg)
    messages[#messages + 1] = msg
  end
  local ok, err = pcall(fn)
  vim.notify = notify
  assert(ok, err)
  return messages
end

fetch.new_generation()
local stale_token = fetch.new_generation() - 1
local stale_notifications = capture_notifications(function()
  katana._on_actions(actions, { bufnr = bufnr, win = origin_win }, nil, stale_token)
end)
report.check("respuesta de generación vieja no abre la UI", not window.is_open() and #vim.api.nvim_list_wins() == 1)
report.check("respuesta de generación vieja no avisa", #stale_notifications == 0, vim.inspect(stale_notifications))

--- El token vigente sí abre: el guardián no bloquea respuestas legítimas.
local live_token = fetch.new_generation()
katana._on_actions(actions, { bufnr = bufnr, win = origin_win }, nil, live_token)
report.check("respuesta de la generación vigente abre el picker", window.is_open())
window.close()
fetch.cancel()

--------------------------------------------------------------------------------
-- `hide_disabled`: filtrar antes de decidir si se abre la UI.
--------------------------------------------------------------------------------

local config = require("katana.config")
local hide_prev = config.options.hide_disabled
config.options.hide_disabled = true

local disabled = {
  { title = "off 1", kind = "quickfix", source = "lsp:x", disabled = true },
  { title = "off 2", kind = "source", source = "lsp:x", disabled = true },
}
local disabled_notifications = capture_notifications(function()
  katana._on_actions(disabled, { bufnr = bufnr, win = origin_win })
end)
report.check("todas deshabilitadas: un solo aviso", #disabled_notifications == 1, #disabled_notifications)
report.check("todas deshabilitadas: no se abre la UI", not window.is_open() and #vim.api.nvim_list_wins() == 1)
config.options.hide_disabled = hide_prev

--------------------------------------------------------------------------------
-- Preview cerrado: `update`/`scroll` no deben tocar ventanas inexistentes.
--------------------------------------------------------------------------------

report.check("preview.update no falla con el picker cerrado", pcall(preview.update))
report.check("preview.scroll no falla con el picker cerrado", pcall(preview.scroll, 3))

report.finish()
