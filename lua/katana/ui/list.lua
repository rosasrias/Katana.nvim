---@mod katana.ui.list Renderizado de la lista de acciones con Volt
---
--- El buffer de Volt sólo contiene líneas en blanco: el texto de cada fila es
--- `virt_text` (los *marks* de Volt). `volt.draw` **elimina el tercer elemento** de
--- cada mark (donde vive la acción del click), por lo que las filas se construyen
--- de nuevo en cada render.

local api = vim.api
local volt = require("volt")

local state = require("katana.state")
local config = require("katana.config")
local hls = require("katana.ui.highlights")

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

--- Construye las filas (marks) de la lista a partir de `state.flat`.
---@param limit integer|nil número máximo de filas
---@return table[][]
function M.rows(limit)
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
      local group = item.group
      local label = group.label

      -- La cabecera usa el mismo icono y color que sus acciones, para que el
      -- grupo se reconozca de un vistazo.
      local icon, icon_hl = action_icon({ kind = group.key })

      -- La cabecera también empieza en la primera columna: no hay margen a la
      -- izquierda (ni hueco ni barra) delante del icono ni de los números.
      local prefix = icon .. "  "
      local used = vim.fn.strwidth(prefix) + vim.fn.strwidth(label) + 1
      rows[#rows + 1] = {
        { prefix, icon_hl },
        { label, "KatanaHeader" },
        { " " .. string.rep("─", math.max(0, (state.list_width or 40) - used)), "KatanaSeparator" },
      }
    elseif item.type == "action" then
      local action = item.action
      action_index = action_index + 1

      local title = require("katana.utils").compact_title(action.title) or ""
      local icon, hl_icon = action_icon(action)
      local selected = i == state.index

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

      -- Al seleccionar, el texto pasa a azul (`KatanaSelected*`) sobre el fondo
      -- del resaltado; el icono conserva el color de su kind.
      -- Volt sólo admite `{ texto, hl_group, acciones }`, así que el fondo se
      -- resuelve con grupos de resaltado dedicados, no con opciones por mark.
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

      -- La fila empieza en el número: no hay nada a su izquierda (ni sangría,
      -- ni barra, ni glifo). La fila activa se distingue por el color del texto
      -- (azul) y el fondo.
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

      -- El tercer elemento de un mark es la acción del click. `volt.draw` lo
      -- elimina tras usarlo, por eso las filas se construyen de nuevo cada vez.
      title_mark[3] = {
        click = function()
          state.index = i
          require("katana.ui.list").update_selection()
          require("katana.preview.diff").update()
        end,
      }

      rows[#rows + 1] = marks
    end
  end

  if #rows == 0 then
    rows = {
      { { "  No matching actions", "Comment" } },
    }
  end

  return rows
end

--- Redibuja la lista.
---
--- El buffer contiene *todas* las filas (para poder desplazarse con la ventana),
--- pero la ventana muestra como mucho `state.max_rows` filas. Al filtrar cambia
--- el número de filas: hay que limpiar los extmarks anteriores y redimensionar el
--- buffer de líneas en blanco.
function M.render()
  if not state.open then
    return
  end

  local buf = state.buf_main
  local win = state.win_main

  if not buf or not api.nvim_buf_is_valid(buf) then
    return
  end

  local horizontal = config.options.preview_split == "horizontal"
  local visible = math.max(1, math.min(#state.flat, state.max_rows or 1))

  if win and api.nvim_win_is_valid(win) then
    -- Con el preview debajo, la lista conserva su alto reservado: así el panel
    -- no salta al filtrar y el preview no se mueve de sitio.
    pcall(api.nvim_win_set_height, win, horizontal and (state.max_rows or visible) or visible)
  end

  -- En vertical el preview acompaña a la lista; en horizontal tiene su propio
  -- alto máximo (`preview_max_height`) y hace scroll por dentro.
  if not horizontal and state.win_preview and api.nvim_win_is_valid(state.win_preview) then
    pcall(api.nvim_win_set_height, state.win_preview, visible)
  end

  api.nvim_buf_clear_namespace(buf, state.ns_main, 0, -1)

  local rows = M.rows()

  -- Un fallo al pintar no debe quedar silenciado: se propaga después de
  -- devolver el buffer a su estado no modificable (si se propagara dentro del
  -- pcall, el buffer se quedaría editable).
  vim.bo[buf].modifiable = true
  local ok_draw, draw_err = pcall(volt.set_empty_lines, buf, #rows, state.list_width or 40)
  vim.bo[buf].modifiable = false
  if not ok_draw then
    error(draw_err)
  end

  volt.gen_data({
    {
      buf = buf,
      ns = state.ns_main,
      xpad = 2,
      layout = {
        {
          name = "katana_actions",
          lines = function()
            return M.rows()
          end,
        },
      },
    },
  })

  volt.redraw(buf, "all")

  M.sync_cursor()
end

--- Coloca el cursor de la ventana de lista en la fila activa.
---
--- La columna va al final de la fila (el relleno del fondo), nunca a la
--- izquierda de los números: así el cursor no deja una raya junto al número ni
--- se superpone a él.
function M.sync_cursor()
  if state.win_main and api.nvim_win_is_valid(state.win_main) then
    local col = math.max(0, (state.list_width or 1) - 1)
    pcall(api.nvim_win_set_cursor, state.win_main, { state.index, col })
  end
end

--- Marca la fila seleccionada.
---
--- El fondo de la fila activa lo pone `M.rows()` (los propios marks), porque Volt
--- sólo dibuja `virt_text`: no se puede pintar por encima en otra namespace sin
--- tapar el icono. Por eso aquí hay que **volver a dibujar** la lista, y después
--- mover el cursor de la ventana para que la fila activa quede a la vista.
function M.update_selection()
  local buf = state.buf_main
  if not buf or not api.nvim_buf_is_valid(buf) then
    return
  end

  M.render()
end

return M
