---@mod katana.core.fetch.orchestrator Orquestación de fuentes de acciones
---
--- Combina cuatro fuentes:
---   1. Proveedores registrados por el usuario.
---   2. Proveedor basado en Tree-sitter.
---   3. Acciones registradas por el usuario.
---   4. Todos los clientes LSP attached al buffer (asíncronos).

local config = require("katana.config")
local context = require("katana.core.fetch.context")
local generation = require("katana.core.fetch.generation")
local request = require("katana.core.fetch.request")
local state = require("katana.state")

local M = {}

--- Recoge acciones de todas las fuentes y se las pasa a `done`.
---@param ctx KatanaContext
---@param opts table|nil
---@param done fun(actions: KatanaAction[], errors: table[]|nil)
function M.get_all_actions(ctx, opts, done)
  opts = opts or {}

  local cfg = config.options
  local collected = {}

  local function collect(actions)
    for _, action in ipairs(actions or {}) do
      collected[#collected + 1] = action
    end
  end

  local errors = {}
  local function record_error(source, err)
    errors[#errors + 1] = { source = source, err = err }
    pcall(function()
      vim.notify("Katana: error en " .. source .. ": " .. tostring(err), vim.log.levels.DEBUG)
    end)
  end

  -- 1. Proveedores registrados por el usuario.
  local ok_providers, provider_actions, provider_errors = pcall(require("katana.core.providers").collect, ctx)
  if not ok_providers then
    record_error("proveedor", provider_actions)
  else
    if type(provider_actions) == "table" then
      collect(provider_actions)
    end
    -- `providers.collect` ya notificó cada error; aquí sólo se acumula para
    -- `:KatanaDebug` (no se duplica el aviso).
    for _, provider_error in ipairs(provider_errors or {}) do
      errors[#errors + 1] = {
        source = provider_error.source,
        err = provider_error.err,
      }
    end
  end

  -- 2. Proveedor de Tree-sitter.
  if cfg.ts and cfg.ts.enabled then
    local ok_ts, ts_actions = pcall(require("katana.core.treesitter").get_actions, ctx)
    if not ok_ts then
      record_error("proveedor treesitter", ts_actions)
    elseif type(ts_actions) == "table" then
      collect(ts_actions)
    end
  end

  -- 3. Acciones registradas por el usuario.
  local ok_user, user_actions = pcall(require("katana.register").get_actions, ctx)
  if not ok_user then
    record_error("acciones registradas", user_actions)
  elseif type(user_actions) == "table" then
    collect(user_actions)
  end

  -- 4. Clientes LSP (asíncronos).
  local clients = vim.lsp.get_clients({ bufnr = ctx.bufnr })
  local pending = 0
  local finished = false
  local issuing = true

  local function maybe_finish()
    if issuing or finished or pending > 0 then
      return
    end
    finished = true

    -- Los errores se guardan siempre (también la lista vacía) para que
    -- `:KatanaDebug` no muestre errores de una petición anterior. Si esta
    -- respuesta pertenece a una generación antigua, no se escribe nada.
    if generation.is_current(opts._token) then
      state.last = state.last or {}
      state.last.fetch_errors = #errors > 0 and errors or nil
    end

    done(collected, errors)
  end

  for _, client in ipairs(clients) do
    pending = pending + 1
    request.fetch(client, ctx, opts, function(actions)
      collect(actions)
      pending = pending - 1
      maybe_finish()
    end, record_error)
  end

  issuing = false
  maybe_finish()
end

--- Punto de entrada: recoge las acciones del buffer actual y abre el picker.
---@param opts table|nil
---@return integer|nil token generación de esta petición
function M.get(opts)
  opts = opts or {}

  local token = generation.new()
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local win = opts.win or vim.api.nvim_get_current_win()

  local ok_ctx, ctx = pcall(context.build, bufnr, win, opts)
  if not ok_ctx then
    state.last = state.last or {}
    state.last.error = "build_context: " .. tostring(ctx)
    pcall(vim.notify, "Katana: error al preparar la petición: " .. tostring(ctx), vim.log.levels.ERROR)
    return token
  end

  local metrics = require("katana.metrics")

  -- `get_all_actions` lo usa para no escribir estado de una respuesta vieja.
  -- Se copia `opts` para no añadir campos internos a la tabla del llamador.
  local fetch_opts = vim.tbl_extend("force", {}, opts)
  fetch_opts._token = token

  metrics.start("fetch")

  M.get_all_actions(ctx, fetch_opts, function(actions)
    -- Una respuesta de una petición anterior no debe abrir la UI ni pisar el
    -- resultado de la petición nueva.
    if not generation.is_current(token) then
      return
    end

    local fetch_ms = metrics.stop("fetch")

    require("katana")._on_actions(actions, opts, ctx, token)

    -- Se guarda después de `_on_actions` porque `state.snapshot()` reemplaza
    -- `state.last`; así la métrica sobrevive para `:KatanaDebug`.
    if fetch_ms then
      state.last = state.last or {}
      state.last.fetch_ms = fetch_ms
    end
  end)

  return token
end

return M
