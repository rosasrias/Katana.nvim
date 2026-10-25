---@mod katana Katana.nvim
---
--- Picker de code actions para Neovim. Combina las acciones de todos los clientes
--- LSP del buffer, un proveedor basado en Tree-sitter, los proveedores y las
--- acciones registradas por el usuario.
---
--- Uso básico:
--- ```lua
--- require("katana").setup()
--- require("katana").code_action()
--- ```

local M = {}

local config = require("katana.config")
local state = require("katana.state")

--- Scopes válidos para `open()`.
local VALID_SCOPES = {
  cursor = true,
  line = true,
  visual = true,
}

--- Configura el plugin.
---@param opts table|nil
---@return table options
function M.setup(opts)
  local options = config.setup(opts)

  -- El comando y el atajo se crean aquí (y no sólo en `plugin/katana.lua`) para
  -- que funcionen aunque el usuario llame a `setup()` con otras opciones.
  local ok_plugin, err_plugin = pcall(function()
    require("katana.plugin").ensure()
  end)
  if not ok_plugin then
    pcall(function()
      vim.notify("Katana: fallo al crear comandos/atajos: " .. tostring(err_plugin), vim.log.levels.WARN)
    end)
  end

  return options
end

--- Abre el picker de acciones.
---@param opts table|nil
---   - `bufnr` integer|nil buffer (por defecto, el actual)
---   - `win` integer|nil ventana (por defecto, la actual)
---   - `scope` '"cursor"'|'"line"'|'"visual"' rango solicitado
---   - `only` string[]|nil kinds LSP a requesting
function M.open(opts)
  opts = opts or {}

  if opts.scope and not VALID_SCOPES[opts.scope] then
    vim.notify(
      string.format("Katana: invalid scope '%s' (expected: cursor, line, visual)", tostring(opts.scope)),
      vim.log.levels.ERROR
    )
    return
  end

  -- En modo visual se pide el rango de la selección.
  if not opts.scope then
    local mode = vim.api.nvim_get_mode().mode
    if mode == "v" or mode == "V" or mode == "\22" then
      opts.scope = "visual"
    end
  end

  local ok, result = pcall(require("katana.core.fetch").get, opts)
  if not ok then
    state.last = state.last or {}
    state.last.error = "fetch: " .. tostring(result)
    pcall(vim.notify, "Katana: error al recoger acciones: " .. tostring(result), vim.log.levels.ERROR)
    return nil
  end

  return result
end

--- Atajo: abre el picker de acciones.
function M.code_action()
  M.open()
end

--- Atajo: abre el picker con sólo las acciones de tipo `source`.
function M.source_action()
  M.open({ only = { "source" } })
end

--- Registra una acción propia (visible en el mismo menú que las de LSP).
---@param spec table
---   - `title` string
---   - `kind` string|nil
---   - `source` string|nil
---   - `run` fun()|nil
---   - `execute_fn` fun(action: KatanaAction)|nil
---   - `edit` vim.lsp.WorkspaceEdit|nil
---   - `command` table|string|nil
---   - `when` fun(ctx: KatanaContext): boolean|nil
---@param opts table|nil
---@return table
function M.register_action(spec, opts)
  return require("katana.register").register(spec, opts)
end

--- Registra un proveedor de acciones.
---
--- El proveedor recibe el contexto de la petición y devuelve una lista de
--- acciones normalizadas.
---@param fn fun(ctx: KatanaContext): KatanaAction[]|nil
---@param name string|nil
---@param opts table|nil
---@return table
function M.register_provider(fn, name, opts)
  return require("katana.core.providers").register(fn, name, opts)
end

--- Cierra el picker si está abierto.
function M.close()
  require("katana.ui.window").close()
end

--- Callback interno: las acciones ya están recogidas.
---@param actions KatanaAction[]
---@param opts table|nil
---@param ctx KatanaContext|nil
---@param token integer|nil generación de la petición que produjo `actions`
function M._on_actions(actions, opts, ctx, token)
  -- Una respuesta vieja no debe oponerse al resultado de una petición nueva.
  if token ~= nil and not require("katana.core.fetch").is_current(token) then
    return
  end

  opts = opts or {}

  local options = config.options
  local collected = actions or {}

  -- El filtro va **antes** de decidir si hay algo que mostrar: si todas las
  -- acciones están deshabilitadas, no se abre una UI vacía ni se avisa dos
  -- veces.
  if options.hide_disabled then
    collected = vim.tbl_filter(function(action)
      return not action.disabled
    end, collected)
  end

  if #collected == 0 then
    -- Si el picker ya está abierto (esperando), se cierra para no dejarlo
    -- colgado. No se requiere el módulo de UI si no hay nada abierto (así un
    -- fallo de Volt no impide informar del resultado).
    if state.open then
      pcall(function()
        require("katana.ui.window").close()
      end)
    end

    pcall(
      vim.notify,
      "Katana: no code actions found (run :KatanaDebug for details)",
      vim.log.levels.INFO
    )
    return
  end

  local sorted = require("katana.core.prioritize").filter_and_sort(collected, ctx)

  if #sorted == 0 then
    pcall(
      vim.notify,
      "Katana: no code actions found after filtering (run :KatanaDebug for details)",
      vim.log.levels.INFO
    )
    return
  end

  if options.resolve_on_open then
    require("katana.core.resolve").resolve_batch(sorted, options.resolve_limit)
  end

  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local win = opts.win or vim.api.nvim_get_current_win()

  local window = require("katana.ui.window")
  local metrics = require("katana.metrics")

  -- El picker se abre ahora, con las acciones ya recibidas y ordenadas.
  metrics.start("picker_open")
  local open_ok, open_result, open_err = pcall(window.open, sorted, function(action)
    require("katana.apply").execute(action, {
      bufnr = bufnr,
      win = win,
    })
  end)
  local open_ms = metrics.stop("picker_open")

  if open_ms then
    state.last = state.last or {}
    state.last.open_ms = open_ms
  end

  if not open_ok then
    open_err = open_result
  elseif open_result == false then
    open_err = open_err or "window.open devolvió false"
  else
    open_err = nil
  end

  if open_err then
    state.last = state.last or {}
    state.last.error = string.format("window.open: %s", tostring(open_err))
    pcall(vim.notify, "Katana: error al abrir el picker: " .. tostring(open_err), vim.log.levels.ERROR)
  end
end

return M
