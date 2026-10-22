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
local function find_client(action, bufnr)
  local clients = vim.lsp.get_clients({ bufnr = bufnr })

  if action.client_id then
    for _, client in ipairs(clients) do
      if client.id == action.client_id then
        return client
      end
    end
  end

  return clients[1]
end

--- Aplica el `WorkspaceEdit` de una acción.
---@param action KatanaAction
---@param opts KatanaExecutorOptions
---@return boolean ok
function M.apply_edit(action, opts)
  local edit = action.edit
  if type(edit) ~= "table" then
    return true
  end

  local encoding = action.encoding or "utf-16"
  local groups = workspace.collect_edits(edit)

  for _, group in ipairs(groups) do
    local target = workspace.resolve_buf(group, opts.bufnr)
    if target and vim.fn.bufloaded(target) == 1 then
      -- Cierra el bloque de undo previo para que la acción se deshaga sola.
      workspace.close_undo_block(target)
      workspace.apply_edits_to_buffer(target, group.edits, encoding)
    end
  end

  return true
end

--- Ejecuta el comando LSP de una acción.
---@param action KatanaAction
---@param opts KatanaExecutorOptions
---@return boolean ok
function M.run_command(action, opts)
  local command = action.command
  if not command then
    return true
  end

  -- Algunos servidores envían el comando como una cadena simple.
  if type(command) == "string" then
    vim.cmd(command)
    return true
  end

  if type(command) ~= "table" or not command.command then
    return true
  end

  local client = find_client(action, opts.bufnr)
  if not client then
    notify_error(string.format("no LSP client available to run command '%s'", command.command))
    return false
  end

  -- `Client:exec_cmd(cmd, context, handler)`: `cmd` es el objeto completo y el
  -- contexto aporta `bufnr` y `client_id`.
  client:exec_cmd(command, { bufnr = opts.bufnr })

  return true
end

--- Ejecuta la lógica propia de la acción.
---@param action KatanaAction
---@param opts KatanaExecutorOptions
---@return boolean ok
function M.run_execute_fn(action, opts)
  if type(action.execute_fn) ~= "function" then
    return true
  end

  -- Las acciones propias también pueden modificar el buffer: se cierra el bloque
  -- de undo para que su reversión sea independiente.
  workspace.close_undo_block(opts.bufnr)

  action.execute_fn(action)

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
    local ok, err = pcall(function()
      M.apply_edit(resolved, opts)
      M.run_command(resolved, opts)
      M.run_execute_fn(resolved, opts)
    end)

    if not ok then
      notify_error(string.format("failed to execute '%s'", resolved.title or "?"), err)
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
