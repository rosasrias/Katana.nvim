---@mod katana.ui.list Renderizado de la lista de acciones
---
--- La lista se dibuja con **texto real en el buffer** y `nvim_buf_set_extmark`
--- para los colores. No depende de Volt ni de ningún plugin de UI: funciona con
--- la interfaz nativa de Neovim (flotantes + extmarks).
---
--- Cada fila se construye como una lista de *chunks* `{ texto, grupo_hl }`. A
--- partir de ellos se genera la línea plana (para el buffer) y los extmarks (para
--- el color). Así el resaltado y el texto siempre coinciden.

local api = vim.api

local state = require("katana.state")
local config = require("katana.config")
local hls = require("katana.ui.highlights")

local M = {}

--------------------------------------------------------------------------
-- Utilidades de texto
--------------------------------------------------------------------------

--- Ancho en celdas de pantalla de un texto.
---@param text string
---@return integer
local function display_width(text)
  return vim.fn.strdisplaywidth(text)
end

--- Recorta un texto a `width` celdas, añadiendo `…` si sobra contenido.
---@param text string
---@param width integer
---@return string
local function truncate(text, width)
  if width <= 0 then
    return ""
  end
  if display_width(text) <= width then
    return text
  end
  if width == 1 then
    return "…"
  end

  local out = {}
  local used = 0
  local count = vim.fn.strchars(text)

  for i = 0, count - 1 do
    local char = vim.fn.strcharpart(text, i, 1)
    local w = display_width(char)
    if used + w > width - 1 then
      break
    end
    out[#out + 1] = char
    used = used + w
  end

  return table.concat(out) .. "…"
end

--- Ajusta una lista de chunks al ancho disponible, recortando el último.
---@param chunks table[] lista de `{ texto, hl }`
---@param width integer
---@return table[] chunks ajustados
local function fit(chunks, width)
  local out = {}
  local used = 0

  for _, chunk in ipairs(chunks) do
    local w = display_width(chunk[1])
    if used + w <= width then
      out[#out + 1] = chunk
      used = used + w
    else
      local rest = truncate(chunk[1], width - used)
      if rest ~= "" then
        out[#out + 1] = { rest, chunk[2] }
      end
      break
    end
  end

  return out
end

---@param chunks table[]
---@return string
local function chunks_text(chunks)
  local parts = {}
  for i, chunk in ipairs(chunks) do
    parts[i] = chunk[1]
  end
  return table.concat(parts)
end

--------------------------------------------------------------------------
-- Datos de la acción
--------------------------------------------------------------------------

--- Icono y grupo de color de una acción según su kind.
---@param action KatanaAction
---@return string icon
---@return string hl_group
local function action_icon(action)
  local utils = require("katana.utils")

  local icon, hl = require("katana.ui.icons").get(action.kind)
  if icon then
    return icon, hl
  end

  local icons = config.options.icons or {}
  local group = utils.kind_group_key(action.kind)

  return icons[action.kind] or icons[group] or icons.other or "", hls.hl_group_for(group)
end

--- Texto con el origen (cliente LSP, proveedor, ...) de la acción.
---@param action KatanaAction
---@return string
local function action_source(action)
  if type(action.sources) == "table" and #action.sources > 1 then
    return table.concat(action.sources, ", ")
  end
  return action.source or ""
end

--- Divide el título marcando los tramos entre backticks con otro color.
---@param title string
---@param selected boolean
---@return table[] chunks
local function title_chunks(title, selected)
  local base = selected and "KatanaSelectedText" or "KatanaTitle"
  local code = selected and "KatanaSelectedCode" or "KatanaCode"
  local chunks = {}
  local pos = 1

  while true do
    local start_pos, end_pos = title:find("`[^`]+`", pos)
    if not start_pos then
      break
    end
    if start_pos > pos then
      chunks[#chunks + 1] = { title:sub(pos, start_pos - 1), base }
    end
    chunks[#chunks + 1] = { title:sub(start_pos, end_pos), code }
    pos = end_pos + 1
  end

  if pos <= #title then
    chunks[#chunks + 1] = { title:sub(pos), base }
  end
  if #chunks == 0 then
    chunks[1] = { title, base }
  end

  return chunks
end

--------------------------------------------------------------------------
-- Construcción de filas
--------------------------------------------------------------------------

--- Construye las filas de la lista a partir de `state.flat`.
---@param limit integer|nil número máximo de filas
---@return table[] filas `{ text = string, chunks = table[] }`
function M.build(limit)
  local opts = config.options
  local rows = {}
  local width = math.max(10, state.list_width or 40)

  local num_width = 0
  if opts.num_shortcuts and #state.flat > 0 then
    num_width = #tostring(#state.flat)
  end

  -- Contador de atajos numéricos: sólo cuentan las acciones, no las cabeceras.
  local action_index = 0

  for i, item in ipairs(state.flat) do
    if limit and i > limit then
      break
    end

    if item.type == "header" then
      local group = item.group
      local label = group.label
      local icon, icon_hl = action_icon({ kind = group.key })
      local rule_len = math.max(0, width - display_width(label) - 6)

      local chunks = {
        { "  " },
        { icon .. " ", icon_hl },
        { label, "KatanaHeader" },
        { " " },
        { string.rep("─", rule_len), "KatanaSeparator" },
      }

      rows[#rows + 1] = { chunks = fit(chunks, width) }
    elseif item.type == "action" then
      local action = item.action
      action_index = action_index + 1
      local selected = i == state.index

      local title = require("katana.utils").compact_title(action.title) or ""
      local icon, hl_icon = action_icon(action)

      local chunks = {}

      -- Barra de selección a la izquierda.
      chunks[#chunks + 1] = { selected and "▎" or " ", selected and "KatanaAccent" or nil }

      -- Atajo numérico (dim).
      if opts.num_shortcuts then
        local num = action_index <= 9 and tostring(action_index) or " "
        chunks[#chunks + 1] = { string.format("%" .. num_width .. "s ", num), selected and "KatanaSelectedNum" or "KatanaNum" }
      end

      -- Icono del kind (conserva su color incluso en la fila activa).
      chunks[#chunks + 1] = { icon .. " ", hls.selected_hl_for(hl_icon, selected) }

      -- Título, con los tramos `code` resaltados.
      for _, chunk in ipairs(title_chunks(title, selected)) do
        chunks[#chunks + 1] = chunk
      end

      -- Sufijos: preferida, marcador de variantes y origen.
      local suffix = {}
      if opts.show_preferred and action.isPreferred then
        suffix[#suffix + 1] = { " " .. ((opts.icons or {}).preferred or "*"), selected and "KatanaSelectedPreferred" or "KatanaPreferred" }
      end
      if type(action.variants) == "table" and #action.variants > 0 then
        suffix[#suffix + 1] = { " ►", "KatanaArrow" }
      end

      local source = ""
      if opts.show_server_name then
        source = action_source(action)
      end

      local main_width = display_width(chunks_text(chunks)) + display_width(chunks_text(suffix))
      local source_width = display_width(source)

      if source ~= "" then
        local pad = width - main_width - source_width - 1
        if pad >= 1 then
          -- Origen alineado a la derecha, como una columna de metadatos.
          chunks[#chunks + 1] = { string.rep(" ", pad) }
        else
          -- Sin sitio para alinearlo: al menos un separador antes del origen.
          chunks[#chunks + 1] = { " " }
        end
        chunks[#chunks + 1] = { source, selected and "KatanaSelectedSource" or "KatanaSourceName" }
      end

      for _, chunk in ipairs(suffix) do
        chunks[#chunks + 1] = chunk
      end

      chunks = fit(chunks, width)
      rows[#rows + 1] = { chunks = chunks }
    end
  end

  if #rows == 0 then
    local message = state.query ~= "" and "No matching actions" or "No actions available"
    rows[1] = { chunks = { { "  " .. message, "KatanaEmpty" } } }
  end

  for _, row in ipairs(rows) do
    row.text = chunks_text(row.chunks)
  end

  return rows
end

--- Compatibilidad: filas como listas de chunks (sin el campo `text`).
---@param limit integer|nil
---@return table[][]
function M.rows(limit)
  local rows = M.build(limit)
  local out = {}
  for i, row in ipairs(rows) do
    out[i] = row.chunks
  end
  return out
end

--------------------------------------------------------------------------
-- Dibujado
--------------------------------------------------------------------------

--- Redibuja la lista en el buffer.
---
--- El buffer contiene *todas* las filas; la ventana muestra como mucho
--- `state.max_rows`. Al filtrar cambia el número de filas, así que se reescribe
--- el buffer y se recolocan los extmarks.
function M.render()
  local buf = state.buf_main
  local win = state.win_main

  if not buf or not api.nvim_buf_is_valid(buf) then
    return
  end

  local visible = math.max(1, math.min(#state.flat, state.max_rows or 1))

  if win and api.nvim_win_is_valid(win) then
    pcall(api.nvim_win_set_height, win, visible)
  end

  -- El preview se mantiene a la misma altura que la lista.
  if state.win_preview and api.nvim_win_is_valid(state.win_preview) then
    pcall(api.nvim_win_set_height, state.win_preview, visible)
  end

  local rows = M.build()
  local lines = {}
  for i, row in ipairs(rows) do
    lines[i] = row.text
  end

  api.nvim_buf_clear_namespace(buf, state.ns_main, 0, -1)

  vim.bo[buf].modifiable = true
  local ok, err = pcall(api.nvim_buf_set_lines, buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  if not ok then
    pcall(function()
      vim.notify("Katana: error al dibujar la lista: " .. tostring(err), vim.log.levels.ERROR)
    end)
    return
  end

  vim.bo[buf].modified = false

  for i, row in ipairs(rows) do
    local col = 0
    for _, chunk in ipairs(row.chunks) do
      local text, hl = chunk[1], chunk[2]
      if hl and hl ~= "" and #text > 0 then
        pcall(api.nvim_buf_set_extmark, buf, state.ns_main, i - 1, col, {
          end_col = col + #text,
          hl_group = hl,
          priority = 200,
        })
      end
      col = col + #text
    end

    local item = state.flat[i]
    if item and item.type == "action" and i == state.index then
      pcall(api.nvim_buf_set_extmark, buf, state.ns_main, i - 1, 0, {
        end_col = #row.text,
        line_hl_group = "KatanaRow",
        hl_eol = true,
        priority = 150,
      })
    end
  end

  M.sync_cursor()
end

--- Coloca el cursor de la ventana de lista en la fila activa.
function M.sync_cursor()
  if state.win_main and api.nvim_win_is_valid(state.win_main) then
    pcall(api.nvim_win_set_cursor, state.win_main, { math.max(1, state.index), 0 })
  end
end

--- Marca la fila seleccionada y la deja a la vista.
function M.update_selection()
  M.render()
end

--- Selecciona la fila bajo el cursor (clic de ratón).
---@param row integer fila 1-based
---@return boolean
function M.select_row(row)
  local item = state.flat[row]
  if not item or item.type ~= "action" then
    return false
  end

  state.index = row
  M.update_selection()
  return true
end

return M
