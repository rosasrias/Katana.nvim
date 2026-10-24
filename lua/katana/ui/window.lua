---@mod katana.ui.window Ventanas del picker
---
--- El picker tiene dos ventanas:
---   * la lista de acciones (renderizada con Volt),
---   * la previsualización del diff (debajo de la lista).
---
--- No hay ventana de filtro: se navega directamente con `j`/`k` (o las flechas)
--- y se confirma con `<CR>`.

local api = vim.api
local volt = require("volt")

local state = require("katana.state")
local config = require("katana.config")
local layout = require("katana.ui.layout")
local list = require("katana.ui.list")
local preview = require("katana.preview.diff")
local group = require("katana.core.group")
local highlights = require("katana.ui.highlights")

local M = {}

--- Reconstruye las filas de la lista a partir de `state.filtered`.
---
--- Se llama al abrir el picker.
function M.rebuild()
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
  list.render()
  preview.update()
end

--- Abre el picker con la lista de acciones dada.
---@param actions KatanaAction[]
---@param on_select fun(action: KatanaAction)|nil
function M.open(actions, on_select)
  if not actions or #actions == 0 then
    vim.notify("Katana: no code actions available", vim.log.levels.INFO)
    return
  end

  local origin_buf = api.nvim_get_current_buf()
  local origin_win = api.nvim_get_current_win()

  state.reset()
  state.origin_buf = origin_buf
  state.origin_win = origin_win
  state.actions = actions
  state.filtered = actions
  state.on_select = on_select
  state.open = true

  local geometry = layout.compute()
  state.list_width = geometry.list_width
  state.max_rows = geometry.list_height

  highlights.setup()

  -- La lista no necesita cursor visible: la fila activa ya se marca en azul.
  -- `guicursor` es global, así que se guarda el valor del usuario y se restaura
  -- al cerrar el picker.
  state.guicursor_prev = vim.o.guicursor
  pcall(function()
    vim.o.guicursor = "a:block-KatanaCursor"
  end)

  ------------------------------------------------------------------- lista
  local list_buf = api.nvim_create_buf(false, true)
  vim.bo[list_buf].buftype = "nofile"
  vim.bo[list_buf].bufhidden = "wipe"
  vim.bo[list_buf].swapfile = false
  state.buf_main = list_buf

  -- La lista es la ventana activa: no hay prompt, se navega en modo normal.
  local list_win = api.nvim_open_win(list_buf, true, {
    relative = "editor",
    row = geometry.list.row,
    col = geometry.list.col,
    width = geometry.list.width,
    height = geometry.list.height,
    style = "minimal",
    border = geometry.border,
    title = " Katana ",
    title_pos = "center",
  })
  state.win_main = list_win

  ------------------------------------------------------------ previsualización
  if geometry.preview_width > 0 and (geometry.preview_height or 0) > 0 then
    local preview_buf = api.nvim_create_buf(false, true)
    vim.bo[preview_buf].buftype = "nofile"
    vim.bo[preview_buf].bufhidden = "wipe"
    vim.bo[preview_buf].swapfile = false
    state.buf_preview = preview_buf

    local preview_win = api.nvim_open_win(preview_buf, false, {
      relative = "editor",
      row = geometry.preview.row,
      col = geometry.preview.col,
      width = geometry.preview.width,
      height = geometry.preview.height or geometry.list_height,
      style = "minimal",
      border = geometry.border,
      title = " Preview ",
      title_pos = "center",
    })
    state.win_preview = preview_win
  end

  -------------------------------------------------------------------- volt
  -- `volt.run` redibuja el buffer, por lo que el estado debe existir antes
  -- (`volt.gen_data`).
  volt.gen_data({
    {
      buf = list_buf,
      ns = state.ns_main,
      xpad = 2,
      layout = {
        {
          name = "katana_actions",
          lines = function()
            return list.rows(geometry.list.height)
          end,
        },
      },
    },
  })

  volt.run(list_buf, {
    h = geometry.list.height,
    w = geometry.list_width,
  })

  -- Soporte de ratón: se registra antes de los keymaps propios para que nuestros
  -- `<CR>` tengan prioridad sobre los de Volt.
  pcall(function()
    require("volt.events").add(list_buf)
  end)

  M.rebuild()

  require("katana.ui.mappings").setup()

  state.snapshot("abierto")

  ----------------------------------------------------------------- autocmds
  state.au_close = api.nvim_create_autocmd("WinClosed", {
    buffer = list_buf,
    callback = function()
      vim.schedule(function()
        if state.open and (not state.win_main or not api.nvim_win_is_valid(state.win_main)) then
          M.close()
        end
      end)
    end,
  })

  for _, win in ipairs({ list_win, state.win_preview }) do
    if win and api.nvim_win_is_valid(win) then
      vim.wo[win].number = false
      vim.wo[win].relativenumber = false
      vim.wo[win].signcolumn = "no"
      vim.wo[win].foldenable = false
      vim.wo[win].spell = false
      vim.wo[win].scrolloff = 0
      vim.wo[win].sidescrolloff = 0
      vim.wo[win].cursorline = false
      vim.wo[win].wrap = false

      -- En horizontal la lista conserva su alto reservado; se ocultan las `~`
      -- de las filas sobrantes para que el panel no parezca roto.
      if config.options.preview_split == "horizontal" then
        pcall(function()
          vim.wo[win].fillchars = "eob: "
        end)
      end
    end
  end

  api.nvim_set_current_win(list_win)
end

--- Confirma la acción seleccionada: cierra el picker y la ejecuta.
function M.confirm()
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
    on_select(action)
  end
end

--- Cierra el picker.
function M.close()
  if not state.open then
    return
  end

  state.open = false

  if state.au_close then
    pcall(api.nvim_del_autocmd, state.au_close)
    state.au_close = nil
  end

  -- `volt.utils.close` borra el buffer de la lista y lo quita de `volt.events`.
  local list_buf = state.buf_main
  if list_buf and api.nvim_buf_is_valid(list_buf) then
    pcall(function()
      require("volt.utils").close({ bufs = { list_buf } })
    end)
  end

  if state.win_preview and api.nvim_win_is_valid(state.win_preview) then
    pcall(api.nvim_win_close, state.win_preview, true)
  end

  if state.buf_preview and api.nvim_buf_is_valid(state.buf_preview) then
    pcall(api.nvim_buf_delete, state.buf_preview, { force = true })
  end

  -- Devuelve el foco a la ventana de origen.
  if state.origin_win and api.nvim_win_is_valid(state.origin_win) then
    pcall(api.nvim_set_current_win, state.origin_win)
  end

  if state.guicursor_prev then
    pcall(function()
      vim.o.guicursor = state.guicursor_prev
    end)
    state.guicursor_prev = nil
  end

  state.reset()
end

---@return boolean
function M.is_open()
  return state.open
end

return M
