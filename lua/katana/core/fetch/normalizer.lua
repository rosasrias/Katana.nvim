---@mod katana.core.fetch.normalizer Acciones LSP normalizadas
---
--- Convierte la respuesta cruda de `textDocument/codeAction` al contrato
--- `KatanaAction` y añade, cuando hace falta, una `resolve_fn` para
--- `codeAction/resolve`.

local action_module = require("katana.core.action")
local optional = require("katana.core.optional")

local M = {}

---@param raw table
---@return boolean
local function is_quickfix(raw)
  return type(raw.kind) == "string" and raw.kind:sub(1, 9) == "quickfix"
end

--- Normaliza las acciones devueltas por un cliente LSP.
---@param result table[]
---@param client vim.lsp.Client
---@param ctx KatanaContext
---@return KatanaAction[]
function M.normalize(result, client, ctx)
  local actions = {}

  for _, raw in ipairs(optional.value(result) or {}) do
    if type(raw) == "table" and optional.value(raw.title) then
      local diagnostics = optional.value(raw.diagnostics)
        or (is_quickfix(raw) and ctx.diagnostics or nil)
      local data = optional.value(raw.data)

      local action, normalize_err = action_module.normalize({
        title = optional.value(raw.title),
        kind = optional.value(raw.kind),
        source = "lsp:" .. (client.name or "unknown"),
        raw = raw,
        diagnostics = diagnostics,
        client_id = client.id,
        encoding = client.offset_encoding or ctx.encoding,
        isPreferred = optional.value(raw.isPreferred) or false,
        disabled = optional.value(raw.disabled),
        -- El servidor puede enviar la edición y el comando ya resueltos: no hay
        -- que esperar al `codeAction/resolve` para aplicarlos.
        edit = optional.value(raw.edit),
        command = optional.value(raw.command),
        data = data,
        _client_name = client.name,
        _client_id = client.id,
        _bufnr = ctx.bufnr,
      })

      if not action then
        pcall(function()
          vim.notify(
            string.format(
              "Katana: acción LSP de '%s' ignorada: %s",
              tostring(client.name),
              tostring(normalize_err)
            ),
            vim.log.levels.DEBUG
          )
        end)
        goto continue
      end

      -- `codeAction/resolve` sólo hace falta si el servidor ha devuelto `data`.
      if data ~= nil and client:supports_method("codeAction/resolve", ctx.bufnr) then
        action.resolve_fn = function(cb)
          if client.is_stopped and client:is_stopped() then
            cb(action, "el cliente LSP se detuvo antes de resolver la acción")
            return
          end

          -- Los parámetros de `codeAction/resolve` son la propia acción.
          local ok_request, request_err = pcall(function()
            client:request("codeAction/resolve", raw, function(err, resolved)
              if err ~= nil then
                cb(action, err)
                return
              end

              if type(resolved) ~= "table" then
                cb(action, "respuesta inválida de codeAction/resolve")
                return
              end

              -- `or` no sirve aquí: `vim.NIL` es truthy y un `null` explícito
              -- del servidor borraría el valor ya conocido (o pasaría un
              -- `vim.NIL` al executor). Sólo se sustituye lo realmente presente.
              local edit = optional.value(resolved.edit)
              if edit ~= nil then
                action.edit = edit
              end

              local command = optional.value(resolved.command)
              if command ~= nil then
                action.command = command
              end

              local resolved_diagnostics = optional.value(resolved.diagnostics)
              if resolved_diagnostics ~= nil then
                action.diagnostics = resolved_diagnostics
              end

              local is_preferred = optional.value(resolved.isPreferred)
              if is_preferred ~= nil then
                action.isPreferred = is_preferred == true
              end

              local disabled = optional.value(resolved.disabled)
              if disabled ~= nil then
                action.disabled = disabled
              end

              local resolved_data = optional.value(resolved.data)
              if resolved_data ~= nil then
                action.data = resolved_data
              end

              action.raw = optional.value(resolved) or action.raw
              cb(action, nil)
            end, ctx.bufnr)
          end)

          if not ok_request then
            cb(action, request_err)
          end
        end
      end

      actions[#actions + 1] = action
    end

    ::continue::
  end

  return actions
end

return M
