---@mod katana.ui.window Ventanas del picker
---
--- El picker tiene tres ventanas:
---   * la lista de acciones (texto real + extmarks, sin dependencias de UI),
---   * el prompt del filtro en vivo (modo insert),
---   * la previsualización del diff.
---
--- No requiere Volt ni ningún otro plugin: usa sólo `nvim_open_win`, buffers y
--- extmarks nativos.

local api = vim.api

local state = require("katana.state")
local config = require("katana.config")
local metrics = require("katana.metrics")
local layout = require("katana.ui.layout")
local list = require("katana.ui.list")
local preview = require("katana.preview.diff")
local group = require("katana.core.group")
local highlights = require("katana.ui.highlights")

local M = {}

--- Texto que el usuario ha escrito en un buffer `buftype=prompt`.
---
--- Neovim guarda la línea del buffer **con el prefijo del prompt delante**
--- (`prompt_setprompt`), así que leer la línea tal cual devuelve `" > "` cuando
--- el filtro está vacío. Eso haría que ninguna acción coincidiese y que la lista
--- apareciese como *No matching actions*.
---@param buf integer
---@return string
local function prompt_text(buf)
  local line = api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""

  local prompt = ""
  pcall(function()
    prompt = vim.fn.prompt_getprompt(buf) or ""
  end)

  if prompt ~= "" and line:sub(1, #prompt) == prompt then
    line = line:sub(#prompt + 1)
  end

  return line
end

--- Reconstruye las filas de la lista a partir de `state.filtered`.
---
--- Se llama al abrir el picker y cada vez que cambia el filtro.
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

  metrics.start("picker_open")

  highlights.setup()

  ------------------------------------------------------------------- lista
  local list_buf = api.nvim_create_buf(false, true)
  vim.bo[list_buf].buftype = "nofile"
  vim.bo[list_buf].bufhidden = "wipe"
  vim.bo[list_buf].swapfile = false
  state.buf_main = list_buf

  local list_opts = {
    relative = "editor",
    row = geometry.list.row,
    col = geometry.list.col,
    width = geometry.list.width,
    height = geometry.list.height,
    style = "minimal",
    border = geometry.border,
  }
  if config.options.title and config.options.title ~= "" then
    list_opts.title = config.options.title
    list_opts.title_pos = "center"
  end
  local list_win = api.nvim_open_win(list_buf, false, list_opts)
  state.win_main = list_win

  ------------------------------------------------------------------ prompt
  local prompt_buf = api.nvim_create_buf(false, true)
  vim.bo[prompt_buf].buftype = "prompt"
  vim.bo[prompt_buf].bufhidden = "wipe"
  vim.fn.prompt_setprompt(prompt_buf, config.options.prompt or " > ")
  state.buf_prompt = prompt_buf

  local prompt_win = api.nvim_open_win(prompt_buf, true, {
    relative = "editor",
    row = geometry.prompt.row,
    col = geometry.prompt.col,
    width = geometry.prompt.width,
    height = 1,
    style = "minimal",
    border = "none",
  })
  state.win_prompt = prompt_win

  ------------------------------------------------------------ previsualización
  if geometry.preview_width > 0 then
    local preview_buf = api.nvim_create_buf(false, true)
    vim.bo[preview_buf].buftype = "nofile"
    vim.bo[preview_buf].bufhidden = "wipe"
    vim.bo[preview_buf].swapfile = false
    state.buf_preview = preview_buf

    local preview_opts = {
      relative = "editor",
      row = geometry.preview.row,
      col = geometry.preview.col,
      width = geometry.preview.width,
      height = geometry.preview.height or geometry.list_height,
      style = "minimal",
      border = geometry.border,
    }
    if config.options.preview_title and config.options.preview_title ~= "" then
      preview_opts.title = config.options.preview_title
      preview_opts.title_pos = "center"
    end
    local preview_win = api.nvim_open_win(preview_buf, false, preview_opts)
    state.win_preview = preview_win
  end

  M.rebuild()

  require("katana.ui.mappings").setup()

  state.snapshot("abierto")

  -- Latencia del render del picker (creación de ventanas + primera lista). Se
  -- guarda para `:KatanaDebug`.
  local open_ms = metrics.stop("picker_open")
  if open_ms then
    state.last.open_ms = open_ms
  end

  ----------------------------------------------------------------- autocmds
  -- `PromptChanged` no existe en Neovim 0.12; `TextChangedI` sí.
  state.au_filter = api.nvim_create_autocmd("TextChangedI", {
    buffer = prompt_buf,
    callback = function()
      require("katana.ui.filter").apply(prompt_text(prompt_buf))
    end,
  })

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

  -- Todas las ventanas comparten el fondo del panel (`NormalFloat`) para que el
  -- prompt sin borde se funda con la lista y no parezca un hueco.
  for _, win in ipairs({ list_win, prompt_win, state.win_preview }) do
    if win and api.nvim_win_is_valid(win) then
      pcall(function()
        vim.wo[win].winhl = "Normal:KatanaNormal,FloatBorder:KatanaBorder,CursorLine:KatanaRow"
      end)
      vim.wo[win].number = false
      vim.wo[win].relativenumber = false
      vim.wo[win].signcolumn = "no"
      vim.wo[win].foldenable = false
      vim.wo[win].spell = false
      vim.wo[win].scrolloff = 0
      vim.wo[win].sidescrolloff = 0
      vim.wo[win].cursorline = false
      vim.wo[win].wrap = false
    end
  end

  api.nvim_set_current_win(prompt_win)

  -- El buffer `buftype=prompt` arranca en modo insert, pero lo forzamos por si el
  -- usuario lo cerró con `<C-c>` anteriormente.
  vim.schedule(function()
    if state.open and state.win_prompt and api.nvim_win_is_valid(state.win_prompt) then
      pcall(vim.cmd, "startinsert!")
    end
  end)
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

  if state.au_filter then
    pcall(api.nvim_del_autocmd, state.au_filter)
    state.au_filter = nil
  end

  for _, win in ipairs({ state.win_main, state.win_prompt, state.win_preview }) do
    if win and api.nvim_win_is_valid(win) then
      pcall(api.nvim_win_close, win, true)
    end
  end

  for _, buf in ipairs({ state.buf_main, state.buf_prompt, state.buf_preview }) do
    if buf and api.nvim_buf_is_valid(buf) then
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
  end

  -- Devuelve el foco a la ventana de origen.
  if state.origin_win and api.nvim_win_is_valid(state.origin_win) then
    pcall(api.nvim_set_current_win, state.origin_win)
  end

  state.reset()
end

---@return boolean
function M.is_open()
  return state.open
end

return M
