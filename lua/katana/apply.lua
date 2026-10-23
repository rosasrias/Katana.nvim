---@mod katana.apply Ejecución de acciones
---
--- El executor es el único módulo que muta el buffer. Encadena los cuatro pasos
--- del ciclo de vida de una acción:
---
---   1. `resolve_fn` -> resuelve la acción (`codeAction/resolve`).
---   2. `edit`       -> aplica el `WorkspaceEdit`.
---   3. `command`    -> ejecuta el comando LSP.
---   4. `execute_fn` -> ejecuta la lógica propia de la acción.
---
--- Antes de modificar el buffer se cierra el bloque de undo previo, de modo que un
--- único `u` deshace la acción completa (sin arrastrar la edición previa).

local workspace = require("katana.lsp.workspace")
local resolve = require("katana.core.resolve")

local M = {}

---@class KatanaExecutorOptions
---@field bufnr integer
---@field win integer
---@field timeout integer Milisegundos de espera para la resolución

---@param message string
---@param err any|nil
local function notify_error(message, err)
  local text = message
  if err ~= nil then
    text = string.format("%s: %s", message, tostring(err))
  end
  vim.notify("Katana: " .. text, vim.log.levels.ERROR)
end

--- Devuelve el cliente LSP asociado a una acción.
---@param action KatanaAction
---@param bufnr integer
---@return vim.lsp.Client|nil
---@return string|nil error
local function find_client(action, bufnr)
  local clients = vim.lsp.get_clients({ bufnr = bufnr })

  if action.client_id then
    for _, client in ipairs(clients) do
      if client.id == action.client_id then
        return client
      end
    end
    -- Si la acción proviene de un cliente concreto y ya no existe, NO hacemos fallback.
    if action._client_name or action.source and action.source:match("^lsp:") then
      return nil, string.format("cliente LSP '%s' ya no está disponible para esta acción", action._client_name or action.source)
    end
    -- Si no hay indicios claros de origen LSP concreto, seguimos con comportamiento
    -- conservador solo cuando hay clientes disponibles.
    if #clients == 0 then
      return nil
    end
    return nil, "no se encontró el cliente LSP que originó esta acción"
  end

  if #clients == 0 then
    return nil
  end
  return clients[1]
end

--- Aplica el `WorkspaceEdit` de una acción.
---@param action KatanaAction
---@param opts KatanaExecutorOptions
---@return boolean ok
---@return string|nil error
function M.apply_edit(action, opts)
  local edit = action.edit
  if type(edit) ~= "table" then
    return true
  end

  local encoding = action.encoding or "utf-16"
  local groups = workspace.collect_edits(edit)
  local applied = 0

  for _, group in ipairs(groups) do
    local target = workspace.resolve_buf(group, opts.bufnr)
    if target then
      if vim.fn.bufloaded(target) == 0 then
        -- Carga el buffer antes de aplicar para no omitir archivos no cargados.
        pcall(vim.fn.bufload, target)
      end

      if vim.fn.bufloaded(target) == 1 and vim.api.nvim_buf_is_valid(target) then
        -- Cierra el bloque de undo previo para que la acción se deshaga sola.
        workspace.close_undo_block(target)
        local ok_apply, err_apply = pcall(workspace.apply_edits_to_buffer, target, group.edits, encoding)
        if not ok_apply then
          return false, string.format("error al aplicar cambios en %s: %s", vim.api.nvim_buf_get_name(target), tostring(err_apply))
        end
        applied = applied + 1
      else
        return false, string.format("no se pudo cargar el buffer para aplicar cambios en %s", vim.api.nvim_buf_get_name(target))
      end
    else
      return false, "no se pudo resolver el buffer destino del WorkspaceEdit"
    end
  end

  if applied == 0 then
    return false, "el WorkspaceEdit no contiene cambios aplicables"
  end

  return true
end

--- Ejecuta el comando LSP de una acción.
---@param action KatanaAction
---@param opts KatanaExecutorOptions
---@return boolean ok
---@return string|nil error
function M.run_command(action, opts)
  local command = action.command
  if not command then
    return true
  end

  -- Algunos servidores envían el comando como una cadena simple.
  if type(command) == "string" then
    local ok_cmd, err_cmd = pcall(vim.cmd, command)
    if not ok_cmd then
      return false, string.format("error al ejecutar comando: %s", tostring(err_cmd))
    end
    return true
  end

  if type(command) ~= "table" or not command.command then
    return true
  end

  local client, err_client = find_client(action, opts.bufnr)
  if not client then
    local msg = err_client or string.format("no LSP client available to run command '%s'", command.command)
    notify_error(msg)
    return false, msg
  end

  -- `Client:exec_cmd(cmd, context, handler)`: `cmd` es el objeto completo y el
  -- contexto aporta `bufnr` y `client_id`.
  local ok_exec, err_exec = pcall(function()
    client:exec_cmd(command, { bufnr = opts.bufnr })
  end)
  if not ok_exec then
    return false, string.format("error al ejecutar comando '%s': %s", command.command, tostring(err_exec))
  end

  return true
end

--- Ejecuta la lógica propia de la acción.
---@param action KatanaAction
---@param opts KatanaExecutorOptions
---@return boolean ok
---@return string|nil error
function M.run_execute_fn(action, opts)
  if type(action.execute_fn) ~= "function" then
    return true
  end

  -- Las acciones propias también pueden modificar el buffer: se cierra el bloque
  -- de undo para que su reversión sea independiente.
  workspace.close_undo_block(opts.bufnr)

  local ok_fn, err_fn = pcall(action.execute_fn, action)
  if not ok_fn then
    return false, tostring(err_fn)
  end

  return true
end

--- Espera la resolución de una acción.
---@param action KatanaAction
---@param opts KatanaExecutorOptions
---@param done fun(action: KatanaAction)
local function wait_resolve(action, opts, done)
  local timeout = opts.timeout or 5000
  local finished = false

  local timer = vim.uv.new_timer()
  local function stop()
    if timer then
      timer:stop()
      if not timer:is_closing() then
        timer:close()
      end
    end
  end

  local function on_resolved(resolved)
    if finished then
      return
    end
    finished = true
    stop()
    done(resolved or action)
  end

  if timer then
    timer:start(timeout, 0, function()
      vim.schedule(function()
        if finished then
          return
        end
        finished = true
        stop()
        notify_error(string.format("timed out after %dms resolving '%s'", timeout, action.title or "?"))
      end)
    end)
  end

  local ok, result = pcall(function()
    resolve.resolve_single(action, on_resolved)
  end)

  if not ok then
    finished = true
    stop()
    notify_error(string.format("failed to resolve '%s'", action.title or "?"), result)
  end
end

--- Ejecuta una acción.
---@param action KatanaAction
---@param opts KatanaExecutorOptions|nil
function M.execute(action, opts)
  if not action then
    return
  end

  opts = opts or {}
  opts.bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  opts.win = opts.win or vim.api.nvim_get_current_win()

  if action.disabled then
    local reason = type(action.disabled) == "table" and action.disabled.reason or nil
    vim.notify("Katana: " .. (reason or "action is disabled"), vim.log.levels.WARN)
    return
  end

  local function run(resolved)
    local applied = false
    local ok_edit, err_edit = M.apply_edit(resolved, opts)
    if not ok_edit then
      notify_error(string.format("fallo al aplicar cambios de '%s'", resolved.title or "?"), err_edit)
      return
    end
    applied = true

    local ok_cmd, err_cmd = M.run_command(resolved, opts)
    if not ok_cmd then
      if applied then
        notify_error(string.format("el comando falló tras aplicar cambios parciales para '%s'", resolved.title or "?"), err_cmd)
      else
        notify_error(string.format("fallo al ejecutar comando de '%s'", resolved.title or "?"), err_cmd)
      end
      return
    end

    local ok_fn, err_fn = M.run_execute_fn(resolved, opts)
    if not ok_fn then
      if applied then
        notify_error(string.format("la acción personalizada falló tras aplicar cambios parciales para '%s'", resolved.title or "?"), err_fn)
      else
        notify_error(string.format("fallo en la acción personalizada '%s'", resolved.title or "?"), err_fn)
      end
      return
    end
  end

  if type(action.resolve_fn) == "function" and not action.edit and not action.command then
    wait_resolve(action, opts, run)
    return
  end

  run(action)
end

--- Ejecuta la acción seleccionada en el picker.
function M.run_current()
  local state = require("katana.state")
  local item = state.flat[state.index]

  if not item or item.type ~= "action" then
    return
  end

  M.execute(item.action, {
    bufnr = state.origin_buf or vim.api.nvim_get_current_buf(),
    win = state.origin_win or vim.api.nvim_get_current_win(),
  })
end

return M
