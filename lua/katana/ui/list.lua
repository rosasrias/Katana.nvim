---@mod katana.ui.list Renderizado de la lista de acciones con Volt
---
--- El buffer de Volt sólo contiene líneas en blanco: el texto de cada fila es
--- `virt_text` (los *marks* de Volt). `volt.draw` **elimina el tercer elemento** de
--- cada mark (donde vive la acción del click), por lo que las filas se construyen
--- de nuevo en cada render.
---
--- La construcción de filas vive en `katana.ui.list.rows`; este módulo gestiona
--- el ciclo de vida del buffer, la ventana y el cursor.

local api = vim.api
local volt = require("volt")

local config = require("katana.config")
local rows = require("katana.ui.list.rows")
local state = require("katana.state")

local M = {}

--- Construye las filas (marks) de la lista a partir de `state.flat`.
---@param limit integer|nil número máximo de filas
---@return table[][]
function M.rows(limit)
  return rows.build(limit)
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

  local built = M.rows()

  -- Un fallo al pintar no debe quedar silenciado: se propaga después de
  -- devolver el buffer a su estado no modificable (si se propagara dentro del
  -- pcall, el buffer se quedaría editable).
  vim.bo[buf].modifiable = true
  local ok_draw, draw_err = pcall(volt.set_empty_lines, buf, #built, state.list_width or 40)
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
--- El fondo de la fila activa lo pone el constructor de filas (los propios
--- marks), porque Volt sólo dibuja `virt_text`: no se puede pintar por encima en
--- otra namespace sin tapar el icono. Por eso aquí hay que **volver a dibujar**
--- la lista, y después mover el cursor de la ventana para que la fila activa
--- quede a la vista.
function M.update_selection()
  local buf = state.buf_main
  if not buf or not api.nvim_buf_is_valid(buf) then
    return
  end

  M.render()
end

return M
