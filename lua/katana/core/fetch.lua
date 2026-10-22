---@mod katana.core.fetch Motor de recogida de acciones
---
--- El motor combina cuatro fuentes:
---   1. Todos los clientes LSP attached al buffer (`textDocument/codeAction`).
---   2. Proveedores registrados por el usuario (`katana.register_provider`).
---   3. El proveedor basado en Tree-sitter.
---   4. Las acciones registradas por el usuario (`katana.register_action`).
---
--- Todas las acciones se normalizan a la misma forma (`KatanaAction`) para que el
--- resto del plugin no tenga que saber de dónde salieron.

local workspace = require("katana.lsp.workspace")
local config = require("katana.config")

local M = {}

---@class KatanaAction
---@field title string Título legible de la acción
---@field kind string|nil Kind LSP (quickfix, refactor.extract, source.fixAll, ...)
---@field source string Origen (`lsp:lua_ls`, `ts`, `user:mi-plugin`, ...)
---@field raw any Payload original
---@field resolve_fn fun(cb: fun(action: KatanaAction))|nil Resolución diferida
---@field execute_fn fun(action: KatanaAction)|nil Ejecución personalizada
---@field edit vim.lsp.WorkspaceEdit|nil Cambios a aplicar
---@field command lsp.Command|nil Comando a ejecutar
---@field diagnostics lsp.Diagnostic[]|nil Diagnósticos relacionados
---@field sources string[]|nil Orígenes fusionados (tras deduplicar)
---@field client_id integer|nil Cliente LSP propietario
---@field encoding KatanaEncoding|nil Codificación de posiciones del cliente
---@field isPreferred boolean|nil
---@field disabled table|boolean|nil
---@field _client_name string|nil Nombre del cliente LSP (compatibilidad)
---@field _bufnr integer|nil Buffer de origen (compatibilidad)

---@class KatanaContext
---@field bufnr integer
---@field win integer
---@field uri string
---@field range lsp.Range
---@field encoding KatanaEncoding
---@field diagnostics lsp.Diagnostic[]
---@field cursor { row: integer, col: integer }
---@field scope '"cursor"'|'"line"'|'"visual"'

--------------------------------------------------------------------------------
-- Contexto
--------------------------------------------------------------------------------

--- Convierte un diagnóstico de `vim.diagnostic` en un `lsp.Diagnostic`.
---
--- Sólo se copian los campos definidos por el protocolo. Mandar el diagnóstico de
--- Neovim tal cual (con `lnum`, `col`, `user_data`, ...) hace fallar a los
--- servidores con deserialización estricta (p. ej. `csharp_ls` responde
--- `Internal error: JsonSerializationException`).
---@param diagnostic table
---@param encoding KatanaEncoding
---@param lines string[]
---@return lsp.Diagnostic
function M.sanitize_diagnostic(diagnostic, encoding, lines)
  local start_line = diagnostic.lnum or 0
  local end_line = diagnostic.end_lnum or start_line

  local start_text = lines[start_line + 1] or ""
  local end_text = lines[end_line + 1] or start_text

  local result = {
    range = {
      start = {
        line = start_line,
        character = workspace.byte_to_char(start_text, diagnostic.col or 0, encoding),
      },
      ["end"] = {
        line = end_line,
        character = workspace.byte_to_char(end_text, diagnostic.end_col or 0, encoding),
      },
    },
    message = diagnostic.message or "",
  }

  if diagnostic.severity then
    result.severity = diagnostic.severity
  end
  if diagnostic.source then
    result.source = diagnostic.source
  end
  if diagnostic.code ~= nil then
    result.code = diagnostic.code
  end

  return result
end

---@param diagnostic table
---@param range lsp.Range
---@param scope string|nil
---@param cursor { row: integer, col: integer }|nil
---@return boolean
local function diagnostic_in_range(diagnostic, range, scope, cursor)
  local start_line = diagnostic.lnum or 0
  local end_line = diagnostic.end_lnum or start_line

  -- El filtro es por líneas (no por columnas): basta con tener el cursor en la
  -- línea del error para que su quickfix esté disponible. Es más generoso que
  -- `vim.lsp.buf.code_action()`, que exige que el cursor caiga dentro del rango
  -- exacto del diagnóstico.
  local from = range and range.start and range.start.line or 0
  local to = range and range["end"] and range["end"].line or from

  if cursor and scope == "cursor" then
    from = math.min(from, cursor.row)
    to = math.max(to, cursor.row)
  end

  return start_line <= to and end_line >= from
end

--- Recoge los diagnósticos del buffer que intersectan el rango pedido.
---@param bufnr integer
---@param range lsp.Range
---@param encoding KatanaEncoding
---@param scope string|nil
---@param cursor { row: integer, col: integer }|nil
---@return lsp.Diagnostic[]
function M.collect_diagnostics(bufnr, range, encoding, scope, cursor)
  local result = {}
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  for _, diagnostic in ipairs(vim.diagnostic.get(bufnr)) do
    if diagnostic_in_range(diagnostic, range, scope, cursor) then
      result[#result + 1] = M.sanitize_diagnostic(diagnostic, encoding, lines)
    end
  end

  return result
end

--- Devuelve el rango de la selección visual actual.
---
--- Las marcas `'<` y `'>` sólo se actualizan **al salir** del modo visual, así que
--- `vim.lsp.util.make_given_range_params()` devuelve la selección *anterior* (o
--- un rango vacío si nunca se ha hecho ninguna). Para pedir las acciones de la
--- selección actual hay que forzar la salida del modo visual (las marcas se
--- actualizan) y devolver afterwards el cursor a su sitio.
---@param bufnr integer
---@param win integer
---@param encoding KatanaEncoding
---@return lsp.Range|nil
function M.visual_range(bufnr, win, encoding)
  local mode = vim.api.nvim_get_mode().mode

  if mode == "v" or mode == "V" or mode == "\22" then
    local cursor = vim.api.nvim_win_get_cursor(win)

    -- ESC: cierra la selección visual y actualiza las marcas '< y '>.
    pcall(vim.cmd, "normal! \27")

    -- El cursor se queda donde estaba (al final de la selección).
    pcall(vim.api.nvim_win_set_cursor, win, cursor)
  end

  local start_mark = vim.api.nvim_buf_get_mark(bufnr, "<")
  local end_mark = vim.api.nvim_buf_get_mark(bufnr, ">")

  if not start_mark or not end_mark or start_mark[1] == 0 or end_mark[1] == 0 then
    return nil
  end

  local start_line = vim.api.nvim_buf_get_lines(bufnr, start_mark[1] - 1, start_mark[1], false)[1] or ""
  local end_line = vim.api.nvim_buf_get_lines(bufnr, end_mark[1] - 1, end_mark[1], false)[1] or ""

  -- `nvim_buf_get_mark` devuelve la fila en base 1 y la columna en base 0.
  local start_char = workspace.byte_to_char(start_line, start_mark[2], encoding)
  local end_char = workspace.byte_to_char(end_line, end_mark[2], encoding)

  -- El final del rango LSP es exclusivo: la marca '> apunta al último carácter
  -- seleccionado, así que (salvo con 'selection' = "exclusive") hay que sumarle
  -- uno.
  if vim.o.selection ~= "exclusive" then
    end_char = end_char + 1
  end

  return {
    start = { line = start_mark[1] - 1, character = start_char },
    ["end"] = { line = end_mark[1] - 1, character = end_char },
  }
end

--- Calcula el rango pedido para un cliente concreto.
---@param ctx KatanaContext
---@param encoding KatanaEncoding
---@return lsp.Range
function M.make_range(ctx, encoding)
  if ctx.scope == "visual" then
    return M.visual_range(ctx.bufnr, ctx.win, encoding)
      or vim.lsp.util.make_given_range_params(nil, nil, ctx.bufnr, encoding).range
  end

  if ctx.scope == "line" then
    local row = ctx.cursor.row
    local text = vim.api.nvim_buf_get_lines(ctx.bufnr, row, row + 1, false)[1] or ""
    return {
      start = { line = row, character = 0 },
      ["end"] = { line = row, character = #text },
    }
  end

  return vim.lsp.util.make_range_params(ctx.win, encoding).range
end

--------------------------------------------------------------------------------
-- Rango de la petición
--------------------------------------------------------------------------------

--- ¿Es un carácter válido de identificador?
---@param ch string
---@return boolean
local function is_word_char(ch)
  return ch ~= "" and ch:match("[%w_]") ~= nil
end

--- Devuelve el rango (en bytes) de la palabra bajo una posición.
---
--- Los servidores que enlazan sus *code actions* a un token concreto (Roslyn con
--- "Generar método", por ejemplo) sólo las ofrecen si el rango pedido corta ese
--- token. Con el rango del cursor (de ancho cero) eso sólo ocurre si el cursor
--- cae exactamente sobre el identificador, así que se ensancha al identificador.
---
--- Si el cursor no está sobre un identificador pero justo detrás de uno, se
--- toma ese identificador (igual que hace el editor al pulsar `cw`).
---@param bufnr integer
---@param row integer fila (0-based)
---@param col integer columna en bytes (0-based)
---@return integer|nil start_col byte inicial
---@return integer|nil stop_col byte final (excluido)
function M.word_range(bufnr, row, col)
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, row, row + 1, false)
  if not ok then
    return nil, nil
  end

  local line = lines and lines[1] or ""
  if line == "" then
    return nil, nil
  end

  --- Carácter en un offset de byte (0-based).
  ---@param offset integer
  ---@return string
  local function char_at(offset)
    if offset < 0 or offset >= #line then
      return ""
    end
    return line:sub(offset + 1, offset + 1)
  end

  local start_col, stop_col

  if is_word_char(char_at(col)) then
    start_col, stop_col = col, col + 1
  elseif col > 0 and is_word_char(char_at(col - 1)) then
    start_col, stop_col = col - 1, col
  else
    return nil, nil
  end

  while start_col > 0 and is_word_char(char_at(start_col - 1)) do
    start_col = start_col - 1
  end

  while stop_col < #line and is_word_char(char_at(stop_col)) do
    stop_col = stop_col + 1
  end

  if start_col >= stop_col then
    return nil, nil
  end

  return start_col, stop_col
end

--- Devuelve el rango que cubre todos los diagnósticos indicados.
---@param diagnostics lsp.Diagnostic[]
---@return lsp.Range|nil
function M.union_range(diagnostics)
  local start_line, start_char, stop_line, stop_char

  for _, diagnostic in ipairs(diagnostics or {}) do
    local range = diagnostic and diagnostic.range
    if range and range.start and range["end"] then
      local s_line = range.start.line or 0
      local e_line = range["end"].line or s_line
      local s_char = range.start.character or 0
      local e_char = range["end"].character or 0

      if start_line == nil then
        start_line, start_char, stop_line, stop_char = s_line, s_char, e_line, e_char
      else
        if s_line < start_line or (s_line == start_line and s_char < start_char) then
          start_line, start_char = s_line, s_char
        end
        if e_line > stop_line or (e_line == stop_line and e_char > stop_char) then
          stop_line, stop_char = e_line, e_char
        end
      end
    end
  end

  if start_line == nil then
    return nil
  end

  return {
    start = { line = start_line, character = start_char },
    ["end"] = { line = stop_line, character = stop_char },
  }
end

--- Calcula el rango completo de una línea del buffer.
---@param bufnr integer
---@param row integer fila (0-based)
---@param encoding KatanaEncoding
---@return lsp.Range
function M.line_range(bufnr, row, encoding)
  local text = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  return {
    start = { line = row, character = 0 },
    ["end"] = { line = row, character = workspace.byte_to_char(text, #text, encoding) },
  }
end

--- Compara dos rangos LSP.
---@param a lsp.Range|nil
---@param b lsp.Range|nil
---@return boolean
function M.ranges_equal(a, b)
  if not a or not b then
    return a == b
  end

  return a.start.line == b.start.line
    and a.start.character == b.start.character
    and a["end"].line == b["end"].line
    and a["end"].character == b["end"].character
end

--- Calcula los rangos que se piden al servidor en `textDocument/codeAction`.
---
--- El rango del cursor (de ancho cero) es demasiado estricto para los servidores
--- que asocian sus acciones a un token o a un diagnóstico: con él, "Generar
--- método Suma" (Roslyn) sólo aparece si el cursor cae *exactamente* sobre el
--- identificador. Por eso en modo "auto" se piden varios rangos:
---
---  1. El rango exacto de los diagnósticos de la línea del cursor (es lo que
---     el servidor usa para decidir qué *code action* ofrece).
---  2. Si no hay diagnósticos, el identificador bajo el cursor.
---  3. Siempre la línea completa: es la red de seguridad que hace que Roslyn
---     ofrezca "Generar método X" aunque el cursor esté en otra palabra de la
---     línea (por ejemplo sobre `Console` en `Console.WriteLine(Suma(7,5.2))`).
---
--- Las respuestas de todos los rangos se fusionan, así que en la práctica el
--- usuario ve la unión de las acciones (los duplicados se eliminan al ordenar).
---
--- Se puede forzar con `code_action_range = "cursor"` o `"line"`.
---@param ctx KatanaContext
---@param encoding KatanaEncoding
---@param diagnostics lsp.Diagnostic[]
---@return lsp.Range[]
function M.make_request_ranges(ctx, encoding, diagnostics)
  local mode = config.options.code_action_range or "auto"

  if ctx.scope == "visual" then
    return {
      M.visual_range(ctx.bufnr, ctx.win, encoding)
        or vim.lsp.util.make_given_range_params(nil, nil, ctx.bufnr, encoding).range,
    }
  end

  if mode == "line" or ctx.scope == "line" then
    return { M.line_range(ctx.bufnr, ctx.cursor.row, encoding) }
  end

  if mode == "cursor" then
    return { vim.lsp.util.make_range_params(ctx.win, encoding).range }
  end

  -- "auto": primero el rango real de los diagnósticos.
  local ranges = {}
  local union = M.union_range(diagnostics)

  if union then
    ranges[#ranges + 1] = union
  else
    -- Después, el identificador bajo el cursor.
    local start_col, stop_col = M.word_range(ctx.bufnr, ctx.cursor.row, ctx.cursor.col)
    if start_col then
      local text = vim.api.nvim_buf_get_lines(ctx.bufnr, ctx.cursor.row, ctx.cursor.row + 1, false)[1] or ""
      ranges[#ranges + 1] = {
        start = { line = ctx.cursor.row, character = workspace.byte_to_char(text, start_col, encoding) },
        ["end"] = { line = ctx.cursor.row, character = workspace.byte_to_char(text, stop_col, encoding) },
      }
    else
      ranges[#ranges + 1] = vim.lsp.util.make_range_params(ctx.win, encoding).range
    end
  end

  -- Y la línea completa, que es la que garantiza las acciones ligadas al error
  -- de la línea (Roslyn, entre otros).
  local line = M.line_range(ctx.bufnr, ctx.cursor.row, encoding)
  if not M.ranges_equal(ranges[#ranges], line) then
    ranges[#ranges + 1] = line
  end

  return ranges
end

--- Calcula el rango principal de la petición (el primero de `make_request_ranges`).
---@param ctx KatanaContext
---@param encoding KatanaEncoding
---@param diagnostics lsp.Diagnostic[]
---@return lsp.Range
function M.make_request_range(ctx, encoding, diagnostics)
  return M.make_request_ranges(ctx, encoding, diagnostics)[1]
end

--- Filtra los diagnósticos que caen en una fila.
---@param diagnostics lsp.Diagnostic[]|nil
---@param row integer fila (0-based)
---@return lsp.Diagnostic[]
function M.diagnostics_on_row(diagnostics, row)
  local result = {}

  for _, diagnostic in ipairs(diagnostics or {}) do
    local range = diagnostic and diagnostic.range
    if range and range.start then
      local start_line = range.start.line or 0
      local end_line = range["end"] and range["end"].line or start_line
      if start_line <= row and end_line >= row then
        result[#result + 1] = diagnostic
      end
    end
  end

  return result
end

--- Pide los diagnósticos al servidor (modelo *pull*).
---
--- Roslyn usa *pull diagnostics*: hasta que el proyecto no está cargado, Neovim
--- puede no tener ningún diagnóstico en el buffer. Pedirlos al abrir el picker
--- hace que el rango de la petición pueda ser el del error aunque todavía no
--- se haya publicado.
---@param client vim.lsp.Client
---@param ctx KatanaContext
---@param cb fun(diagnostics: lsp.Diagnostic[])
function M.pull_diagnostics(client, ctx, cb)
  cb = cb or function() end

  if not client:supports_method("textDocument/diagnostic", ctx.bufnr) then
    cb({})
    return
  end

  local finished = false
  local timer = vim.uv.new_timer()

  local function finish(result)
    if finished then
      return
    end
    finished = true

    if timer then
      pcall(function()
        timer:stop()
        if not timer:is_closing() then
          timer:close()
        end
      end)
    end

    cb(result or {})
  end

  -- Si el servidor no contesta, se sigue con lo que haya (sin diagnostics).
  timer:start(config.options.pull_timeout or 2000, 0, function()
    vim.schedule(function()
      finish({})
    end)
  end)

  local ok = pcall(function()
    client:request("textDocument/diagnostic", {
      textDocument = { uri = ctx.uri },
    }, function(err, result)
      if err ~= nil or type(result) ~= "table" then
        finish({})
        return
      end

      finish(result.items or {})
    end, ctx.bufnr)
  end)

  if not ok then
    finish({})
  end
end

--- Construye el contexto de una petición de acciones.
---@param bufnr integer|nil
---@param win integer|nil
---@param opts table|nil
---@return KatanaContext
function M.build_context(bufnr, win, opts)
  opts = opts or {}

  bufnr = bufnr or vim.api.nvim_get_current_buf()
  win = win or vim.api.nvim_get_current_win()

  if not vim.api.nvim_win_is_valid(win) then
    win = vim.api.nvim_get_current_win()
  end

  -- La codificación de posiciones la fija el cliente LSP; si hay varios se usa la
  -- del primero (Neovim tampoco puede hacer mejor: una misma acción puede estar
  -- dirigida a un único cliente).
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  local encoding = "utf-16"
  for _, client in ipairs(clients) do
    if client.offset_encoding then
      encoding = client.offset_encoding
      break
    end
  end

  local scope = opts.scope or "cursor"
  local cursor = vim.api.nvim_win_get_cursor(win)

  local ctx = {
    bufnr = bufnr,
    win = win,
    uri = vim.uri_from_bufnr(bufnr),
    encoding = encoding,
    diagnostics = {},
    cursor = { row = cursor[1] - 1, col = cursor[2] },
    scope = scope,
  }

  ctx.range = M.make_range(ctx, encoding)
  ctx.diagnostics = M.collect_diagnostics(bufnr, ctx.range, encoding, ctx.scope, ctx.cursor)

  return ctx
end

--------------------------------------------------------------------------------
-- Acciones de LSP
--------------------------------------------------------------------------------

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
function M.normalize_lsp_actions(result, client, ctx)
  local actions = {}

  for _, raw in ipairs(result or {}) do
    if type(raw) == "table" and raw.title then
      local action = {
        title = raw.title,
        kind = raw.kind,
        source = "lsp:" .. (client.name or "unknown"),
        raw = raw,
        diagnostics = raw.diagnostics or (is_quickfix(raw) and ctx.diagnostics or nil),
        client_id = client.id,
        encoding = client.offset_encoding or ctx.encoding,
        isPreferred = raw.isPreferred or false,
        disabled = raw.disabled or nil,
        -- El servidor puede enviar la edición y el comando ya resueltos: no hay
        -- que esperar al `codeAction/resolve` para aplicarlos.
        edit = raw.edit or nil,
        command = raw.command or nil,
        data = raw.data or nil,
        _client_name = client.name,
        _client_id = client.id,
        _bufnr = ctx.bufnr,
      }

      -- `codeAction/resolve` sólo hace falta si el servidor ha devuelto `data`.
      if raw.data and client:supports_method("codeAction/resolve", ctx.bufnr) then
        action.resolve_fn = function(cb)
          if client.is_stopped and client:is_stopped() then
            cb(action)
            return
          end

          -- Los parámetros de `codeAction/resolve` son la propia acción.
          client:request("codeAction/resolve", raw, function(err, resolved)
            if err == nil and resolved then
              action.edit = resolved.edit or action.edit
              action.command = resolved.command or action.command
              action.isPreferred = resolved.isPreferred or action.isPreferred
              action.disabled = resolved.disabled or action.disabled
              action.data = resolved.data or action.data
              action.raw = resolved
            end
            cb(action)
          end, ctx.bufnr)
        end
      end

      actions[#actions + 1] = action
    end
  end

  return actions
end

--- Pide acciones a un cliente LSP.
---@param client vim.lsp.Client
---@param ctx KatanaContext
---@param opts table
---@param done fun(actions: KatanaAction[])
local function request_lsp(client, ctx, opts, done)
  if not client:supports_method("textDocument/codeAction", ctx.bufnr) then
    done({})
    return
  end

  local encoding = client.offset_encoding or ctx.encoding

  -- El rango y los diagnósticos se recalculan con la codificación del propio
  -- cliente: cada servidor mide las posiciones en sus propias unidades.
  local base_range = M.make_range(ctx, encoding)

  local diagnostics = M.collect_diagnostics(ctx.bufnr, base_range, encoding, ctx.scope, ctx.cursor)

  local context = {
    diagnostics = diagnostics,
  }

  -- `triggerKind` es obligatorio en LSP 3.16 y opcional en 3.17: Neovim lo
  -- envía siempre y algunos servidores (lua_ls, rust-analyzer) lo leen sin
  -- comprobar que exista.
  if opts.trigger_kind ~= false then
    context.triggerKind = opts.trigger_kind or vim.lsp.protocol.CodeActionTriggerKind.Invoked
  end

  -- `only` sólo se envía si se pide explícitamente: algunos servidores
  -- deserializan el contexto de forma estricta.
  if opts.only and #opts.only > 0 then
    context.only = opts.only
  end

  local collected = {}
  local finished = false

  local function finish()
    if finished then
      return
    end
    finished = true
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

    local ok = pcall(function()
      client:request("textDocument/codeAction", params, function(err, result)
        if err ~= nil or type(result) ~= "table" then
          cb({})
          return
        end

        cb(M.normalize_lsp_actions(result, client, ctx))
      end, ctx.bufnr)
    end)

    if not ok then
      cb({})
    end
  end

  --- Envía la petición con todos los rangos calculados y fusiona las respuestas.
  ---@param diags lsp.Diagnostic[]
  local function run(diags)
    context.diagnostics = diags

    local ranges = M.make_request_ranges(ctx, encoding, diags)

    if #ranges == 0 then
      finish()
      return
    end

    local pending = #ranges

    for _, request_range in ipairs(ranges) do
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
    M.pull_diagnostics(client, ctx, function(pulled)
      run(M.diagnostics_on_row(pulled, ctx.cursor.row))
    end)
  else
    run(diagnostics)
  end
end

--------------------------------------------------------------------------------
-- Orquestación
--------------------------------------------------------------------------------

--- Recoge acciones de todas las fuentes y se las pasa a `done`.
---@param ctx KatanaContext
---@param opts table|nil
---@param done fun(actions: KatanaAction[])
function M.get_all_actions(ctx, opts, done)
  opts = opts or {}

  local cfg = config.options
  local collected = {}

  local function collect(actions)
    for _, action in ipairs(actions or {}) do
      collected[#collected + 1] = action
    end
  end

  -- 1. Proveedores registrados por el usuario.
  local ok_providers, provider_actions = pcall(require("katana.core.providers").collect, ctx)
  if ok_providers and type(provider_actions) == "table" then
    collect(provider_actions)
  end

  -- 2. Proveedor de Tree-sitter.
  if cfg.ts and cfg.ts.enabled then
    local ok_ts, ts_actions = pcall(require("katana.core.treesitter").get_actions, ctx)
    if ok_ts and type(ts_actions) == "table" then
      collect(ts_actions)
    end
  end

  -- 3. Acciones registradas por el usuario.
  local ok_user, user_actions = pcall(require("katana.register").get_actions, ctx)
  if ok_user and type(user_actions) == "table" then
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
    done(collected)
  end

  for _, client in ipairs(clients) do
    pending = pending + 1
    request_lsp(client, ctx, opts, function(actions)
      collect(actions)
      pending = pending - 1
      maybe_finish()
    end)
  end

  issuing = false
  maybe_finish()
end

--- Punto de entrada: recoge las acciones del buffer actual y abre el picker.
---@param opts table|nil
function M.get(opts)
  opts = opts or {}

  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local win = opts.win or vim.api.nvim_get_current_win()

  local ctx = M.build_context(bufnr, win, opts)

  M.get_all_actions(ctx, opts, function(actions)
    require("katana")._on_actions(actions, opts, ctx)
  end)
end

return M
