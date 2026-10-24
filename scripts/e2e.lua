-- Prueba end-to-end con un servidor LSP real (clangd): recogida de acciones,
-- picker, preview con el diff, confirmación, aplicación del WorkspaceEdit y undo
-- agrupado con un solo `u`.
--
--   nvim --headless -u NONE -l scripts/e2e.lua
--
-- Requiere `clangd` (mason o en el PATH). Se puede forzar con `KATANA_CLANGD`.

local script = debug.getinfo(1, "S").source:sub(2)
local dir = vim.fn.fnamemodify(script, ":p:h")
local root = vim.fn.fnamemodify(dir, ":h")

vim.opt.rtp:append(root)

local env = dofile(dir .. "/env.lua")
local report = env.reporter()

report.header("Katana.nvim · end-to-end test (clangd)")

local clangd = env.find_clangd()
if not clangd then
  report.skip("clangd no está disponible (define KATANA_CLANGD con la ruta del ejecutable)")
  report.finish()
  return
end

local ok, err = pcall(function()
  local katana = require("katana")
  katana.setup({ ts = { enabled = false }, resolve_on_open = true, resolve_limit = 5 })

  local state = require("katana.state")
  local window = require("katana.ui.window")

  -- Fichero C con un error corregible ("insert ';'").
  local workdir = vim.fn.tempname()
  vim.fn.mkdir(workdir, "p")
  local file = workdir .. "/main.c"
  vim.fn.writefile({ "int main(void) {", "  int x = 1", "  return 0", "}" }, file)
  vim.cmd("edit " .. vim.fn.fnameescape(file))
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "c"

  local client_id = env.start_client({
    name = "clangd",
    cmd = { clangd },
    root_dir = workdir,
  })
  vim.lsp.buf_attach_client(bufnr, client_id)

  vim.wait(20000, function()
    local c = vim.lsp.get_client_by_id(client_id)
    return c ~= nil and c.initialized
  end, 200)

  local client = vim.lsp.get_client_by_id(client_id)
  report.check("cliente clangd inicializado", client ~= nil and client.initialized == true)

  vim.wait(20000, function()
    return #vim.diagnostic.get(bufnr) > 0
  end, 200)
  report.check("diagnósticos de clangd", #vim.diagnostic.get(bufnr) > 0, #vim.diagnostic.get(bufnr))

  -- Cursor sobre el diagnóstico (como haría el usuario con `]d`).
  local first_diag = vim.diagnostic.get(bufnr)[1]
  if first_diag then
    vim.api.nvim_win_set_cursor(0, { first_diag.lnum + 1, first_diag.col })
  end

  katana.code_action()
  vim.wait(15000, function()
    return window.is_open()
  end, 100)

  report.check("picker abierto con LSP real", window.is_open())
  report.check("acciones recibidas", #state.actions > 0, #state.actions)

  local first = state.actions[1]
  report.check("origen lsp:clangd", first ~= nil and first.source == "lsp:clangd", first and first.source)
  report.check("la acción trae WorkspaceEdit", first ~= nil and first.edit ~= nil)

  --- Texto renderizado en cada fila (texto real del buffer).
  local function rows_text()
    if not state.buf_main or not vim.api.nvim_buf_is_valid(state.buf_main) then
      return {}
    end
    return vim.api.nvim_buf_get_lines(state.buf_main, 0, -1, false)
  end

  local rendered = ""
  if state.buf_main then
    rendered = table.concat(rows_text(), "\n")
  end
  report.check("la lista muestra la acción", first ~= nil and rendered:find(first.title, 1, true) ~= nil, rendered:sub(1, 120))

  local preview_text = ""
  if state.buf_preview and vim.api.nvim_buf_is_valid(state.buf_preview) then
    preview_text = table.concat(vim.api.nvim_buf_get_lines(state.buf_preview, 0, -1, false), "\n")
  end
  report.check("preview con diff", preview_text:find(";", 1, true) ~= nil, preview_text:sub(1, 160))

  window.confirm()
  vim.wait(500, function()
    return false
  end)

  report.check("picker cerrado", not window.is_open())
  local after = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  report.check("edit aplicado (punto y coma)", after[2] == "  int x = 1;", vim.inspect(after))
  report.check("foco devuelto", vim.api.nvim_get_current_buf() == bufnr)

  vim.cmd("undo")
  local undone = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  report.check("un solo `u` revierte la acción", undone[2] == "  int x = 1", vim.inspect(undone))

  -- `Client:stop()` es la API moderna; `vim.lsp.stop_client()` está obsoleta.
  pcall(function()
    if client and client.stop then
      client:stop(true)
    else
      vim.lsp.stop_client(client_id, true)
    end
  end)
end)

if not ok then
  report.check("error inesperado", false, err)
end

report.finish()
