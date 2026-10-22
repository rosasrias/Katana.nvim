---@mod katana.core.debug Diagnóstico de la petición de code actions
---
--- Recoge toda la información que determina qué acciones se muestran y la
--- devuelve como texto: clientes LSP conectados, diagnósticos del buffer,
--- rangos pedidos al servidor y acciones recibidas.
---
--- Se usa desde el comando `:KatanaDebug`.

local M = {}

--- Recoge la información de depuración de un buffer.
---@param opts table|nil
---   - `bufnr` integer|nil
---   - `win` integer|nil
---   - `scope` string|nil
---@return string[] líneas del informe
function M.collect(opts)
  opts = opts or {}

  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local win = opts.win or vim.api.nvim_get_current_win()

  local fetch = require("katana.core.fetch")
  local config = require("katana.config")

  local lines = {}
  local function add(fmt, ...)
    if select("#", ...) > 0 then
      lines[#lines + 1] = string.format(fmt, ...)
    else
      lines[#lines + 1] = fmt
    end
  end

  local ok_cursor, cursor = pcall(vim.api.nvim_win_get_cursor, win)
  local row = ok_cursor and cursor[1] or 0
  local col = ok_cursor and cursor[2] or 0

  add("Katana · depuración")
  add("  buffer: %d  (%s)", bufnr, vim.api.nvim_buf_get_name(bufnr))
  add("  filetype: %s", tostring(vim.bo[bufnr].filetype))
  add("  cursor: %d:%d  (línea %d)", row, col, row)
  add("  code_action_range: %s", tostring(config.options.code_action_range))
  add("  pull_diagnostics: %s", tostring(config.options.pull_diagnostics))

  ---------------------------------------------------------------- clientes
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  add("  clientes LSP: %d", #clients)

  for _, client in ipairs(clients) do
    add(
      "    - %s (id=%d) root=%s",
      client.name,
      client.id,
      tostring(client.root_dir)
    )
    add(
      "        codeAction=%s  diagnostic=%s  encoding=%s",
      tostring(client:supports_method("textDocument/codeAction", bufnr)),
      tostring(client:supports_method("textDocument/diagnostic", bufnr)),
      tostring(client.offset_encoding)
    )
  end

  if #clients == 0 then
    add("    (ningún cliente LSP conectado a este buffer)")
  end

  ------------------------------------------------------------ diagnósticos
  local buffer_diagnostics = vim.diagnostic.get(bufnr)
  add("  diagnósticos del buffer: %d", #buffer_diagnostics)

  for _, diagnostic in ipairs(buffer_diagnostics) do
    add(
      "    - [%s] %d:%d  %s",
      tostring(diagnostic.code),
      diagnostic.lnum + 1,
      diagnostic.col,
      tostring(diagnostic.message)
    )
  end

  ------------------------------------------------------------------ contexto
  local ctx = fetch.build_context(bufnr, win, opts)
  add("  diagnósticos en la línea del cursor: %d", #ctx.diagnostics)

  local ranges = fetch.make_request_ranges(ctx, ctx.encoding, ctx.diagnostics)
  add("  rangos pedidos: %d", #ranges)

  for i, range in ipairs(ranges) do
    add(
      "    - %d) %d:%d -> %d:%d",
      i,
      range.start.line,
      range.start.character,
      range["end"].line,
      range["end"].character
    )
  end

  ------------------------------------------------------------------ acciones
  local actions = {}
  local finished = false

  fetch.get_all_actions(ctx, opts, function(result)
    actions = result or {}
    finished = true
  end)

  local deadline = vim.uv.now() + 5000
  while not finished and vim.uv.now() < deadline do
    vim.wait(50)
  end

  add("  acciones recibidas: %d", #actions)

  for _, action in ipairs(actions) do
    add("    - %q  kind=%s  source=%s", tostring(action.title), tostring(action.kind), tostring(action.source))
  end

  --------------------------------------------------------- fase del picker
  -- Lo que realmente llegó a pintarse: si `filtered` es 0 pero `actions` no,
  -- el problema está en el filtro (p. ej. texto colado en el prompt).
  local state = require("katana.state")
  local last = state.last or {}

  add("")
  add("  picker:")
  add("    fase: %s", tostring(last.phase or "(nunca se abrió)"))
  add(
    "    abierto=%s  cargando=%s  filtro=%q",
    tostring(last.open),
    tostring(last.loading),
    tostring(last.query or "")
  )
  add(
    "    acciones=%s  filtradas=%s  filas=%s",
    tostring(last.actions),
    tostring(last.filtered),
    tostring(last.flat)
  )

  if last.error then
    add("    error: %s", tostring(last.error))
  end

  if state.open then
    add(
      "    (ahora mismo) acciones=%d  filtradas=%d  filas=%d  filtro=%q",
      #state.actions,
      #state.filtered,
      #state.flat,
      state.query
    )
  end

  return lines
end

--- Muestra el informe de depuración.
---@param opts table|nil
---@return string texto del informe
function M.report(opts)
  local lines = M.collect(opts)
  local text = table.concat(lines, "\n")

  -- Se deja una copia en disco por si hay que compartirla.
  local path = vim.fn.tempname() .. "-katana.txt"
  pcall(function()
    vim.fn.writefile(lines, path)
  end)

  vim.api.nvim_echo({ { text, "Normal" } }, true, {})

  return text
end

return M
