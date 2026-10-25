---@mod katana.ui.window Ventanas del picker
---
--- El picker tiene dos ventanas:
---   * la lista de acciones (renderizada con Volt),
---   * la previsualización del diff (debajo de la lista).
---
--- No hay ventana de filtro: se navega directamente con `j`/`k` (o las flechas)
--- y se confirma con `<CR>`.
---
--- La apertura/cierre de ventanas vive en `katana.ui.window.lifecycle` y
--- `katana.ui.window.teardown`; esta fachada mantiene el contrato público y la
--- lógica de selección.

local state = require("katana.state")
local config = require("katana.config")
local group = require("katana.core.group")
local lifecycle = require("katana.ui.window.lifecycle")
local list = require("katana.ui.list")
local preview = require("katana.preview.diff")
local teardown = require("katana.ui.window.teardown")

local M = {}

--- Reconstruye las filas de la lista a partir de `state.filtered`.
---
--- Se llama al abrir el picker.
function M.rebuild()
  if not state.open then
    return
  end

  local opts = config.options

  if opts.group_by_kind then
    state.groups = group.build(state.filtered)
    state.flat = group.flatten(state.groups)
  else
    state.groups = {}
    state.flat = {}
    for _, action in ipairs(state.filtered) do
      state.flat[#state.flat + 1] = { type = "action", action = action }
    end
  end

  -- La selección cae en la primera acción (nunca en una cabecera).
  state.index = 1
  for i, item in ipairs(state.flat) do
    if item.type == "action" then
      state.index = i
      break
    end
  end

  list.render()
  preview.update()

  state.snapshot("reconstruido")
end

--- Repinta la lista y la previsualización.
function M.refresh()
  if not state.open then
    return
  end

  list.render()
  preview.update()
end

--- Abre el picker con la lista de acciones dada.
---
--- Si ya había un picker abierto, se cierra antes (sin dejar ventanas, buffers
--- ni `guicursor` huérfanos). Nunca lanza: devuelve `false, error` y limpia los
--- restos de una apertura parcial.
---@param actions KatanaAction[]
---@param on_select fun(action: KatanaAction)|nil
---@return boolean ok
---@return string|nil error
function M.open(actions, on_select)
  return lifecycle.open(actions, on_select, { rebuild = M.rebuild })
end

--- Confirma la acción seleccionada: cierra el picker y la ejecuta.
---
--- El cierre ocurre **antes** de ejecutar: así la acción no puede ejecutarse dos
--- veces si su callback vuelve a pulsar `<CR>`/un atajo numérico.
function M.confirm()
  if not state.open then
    return
  end

  local item = state.flat[state.index]
  local action = nil

  if item then
    if item.type == "action" then
      action = item.action
    else
      -- Si la selección está en una cabecera, se toma la primera acción posterior.
      for i = state.index, #state.flat do
        if state.flat[i].type == "action" then
          action = state.flat[i].action
          break
        end
      end
    end
  end

  local on_select = state.on_select

  M.close()

  if action and on_select then
    local ok, err = pcall(on_select, action)
    if not ok then
      state.last = state.last or {}
      state.last.error = "on_select: " .. tostring(err)
      pcall(vim.notify, "Katana: error al ejecutar la acción: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
end

--- Cierra el picker y limpia todos sus recursos.
---
--- Es idempotente: se puede llamar varias veces, con o sin picker abierto, y
--- también después de una apertura que falló a medias. No requiere Volt para
--- limpiar buffers/ventanas.
---@return boolean
function M.close()
  return teardown.close()
end

---@return boolean
function M.is_open()
  return state.open
end

return M
