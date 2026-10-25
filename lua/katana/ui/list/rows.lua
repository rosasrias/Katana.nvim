---@mod katana.ui.list.rows Construcción de filas de la lista
---
--- Convierte `state.flat` en los *marks* que Volt pinta como `virt_text`. Es una
--- función pura respecto del buffer: no escribe nada, sólo lee estado y opciones.
--- El ciclo de vida del dibujado vive en `katana.ui.list`.

local config = require("katana.config")
local hls = require("katana.ui.highlights")
local state = require("katana.state")

local M = {}

--- Icono y grupo de color de una acción según su kind.
---
--- Se prefiere **mini.icons** (glifos `nf-md-*` con su grupo `MiniIcons*`, que
--- NvChad ya colorea vía base46). Si no está disponible, se usan los glifos de
--- `config.options.icons` con los grupos `Katana*`.
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

---@param group table
---@return table[]
local function header_row(group)
  -- La cabecera usa el mismo icono y color que sus acciones, para que el grupo
  -- se reconozca de un vistazo. También empieza en la primera columna: no hay
  -- margen a la izquierda (ni hueco ni barra) delante del icono ni de los
  -- números.
  local icon, icon_hl = action_icon({ kind = group.key })
  local prefix = icon .. "  "
  local used = vim.fn.strwidth(prefix) + vim.fn.strwidth(group.label) + 1
  local width = math.max(0, (state.list_width or 40) - used)

  return {
    { prefix, icon_hl },
    { group.label, "KatanaHeader" },
    { " " .. string.rep("─", width), "KatanaSeparator" },
  }
end

---@param action KatanaAction
---@param index integer posición en `state.flat`
---@param action_index integer número visible (1..9) de la acción
---@param num_width integer
---@return table[]
local function action_row(action, index, action_index, num_width)
  local opts = config.options
  local utils = require("katana.utils")

  local title = utils.compact_title(action.title) or ""
  local icon, hl_icon = action_icon(action)
  local selected = index == state.index

  local num_str = ""
  if opts.num_shortcuts then
    if action_index <= 9 then
      num_str = string.format("%" .. num_width .. "s", tostring(action_index) .. ".")
    else
      num_str = string.rep(" ", num_width)
    end
  end

  local source_str = ""
  if opts.show_server_name then
    local source = action_source(action)
    if source ~= "" then
      source_str = "  " .. source
    end
  end

  local pref_str = ""
  if opts.show_preferred and action.isPreferred then
    pref_str = "  " .. ((opts.icons or {}).preferred or "*")
  end

  -- Al seleccionar, el texto pasa a azul (`KatanaSelected*`) sobre el fondo del
  -- resaltado; el icono conserva el color de su kind. Volt sólo admite
  -- `{ texto, hl_group, acciones }`, así que el fondo se resuelve con grupos de
  -- resaltado dedicados, no con opciones por mark.
  local title_hl = "KatanaTitle"
  if action.disabled then
    title_hl = "KatanaDisabled"
  elseif selected then
    title_hl = "KatanaSelectedText"
  end

  local num_hl = selected and "KatanaSelectedNum" or "KatanaNum"
  local source_hl = selected and "KatanaSelectedSource" or "KatanaSourceName"
  local pref_hl = selected and "KatanaSelectedPreferred" or "KatanaPreferred"
  local gap_hl = selected and "KatanaRow" or "Normal"

  -- La fila empieza en el número: no hay nada a su izquierda (ni sangría, ni
  -- barra, ni glifo). La fila activa se distingue por el color del texto (azul)
  -- y el fondo.
  local marks = {
    { num_str, num_hl },
    { " ", gap_hl },
    { icon .. " ", hls.selected_hl_for(hl_icon, selected) },
    { title, title_hl },
  }
  local title_mark = marks[4]

  if source_str ~= "" then
    table.insert(marks, { source_str, source_hl })
  end
  if pref_str ~= "" then
    table.insert(marks, { pref_str, pref_hl })
  end

  -- El fondo de la fila activa sólo se ve hasta el final del texto; se añade
  -- relleno para que ocupe todo el ancho de la lista.
  if selected then
    local used = 0
    for _, mark in ipairs(marks) do
      used = used + vim.fn.strwidth(mark[1])
    end
    local width = state.list_width or 40
    if used < width then
      table.insert(marks, { string.rep(" ", width - used), "KatanaRow" })
    end
  end

  -- El tercer elemento de un mark es la acción del click. `volt.draw` lo elimina
  -- tras usarlo, por eso las filas se construyen de nuevo cada vez.
  title_mark[3] = {
    click = function()
      state.index = index
      require("katana.ui.list").update_selection()
      require("katana.preview.diff").update()
    end,
  }

  return marks
end

--- Construye las filas (marks) de la lista a partir de `state.flat`.
---@param limit integer|nil número máximo de filas
---@return table[][]
function M.build(limit)
  local opts = config.options
  local rows = {}

  local num_width = 0
  if opts.num_shortcuts and #state.flat > 0 then
    num_width = #tostring(#state.flat) + 1
  end

  -- Contador de atajos numéricos: sólo cuentan las acciones, no las cabeceras.
  local action_index = 0

  for i, item in ipairs(state.flat) do
    if limit and i > limit then
      break
    end

    if item.type == "header" then
      rows[#rows + 1] = header_row(item.group)
    elseif item.type == "action" then
      action_index = action_index + 1
      rows[#rows + 1] = action_row(item.action, i, action_index, num_width)
    end
  end

  if #rows == 0 then
    rows = {
      { { "  No matching actions", "Comment" } },
    }
  end

  return rows
end

return M
