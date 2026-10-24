-- Prueba de la UI nativa del picker de Katana: ventanas, render, agrupación,
-- filtro en vivo, preview reactivo, confirmación y undo agrupado.
--
--   nvim --headless -u NONE -l scripts/ui.lua
--
-- No requiere Volt: la lista se dibuja con texto real y extmarks nativos.

local script = debug.getinfo(1, "S").source:sub(2)
local dir = vim.fn.fnamemodify(script, ":p:h")
local root = vim.fn.fnamemodify(dir, ":h")

vim.opt.rtp:append(root)

local env = dofile(dir .. "/env.lua")
local report = env.reporter()

report.header("Katana.nvim · UI test")

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

local selected = nil
window.open(actions, function(action)
  selected = action
  apply.execute(action, { bufnr = bufnr, win = origin_win })
end)

report.check("picker abierto", window.is_open())
report.check("4 ventanas (original, lista, prompt, preview)", #vim.api.nvim_list_wins() == 4, #vim.api.nvim_list_wins())
report.check("buffer de lista creado", state.buf_main ~= nil and vim.api.nvim_buf_is_valid(state.buf_main))
report.check("buffer de prompt creado", state.buf_prompt ~= nil and vim.api.nvim_buf_is_valid(state.buf_prompt))
report.check("prompt en modo prompt", vim.bo[state.buf_prompt].buftype == "prompt", vim.bo[state.buf_prompt].buftype)
report.check("prompt enfocado", vim.api.nvim_get_current_win() == state.win_prompt)
report.check("buffer de preview creado", state.buf_preview ~= nil and vim.api.nvim_buf_is_valid(state.buf_preview))
report.check("métrica de apertura registrada (ms)", type(state.last.open_ms) == "number", state.last.open_ms)

--- Texto renderizado en cada fila (ahora es texto real del buffer).
local function rows_text()
  return vim.api.nvim_buf_get_lines(state.buf_main, 0, -1, false)
end

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

--- Grupos de resaltado presentes en una fila (extmarks nativos).
local function row_hls(row)
  local marks = vim.api.nvim_buf_get_extmarks(state.buf_main, state.ns_main, 0, -1, { details = true })
  local names = {}
  for _, m in ipairs(marks) do
    if m[2] + 1 == row then
      local details = m[4] or {}
      if details.hl_group then
        names[#names + 1] = details.hl_group
      end
      if details.line_hl_group then
        names[#names + 1] = details.line_hl_group
      end
    end
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

--- Fila de la acción seleccionada (la que lleva la barra).
local function active_row()
  for i = 1, #state.flat do
    if has_hl(i, "KatanaAccent") then
      return i
    end
  end
  return nil
end

local active = active_row()
report.check("la fila activa lleva la barra KatanaAccent", active ~= nil, tostring(active))
report.check("el fondo de la fila activa está en el texto", has_hl(active, "KatanaSelectedText"))
report.check("la fila activa no es una cabecera", state.flat[state.index].type == "action")

--- El icono conserva su color propio en la fila seleccionada.
local icon_sel = nil
for _, n in ipairs(row_hls(active)) do
  if n and n:match("^Katana%w+Sel$") then
    icon_sel = n
  end
end
report.check("el icono usa su variante seleccionada", icon_sel ~= nil, tostring(icon_sel))

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
report.check("mover la selección mueve la barra", before ~= after, string.format("%s -> %s", tostring(before), tostring(after)))
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

local rl, rp, rr = rect(state.win_main), rect(state.win_prompt), rect(state.win_preview)
report.check("lista y prompt no se solapan", not overlaps(rl, rp), vim.inspect({ rl, rp }))
report.check("lista y preview no se solapan", not overlaps(rl, rr), vim.inspect({ rl, rr }))
report.check("prompt y preview no se solapan", not overlaps(rp, rr), vim.inspect({ rp, rr }))

--- Preview reactivo: muestra el diff de la acción seleccionada.
local preview_text = table.concat(vim.api.nvim_buf_get_lines(state.buf_preview, 0, -1, false), "\n")
report.check("preview con diff", preview_text:find("UNO") ~= nil, preview_text:sub(1, 80))
report.check("preview con cabeceras unified", preview_text:find("--- a/") ~= nil)

--- Filtro en vivo.
vim.api.nvim_buf_set_lines(state.buf_prompt, 0, 1, false, { "extract" })
vim.api.nvim_exec_autocmds("TextChangedI", { buffer = state.buf_prompt })
local total_actions = 0
for _, item in ipairs(state.flat) do
  if item.type == "action" then
    total_actions = total_actions + 1
  end
end
report.check("filtro reduce la lista", total_actions == 1, total_actions)
report.check("fila filtrada correcta", rows_contain("Extract function"))

--- Filtro sin resultados.
vim.api.nvim_buf_set_lines(state.buf_prompt, 0, 1, false, { "zzz" })
vim.api.nvim_exec_autocmds("TextChangedI", { buffer = state.buf_prompt })
report.check("filtro sin coincidencias (lista vacía)", #state.flat == 0, #state.flat)
report.check("placeholder sin resultados", rows_contain("No matching actions"))

--- Restablecer el filtro.
vim.api.nvim_buf_set_lines(state.buf_prompt, 0, 1, false, { "" })
vim.api.nvim_exec_autocmds("TextChangedI", { buffer = state.buf_prompt })
report.check("filtro restablecido", #state.flat == 8, #state.flat)

--- El prefijo del prompt no debe contar como filtro.
---
--- Neovim guarda la línea del buffer `buftype=prompt` **con el prefijo delante**
--- (`prompt_setprompt`), así que leer la línea cruda da `" > "` con el filtro
--- vacío: ninguna acción coincide y la lista queda en *No matching actions*.
local prompt_prefix = vim.fn.prompt_getprompt(state.buf_prompt)
report.check("el prefijo forma parte de la línea", prompt_prefix ~= "", prompt_prefix)

vim.api.nvim_buf_set_lines(state.buf_prompt, 0, 1, false, { prompt_prefix })
vim.api.nvim_exec_autocmds("TextChangedI", { buffer = state.buf_prompt })
report.check("prefijo solo (filtro vacío)", state.query == "", string.format("%q", state.query))
report.check("prefijo solo no filtra", #state.flat == 8, #state.flat)

vim.api.nvim_buf_set_lines(state.buf_prompt, 0, 1, false, { prompt_prefix .. "extract" })
vim.api.nvim_exec_autocmds("TextChangedI", { buffer = state.buf_prompt })
report.check("prefijo + texto", state.query == "extract", string.format("%q", state.query))
report.check("prefijo + texto filtra bien", #state.flat >= 1 and rows_contain("Extract function"))

vim.api.nvim_buf_set_lines(state.buf_prompt, 0, 1, false, { prompt_prefix })
vim.api.nvim_exec_autocmds("TextChangedI", { buffer = state.buf_prompt })
report.check("vuelta al filtro vacío", #state.flat == 8, #state.flat)

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

vim.cmd("undo")
report.check("un solo `u` revierte la acción", vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1] == "uno")

--- Reapertura: el picker se puede volver a abrir tras cerrarlo.
window.open(actions, function() end)
report.check("reapertura del picker", window.is_open() and #vim.api.nvim_list_wins() == 4, #vim.api.nvim_list_wins())
window.close()
report.check("cierre del picker", not window.is_open() and #vim.api.nvim_list_wins() == 1, #vim.api.nvim_list_wins())

report.finish()
