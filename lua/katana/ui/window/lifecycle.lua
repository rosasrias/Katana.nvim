---@mod katana.ui.window.lifecycle Apertura del picker
---
--- Crea las ventanas y buffers del picker, configura Volt, registra los
--- autocmds y deja el estado listo. El repintado inicial se delega en el
--- llamador (`hooks.rebuild`) para que esta pieza no dependa de la fachada.

local api = vim.api

local config = require("katana.config")
local guicursor = require("katana.ui.window.guicursor")
local highlights = require("katana.ui.highlights")
local layout = require("katana.ui.layout")
local list = require("katana.ui.list")
local state = require("katana.state")
local teardown = require("katana.ui.window.teardown")

local M = {}

---@class KatanaWindowHooks
---@field rebuild fun()

--- Carga Volt de forma perezosa: `close()`/`is_open()` deben poder usarse (y
--- limpiar restos) aunque Volt no esté en el `runtimepath`.
---@return table
local function volt()
  return require("volt")
end

--- Crea los buffers y ventanas del picker a partir de la geometría calculada.
---@param geometry table
---@return integer list_buf
---@return integer list_win
local function create_list_window(geometry)
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

  return list_buf, list_win
end

--- Crea la ventana de previsualización, si la geometría la contempla.
---@param geometry table
local function create_preview_window(geometry)
  if geometry.preview_width <= 0 or (geometry.preview_height or 0) <= 0 then
    return
  end

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

--- Aplica las opciones de ventana que comparten lista y previsualización.
---@param list_win integer
local function configure_windows(list_win)
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
end

--- Configura Volt sobre el buffer de la lista.
---@param list_buf integer
---@param geometry table
local function setup_volt(list_buf, geometry)
  local volt_mod = volt()

  -- `volt.run` redibuja el buffer, por lo que el estado debe existir antes
  -- (`volt.gen_data`).
  volt_mod.gen_data({
    {
      buf = list_buf,
      ns = state.ns_main,
      xpad = 0,
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

  volt_mod.run(list_buf, {
    h = geometry.list.height,
    w = geometry.list_width,
  })

  -- Soporte de ratón: se registra antes de los keymaps propios para que
  -- nuestros `<CR>` tengan prioridad sobre los de Volt.
  pcall(function()
    require("volt.events").add(list_buf)
  end)
end

--- Registra el autocmd que cierra el picker si su ventana desaparece.
---@param list_buf integer
local function register_close_autocmd(list_buf)
  state.au_close = api.nvim_create_autocmd("WinClosed", {
    buffer = list_buf,
    callback = function()
      vim.schedule(function()
        if state.open and (not state.win_main or not api.nvim_win_is_valid(state.win_main)) then
          teardown.close()
        end
      end)
    end,
  })
end

--- Abre el picker con la lista de acciones dada.
---
--- Si ya había un picker abierto, se cierra antes (sin dejar ventanas, buffers
--- ni `guicursor` huérfanos). Nunca lanza: devuelve `false, error` y limpia los
--- restos de una apertura parcial.
---@param actions KatanaAction[]
---@param on_select fun(action: KatanaAction)|nil
---@param hooks KatanaWindowHooks
---@return boolean ok
---@return string|nil error
function M.open(actions, on_select, hooks)
  if not actions or #actions == 0 then
    pcall(vim.notify, "Katana: no code actions available", vim.log.levels.INFO)
    return false, "no hay acciones que mostrar"
  end

  local ok, err = pcall(function()
    -- Reapertura: primero se desmonta el picker anterior.
    if state.open then
      teardown.close()
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
    guicursor.activate()

    local list_buf, list_win = create_list_window(geometry)
    create_preview_window(geometry)
    setup_volt(list_buf, geometry)
    hooks.rebuild()

    require("katana.ui.mappings").setup()

    state.snapshot("abierto")

    register_close_autocmd(list_buf)
    configure_windows(list_win)

    api.nvim_set_current_win(list_win)
  end)

  if not ok then
    -- Una apertura a medias no debe dejar ventanas, buffers ni `guicursor`
    -- modificados. `close()` es idempotente y limpia lo que exista.
    pcall(teardown.close)
    return false, tostring(err)
  end

  return true
end

return M
