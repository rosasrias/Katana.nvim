---@mod katana.core.fetch.diagnostics Diagnósticos para codeAction
---
--- Convierte los diagnósticos de `vim.diagnostic` al formato LSP y, si el
--- servidor no los ha publicado todavía, los pide con *pull diagnostics*.

local config = require("katana.config")
local encoding_module = require("katana.lsp.encoding")
local optional = require("katana.core.optional")

local M = {}

--- Convierte un diagnóstico de `vim.diagnostic` en un `lsp.Diagnostic`.
---
--- Sólo se copian los campos definidos por el protocolo. Mandar el diagnóstico
--- de Neovim tal cual (con `lnum`, `col`, `user_data`, ...) hace fallar a los
--- servidores con deserialización estricta (p. ej. `csharp_ls` responde
--- `Internal error: JsonSerializationException`).
---@param diagnostic table
---@param encoding KatanaEncoding
---@param lines string[]
---@return lsp.Diagnostic
function M.sanitize(diagnostic, encoding, lines)
  local start_line = diagnostic.lnum or 0
  local end_line = diagnostic.end_lnum or start_line

  local start_text = lines[start_line + 1] or ""
  local end_text = lines[end_line + 1] or start_text

  local result = {
    range = {
      start = {
        line = start_line,
        character = encoding_module.byte_to_char(start_text, diagnostic.col or 0, encoding),
      },
      ["end"] = {
        line = end_line,
        character = encoding_module.byte_to_char(end_text, diagnostic.end_col or 0, encoding),
      },
    },
    message = diagnostic.message or "",
  }

  local severity = optional.value(diagnostic.severity)
  local source = optional.value(diagnostic.source)
  local code = optional.value(diagnostic.code)

  if severity ~= nil then
    result.severity = severity
  end
  if source ~= nil then
    result.source = source
  end
  if code ~= nil then
    result.code = code
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
function M.collect(bufnr, range, encoding, scope, cursor)
  local result = {}
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  for _, diagnostic in ipairs(vim.diagnostic.get(bufnr)) do
    if diagnostic_in_range(diagnostic, range, scope, cursor) then
      result[#result + 1] = M.sanitize(diagnostic, encoding, lines)
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
function M.pull(client, ctx, cb)
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
  if timer then
    timer:start(config.options.pull_timeout or 2000, 0, function()
      vim.schedule(function()
        finish({})
      end)
    end)
  end

  local ok = pcall(function()
    client:request("textDocument/diagnostic", {
      textDocument = { uri = ctx.uri },
    }, function(err, result)
      if err ~= nil or type(result) ~= "table" then
        finish({})
        return
      end

      finish(optional.value(result.items) or {})
    end, ctx.bufnr)
  end)

  if not ok then
    finish({})
  end
end

return M
