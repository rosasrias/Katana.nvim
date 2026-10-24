---@mod katana.ui.mappings Keymaps del picker
---
--- La lista es la única ventana interactiva: navegación (modo normal), scroll del
--- preview, atajos numéricos y confirmación.

local state = require("katana.state")
local config = require("katana.config")
local preview = require("katana.preview.diff")
local list = require("katana.ui.list")
local apply = require("katana.apply")

local M = {}

---@return integer count número de filas visibles
local function row_count()
  return #state.flat
end

--- Busca la siguiente (o anterior) fila que sea una acción, saltando las
--- cabeceras de grupo.
---@param from integer
---@param delta integer
---@return integer|nil
local function next_action(from, delta)
  local i = from

  while true do
    i = i + delta
    if i < 1 or i > row_count() then
      return nil
    end
    if state.flat[i].type == "action" then
      return i
    end
  end
end

--- Mueve la selección.
---@param delta integer
function M.move(delta)
  if row_count() == 0 then
    return
  end

  local target = next_action(state.index, delta)

  if not target then
    -- Se da la vuelta al principio (o al final) de la lista.
    target = delta > 0 and next_action(0, 1) or next_action(row_count() + 1, -1)
  end

  if not target then
    return
  end

  state.index = target

  list.update_selection()

  if config.options.auto_preview then
    preview.update()
  end
end

--- Salta al siguiente grupo.
function M.next_group()
  for i = state.index + 1, row_count() do
    if state.flat[i].type == "header" then
      local target = next_action(i, 1)
      state.index = target or math.min(i + 1, row_count())
      break
    end
  end

  list.update_selection()
  if config.options.auto_preview then
    preview.update()
  end
end

--- Salta al grupo anterior.
function M.prev_group()
  for i = state.index - 1, 1, -1 do
    if state.flat[i].type == "header" then
      local target = next_action(i, 1)
      state.index = target or i + 1
      break
    end
  end

  list.update_selection()
  if config.options.auto_preview then
    preview.update()
  end
end

---@param index integer índice de acción (sólo acciones, no cabeceras)
local function jump_to_action(index)
  local target = nil
  local count = 0

  for i, item in ipairs(state.flat) do
    if item.type == "action" then
      count = count + 1
      if count == index then
        target = i
        break
      end
    end
  end

  if not target then
    return
  end

  state.index = target
  list.update_selection()
  if config.options.auto_preview then
    preview.update()
  end
end

--- Registra los keymaps del buffer de la lista.
function M.setup_list()
  local buf = state.buf_main
  if not buf then
    return
  end

  local opts = { buffer = buf, silent = true, nowait = true }

  vim.keymap.set("n", "j", function()
    M.move(1)
  end, opts)
  vim.keymap.set("n", "k", function()
    M.move(-1)
  end, opts)
  vim.keymap.set("n", "<Down>", function()
    M.move(1)
  end, opts)
  vim.keymap.set("n", "<Up>", function()
    M.move(-1)
  end, opts)
  vim.keymap.set("n", "<C-n>", function()
    M.move(1)
  end, opts)
  vim.keymap.set("n", "<C-p>", function()
    M.move(-1)
  end, opts)

  vim.keymap.set("n", "]", M.next_group, opts)
  vim.keymap.set("n", "[", M.prev_group, opts)

  -- Desplazar el preview (que puede tener más líneas que su alto máximo).
  vim.keymap.set("n", "<C-d>", function()
    preview.scroll(3)
  end, opts)
  vim.keymap.set("n", "<C-u>", function()
    preview.scroll(-3)
  end, opts)

  vim.keymap.set("n", "<CR>", function()
    require("katana.ui.window").confirm()
  end, opts)
  vim.keymap.set("n", "<Space>", function()
    require("katana.ui.window").confirm()
  end, opts)

  vim.keymap.set("n", "q", function()
    require("katana.ui.window").close()
  end, opts)
  vim.keymap.set("n", "<Esc>", function()
    require("katana.ui.window").close()
  end, opts)
  vim.keymap.set("n", "<C-c>", function()
    require("katana.ui.window").close()
  end, opts)

  if config.options.num_shortcuts then
    for i = 1, 9 do
      vim.keymap.set("n", tostring(i), function()
        M.select(i)
      end, opts)
    end
  end
end

--- Selecciona y ejecuta la acción con el atajo numérico dado.
---@param n integer
function M.select(n)
  if not state.open then
    return
  end
  jump_to_action(n)
  apply.run_current()
end

--- Registra todos los keymaps.
function M.setup()
  M.setup_list()
end

return M
