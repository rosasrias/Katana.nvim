---@mod katana.core.fetch.request Petición a un cliente LSP
---
--- Envía `textDocument/codeAction` con los rangos calculados, aplica timeouts
--- por petición y fusiona las respuestas. Un timeout de un rango no debe
--- bloquear la recogida completa.

local config = require("katana.config")
local diagnostics_module = require("katana.core.fetch.diagnostics")
local normalizer = require("katana.core.fetch.normalizer")
local ranges = require("katana.core.fetch.ranges")
local request_ranges = require("katana.core.fetch.request_ranges")
local optional = require("katana.core.optional")

local M = {}

--- Pide acciones a un cliente LSP.
---@param client vim.lsp.Client
---@param ctx KatanaContext
---@param opts table
---@param done fun(actions: KatanaAction[])
---@param record_error fun(source: string, err: any)|nil
function M.fetch(client, ctx, opts, done, record_error)
  if not client:supports_method("textDocument/codeAction", ctx.bufnr) then
    done({})
    return
  end

  local encoding = client.offset_encoding or ctx.encoding

  -- El rango y los diagnósticos se recalculan con la codificación del propio
  -- cliente: cada servidor mide las posiciones en sus propias unidades.
  local base_range = ranges.for_context(ctx, encoding)

  local diagnostics = diagnostics_module.collect(ctx.bufnr, base_range, encoding, ctx.scope, ctx.cursor)

  local context = {
    diagnostics = diagnostics,
  }

  -- `triggerKind` es obligatorio en LSP 3.16 y opcional en 3.17: Neovim lo
  -- envía siempre y algunos servidores (lua_ls, rust-analyzer) lo leen sin
  -- comprobar que exista.
  local trigger_kind = optional.value(opts.trigger_kind)
  if trigger_kind ~= false then
    context.triggerKind = trigger_kind or vim.lsp.protocol.CodeActionTriggerKind.Invoked
  end

  -- `only` sólo se envía si se pide explícitamente: algunos servidores
  -- deserializan el contexto de forma estricta.
  local only = optional.table(opts.only)
  if only and #only > 0 then
    context.only = only
  end

  local collected = {}
  local finished = false
  local timers = {}

  local function cleanup_timers()
    for _, timer in ipairs(timers) do
      if timer then
        pcall(function()
          timer:stop()
          if not timer:is_closing() then
            timer:close()
          end
        end)
      end
    end
    timers = {}
  end

  local function finish()
    if finished then
      return
    end
    finished = true
    cleanup_timers()
    done(collected)
  end

  --- Envía la petición con un rango concreto.
  ---@param request_range lsp.Range
  ---@param cb fun(actions: KatanaAction[])
  local function send(request_range, cb)
    local params = {
      textDocument = { uri = ctx.uri },
      range = request_range,
      context = context,
    }

    local timeout_ms = opts.request_timeout or config.options.lsp_request_timeout or 3000
    local req_finished = false
    local timer = nil

    local function stop_local_timer()
      if timer then
        pcall(function()
          timer:stop()
          if not timer:is_closing() then
            timer:close()
          end
        end)
        timer = nil
      end
    end

    local function safe_cb(actions)
      if req_finished or finished then
        return
      end
      req_finished = true
      stop_local_timer()
      cb(actions or {})
    end

    timer = vim.uv.new_timer()
    if timer then
      timers[#timers + 1] = timer
      timer:start(timeout_ms, 0, function()
        vim.schedule(function()
          if req_finished or finished then
            return
          end
          stop_local_timer()
          req_finished = true

          -- Un timeout por rango/cliente puede ser normal (el servidor tarda o
          -- no soporta bien codeAction). Se registra para `:KatanaDebug` y se
          -- sigue con las demás respuestas; sin esto el contador de peticiones
          -- pendientes nunca bajaría y el picker no llegaría a abrirse.
          if record_error then
            record_error(
              "lsp:" .. tostring(client.name or "?"),
              string.format("timeout de codeAction (%d ms)", timeout_ms)
            )
          end

          -- `safe_cb` no sirve aquí: `req_finished` ya es true y saldría sin
          -- llamar al callback. Se entrega la respuesta vacía directamente.
          pcall(cb, {})
        end)
      end)
    end

    local ok = pcall(function()
      client:request("textDocument/codeAction", params, function(err, result)
        if req_finished or finished then
          return
        end
        if err ~= nil then
          if record_error then
            record_error("lsp:" .. tostring(client.name or "?"), err)
          end
          safe_cb({})
          return
        end
        if type(result) ~= "table" then
          if record_error and result ~= nil then
            record_error(
              "lsp:" .. tostring(client.name or "?"),
              "respuesta inválida de textDocument/codeAction"
            )
          end
          safe_cb({})
          return
        end

        safe_cb(normalizer.normalize(result, client, ctx))
      end, ctx.bufnr)
    end)

    if not ok then
      if record_error then
        record_error("lsp:" .. tostring(client.name or "?"), "no se pudo enviar textDocument/codeAction")
      end
      safe_cb({})
    end
  end

  --- Envía la petición con todos los rangos calculados y fusiona las respuestas.
  ---@param diags lsp.Diagnostic[]
  local function run(diags)
    context.diagnostics = diags

    local all_ranges = request_ranges.for_context(ctx, encoding, diags)

    if #all_ranges == 0 then
      finish()
      return
    end

    local pending = #all_ranges

    for _, request_range in ipairs(all_ranges) do
      send(request_range, function(actions)
        for _, action in ipairs(actions or {}) do
          collected[#collected + 1] = action
        end

        pending = pending - 1
        if pending <= 0 then
          finish()
        end
      end)
    end
  end

  -- Si el buffer no tiene diagnósticos (p. ej. los *pull* de Roslyn todavía no
  -- han llegado porque el proyecto se está cargando), se le piden al servidor:
  -- así el rango de la petición puede ser el del error aunque todavía no se
  -- hayan publicado.
  if #diagnostics == 0 and config.options.pull_diagnostics ~= false then
    local pull_timeout = opts.pull_timeout or config.options.pull_timeout or 2000
    local pull_done = false
    local pull_timer = vim.uv.new_timer()
    if pull_timer then
      timers[#timers + 1] = pull_timer
      pull_timer:start(pull_timeout, 0, function()
        vim.schedule(function()
          if finished or pull_done then
            return
          end
          pull_done = true
          run(ranges.diagnostics_on_row({}, ctx.cursor.row))
        end)
      end)
    end

    diagnostics_module.pull(client, ctx, function(pulled)
      if finished or pull_done then
        return
      end
      pull_done = true
      run(ranges.diagnostics_on_row(pulled or {}, ctx.cursor.row))
    end)
  else
    run(diagnostics)
  end
end

return M
