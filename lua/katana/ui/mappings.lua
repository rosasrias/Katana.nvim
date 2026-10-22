---@mod katana.ui.mappings Keymaps del picker
---
--- Dos buffers tienen keymaps propios:
---   * la lista (modo normal): navegación, atajos numéricos y confirmación.
---   * el prompt (modo insert): filtrado en vivo, navegación y confirmación.
---
--- El prompt es la ventana activa al abrir el picker: se escribe el filtro y se
--- confirma con `<CR>`. La lista se alcanza con `<Tab>` (desde el prompt) o
--- haciendo clic en ella.

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

  vim.keymap.set("n", "]", M.next_group, opts)
  vim.keymap.set("n", "[", M.prev_group, opts)

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

  -- Vuelve al prompt para seguir filtrando.
  vim.keymap.set("n", "<Tab>", function()
    if state.win_prompt and vim.api.nvim_win_is_valid(state.win_prompt) then
      vim.api.nvim_set_current_win(state.win_prompt)
      vim.cmd("startinsert!")
    end
  end, opts)

  if config.options.num_shortcuts then
    for i = 1, 9 do
      vim.keymap.set("n", tostring(i), function()
        jump_to_action(i)
        apply.run_current()
      end, opts)
    end
  end
end

--- Registra los keymaps del buffer del prompt.
function M.setup_prompt()
  local buf = state.buf_prompt
  if not buf then
    return
  end

  local opts = { buffer = buf, silent = true, nowait = true }

  vim.keymap.set("i", "<CR>", function()
    require("katana.ui.window").confirm()
  end, opts)
  vim.keymap.set("i", "<C-n>", function()
    M.move(1)
  end, opts)
  vim.keymap.set("i", "<C-p>", function()
    M.move(-1)
  end, opts)
  vim.keymap.set("i", "<Down>", function()
    M.move(1)
  end, opts)
  vim.keymap.set("i", "<Up>", function()
    M.move(-1)
  end, opts)
  vim.keymap.set("i", "<Tab>", function()
    M.move(1)
  end, opts)
  vim.keymap.set("i", "<S-Tab>", function()
    M.move(-1)
  end, opts)
  vim.keymap.set("i", "<Esc>", function()
    require("katana.ui.window").close()
  end, opts)
  vim.keymap.set("i", "<C-c>", function()
    require("katana.ui.window").close()
  end, opts)
end

--- Registra todos los keymaps.
function M.setup()
  M.setup_list()
  M.setup_prompt()
end

return M
