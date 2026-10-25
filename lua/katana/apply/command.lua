---@mod katana.apply.command Ejecución de comandos LSP
---
--- Selecciona el cliente LSP que debe ejecutar `workspace/executeCommand` y
--- distingue errores síncronos de efectos que el servidor puede completar más
--- tarde.

local optional = require("katana.core.optional")

local M = {}

---@param message string
---@param err any|nil
---@return string
local function format_error(message, err)
  if err == nil then
    return message
  end
  return string.format("%s: %s", message, tostring(err))
end

--- Devuelve el cliente LSP asociado a una acción.
---@param action KatanaAction
---@param opts KatanaExecutorOptions
---@return vim.lsp.Client|nil
---@return string|nil error
function M.find_client(action, opts)
  local clients = vim.lsp.get_clients({ bufnr = opts.bufnr })

  local function by_id(id)
    for _, client in ipairs(clients) do
      if client.id == id then
        return client
      end
    end
    return nil
  end

  local action_client_id = optional.value(action.client_id)
  local opts_client_id = optional.value(opts.client_id)

  if action_client_id ~= nil then
    local client = by_id(action_client_id)
    if client then
      return client
    end
    return nil, string.format(
      "el cliente LSP '%s' ya no está disponible para esta acción",
      action._client_name or tostring(action_client_id)
    )
  end

  if opts_client_id ~= nil then
    local client = by_id(opts_client_id)
    if client then
      return client
    end
    return nil, string.format("el cliente LSP %s indicado en opts.client_id no está disponible", tostring(opts_client_id))
  end

  local source = optional.value(action.source) or ""
  local client_name = optional.value(action._client_name)
  if client_name or source:match("^lsp:") then
    local name = client_name or source:match("^lsp:(.+)$")
    for _, client in ipairs(clients) do
      if client.name == name then
        return client
      end
    end
    return nil, string.format("el cliente LSP '%s' ya no está disponible para esta acción", tostring(name))
  end

  -- Una acción de un proveedor/usuario con `command` no debe ejecutarse con un
  -- cliente arbitrario si hay varios conectados.
  if #clients == 1 then
    return clients[1]
  end
  if #clients == 0 then
    return nil, "no hay ningún cliente LSP disponible para ejecutar el comando"
  end

  return nil, "hay varios clientes LSP y la acción no indica cuál debe ejecutar el comando"
end

--- Ejecuta el comando LSP de una acción.
---@param action KatanaAction
---@param opts KatanaExecutorOptions
---@return boolean ok
---@return string|nil error
---@return boolean attempted
function M.run(action, opts)
  local command = optional.value(action.command)
  if command == nil then
    return true, nil, false
  end

  -- Algunos servidores envían el comando como una cadena simple (comando Vim).
  if type(command) == "string" then
    local ok_cmd, err_cmd = pcall(vim.cmd, command)
    if not ok_cmd then
      return false, format_error("error al ejecutar comando", err_cmd), true
    end
    return true, nil, true
  end

  if type(command) ~= "table" or type(command.command) ~= "string" or command.command == "" then
    return false, "comando LSP inválido (falta 'command')", true
  end

  local client, err_client = M.find_client(action, opts)
  if not client then
    return false, err_client or "no hay cliente LSP para ejecutar el comando", true
  end

  -- `Client:exec_cmd(cmd, context, handler)`: `cmd` es el objeto completo y el
  -- contexto aporta `bufnr` y `client_id`. La respuesta del servidor puede
  -- llegar después: aquí sólo se detectan los errores síncronos.
  local ok_exec, err_exec = pcall(function()
    client:exec_cmd(command, { bufnr = opts.bufnr })
  end)
  if not ok_exec then
    return false, format_error(string.format("error al ejecutar comando '%s'", command.command), err_exec), true
  end

  return true, nil, true
end

return M
