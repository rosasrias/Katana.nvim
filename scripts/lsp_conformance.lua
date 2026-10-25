-- Pruebas de conformidad LSP para Katana.
--
--   nvim --headless -u NONE -l scripts/lsp_conformance.lua
--
-- Valida resolución, deduplicación con payloads distintos, WorkspaceEdit
-- multi-archivo, conversión de codificación y validación de ediciones.

local script = debug.getinfo(1, "S").source:sub(2)
local dir = vim.fn.fnamemodify(script, ":p:h")
local root = vim.fn.fnamemodify(dir, ":h")

vim.opt.rtp:append(root)

local env = dofile(dir .. "/env.lua")
local report = env.reporter()

report.header("Katana.nvim · LSP conformance")

local katana = require("katana")
katana.setup({ ts = { enabled = false }, resolve_on_open = false })

-- 1) Deduplicación: mismo título/kind pero distinto edit
local prio = require("katana.core.prioritize")
local a1 = {
  title = "Organize imports",
  kind = "source.organizeImports",
  source = "lsp:a",
  edit = { changes = { ["file:///a.lua"] = { { range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } }, newText = "A" } } } },
}
local a2 = {
  title = "Organize imports",
  kind = "source.organizeImports",
  source = "lsp:b",
  edit = { changes = { ["file:///b.lua"] = { { range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } }, newText = "B" } } } },
}
local ded = prio.filter_and_sort({ a1, a2 }, nil)
report.check("dedupe conserva acciones con distintos edits", #ded == 2, #ded)

-- Acciones sin payload ejecutable: sí son equivalentes y se fusionan.
local b1 = { title = "Organize imports", kind = "source.organizeImports", source = "lsp:a" }
local b2 = { title = "Organize imports", kind = "source.organizeImports", source = "lsp:b" }
local ded_same = prio.filter_and_sort({ b1, b2 }, nil)
report.check("dedupe fusiona acciones idénticas", #ded_same == 1, #ded_same)
report.check("orígenes fusionados", ded_same[1] and #(ded_same[1].sources or {}) == 2, ded_same[1] and #(ded_same[1].sources or {}))

-- Mismo edit: también se fusionan.
local c1 = vim.deepcopy(a1)
local c2 = vim.deepcopy(a1)
c2.source = "lsp:c"
local ded_same_edit = prio.filter_and_sort({ c1, c2 }, nil)
report.check("dedupe fusiona mismo edit", #ded_same_edit == 1, #ded_same_edit)

-- Distinto comando: no se fusionan.
local d1 = { title = "Rename", kind = "refactor.rewrite", source = "lsp:a", command = { command = "a" } }
local d2 = { title = "Rename", kind = "refactor.rewrite", source = "lsp:b", command = { command = "b" } }
report.check("dedupe conserva comandos distintos", #prio.filter_and_sort({ d1, d2 }, nil) == 2)

-- 2) Validación de WorkspaceEdit
local apply = require("katana.apply")
report.check("validate_edit rechaza edición sin rango", select(1, apply.validate_edit({ changes = { ["file:///x"] = { { newText = "x" } } } })) == false)
report.check("validate_edit acepta vacío? no", select(1, apply.validate_edit({ changes = {} })) == false)

-- 3) collect_edits con documentChanges
local ws = require("katana.lsp.workspace")
local edit_dc = {
  documentChanges = {
    {
      textDocument = { uri = "file:///test.lua" },
      edits = {
        { range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 1 } }, newText = "x" },
      },
    },
  },
}
local groups = ws.collect_edits(edit_dc)
report.check("documentChanges recogido", #groups == 1, #groups)

-- 4) Conversión UTF-16 con astral
local s = "a\240\159\152\128b" -- a + 😀 + b
report.check("byte_to_char astral utf-16", ws.byte_to_char(s, 5, "utf-16") == 3)
report.check("char_to_byte astral utf-16", ws.char_to_byte(s, 3, "utf-16") == 5)

-- 5) apply_to_lines multi-línea
local res = ws.apply_to_lines({ "hello", "world" }, {
  { range = { start = { line = 0, character = 2 }, ["end"] = { line = 1, character = 2 } }, newText = "X\nY" },
}, "utf-8")
report.check("apply_to_lines multi-línea", table.concat(res, "|") == "heX|Yrld", table.concat(res, "|"))

-- 6) Deduplicación con payload de resolve
local resolve_same_1 = { title = "Same", kind = "quickfix", source = "lsp:a", data = { id = 1 }, resolve_fn = function() end }
local resolve_same_2 = { title = "Same", kind = "quickfix", source = "lsp:b", data = { id = 1 }, resolve_fn = function() end }
report.check("dedupe fusiona mismo data/resolve", #prio.filter_and_sort({ resolve_same_1, resolve_same_2 }) == 1)

local resolve_diff_1 = { title = "Same", kind = "quickfix", source = "lsp:a", data = { id = 1 }, resolve_fn = function() end }
local resolve_diff_2 = { title = "Same", kind = "quickfix", source = "lsp:b", data = { id = 2 }, resolve_fn = function() end }
report.check("dedupe conserva distinto data/resolve", #prio.filter_and_sort({ resolve_diff_1, resolve_diff_2 }) == 2)

-- 7) Generación de peticiones: las respuestas viejas no son actuales
local fetch = require("katana.core.fetch")
local old_token = fetch.new_generation()
local new_token = fetch.new_generation()
report.check("token viejo descartado", fetch.is_current(old_token) == false)
report.check("token nuevo actual", fetch.is_current(new_token) == true)
fetch.cancel()
report.check("cancel invalida el token actual", fetch.is_current(new_token) == false)

-- 8) Un timeout de codeAction no bloquea la recogida
--
-- Se sustituye `vim.lsp.get_clients` por un cliente simulado que nunca responde.
-- Así se ejercita el camino real de `request_lsp` (temporizador incluido) sin
-- necesitar un servidor LSP externo.
local config = require("katana.config")
local providers = require("katana.core.providers")
local register = require("katana.register")
providers.clear()
register.clear()

local slow_callback = nil
local slow_client = {
  name = "slow",
  id = 101,
  offset_encoding = "utf-16",
  supports_method = function(_, method)
    return method == "textDocument/codeAction"
  end,
  request = function(_, method, _, callback)
    if method == "textDocument/codeAction" then
      slow_callback = callback
    end
  end,
}

local original_get_clients = vim.lsp.get_clients
local original_notify = vim.notify
local notify_count = 0
vim.lsp.get_clients = function()
  return { slow_client }
end
vim.notify = function()
  notify_count = notify_count + 1
end

local old_range = config.options.code_action_range
local old_pull = config.options.pull_diagnostics
config.options.code_action_range = "cursor"
config.options.pull_diagnostics = false

-- Un proveedor que falla se acumula junto al timeout, sin impedir que `done`
-- llegue a ejecutarse.
providers.register(function()
  error("proveedor roto")
end, "bad")

local fetch_ctx = fetch.build_context(vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win(), {})
local fetch_done = false
local fetch_actions = nil
local fetch_errors = nil

fetch.get_all_actions(fetch_ctx, { request_timeout = 50 }, function(actions, errors)
  fetch_done = true
  fetch_actions = actions
  fetch_errors = errors
end)

vim.wait(1500, function()
  return fetch_done
end)

report.check("el timeout de codeAction no cuelga la recogida", fetch_done == true)
report.check("la recogida devuelve acciones", type(fetch_actions) == "table")
report.check("el timeout se registra como error", fetch_errors and #fetch_errors >= 1, fetch_errors and #fetch_errors)
report.check(
  "el error del proveedor también se registra",
  fetch_errors and #fetch_errors == 2,
  fetch_errors and #fetch_errors
)

local state = require("katana.state")
report.check(
  "los errores sobreviven para :KatanaDebug",
  state.last and state.last.fetch_errors and #state.last.fetch_errors == 2,
  state.last and state.last.fetch_errors and #state.last.fetch_errors
)

-- Una respuesta tardía del servidor se ignora: la petición ya terminó.
if slow_callback then
  pcall(slow_callback, nil, { { title = "late", kind = "quickfix", data = {} } })
end
report.check("respuesta tardía ignorada", type(fetch_actions) == "table" and #fetch_actions == 0, fetch_actions and #fetch_actions)

providers.clear()
config.options.code_action_range = old_range
config.options.pull_diagnostics = old_pull
vim.lsp.get_clients = original_get_clients
vim.notify = original_notify

-- 9) Filtro `hide_disabled` y tokens en `_on_actions`
local katana = require("katana")
local old_hide = config.options.hide_disabled
config.options.hide_disabled = true

notify_count = 0
vim.notify = function()
  notify_count = notify_count + 1
end

katana._on_actions({
  { title = "Disabled", source = "user:test", disabled = true },
}, { bufnr = vim.api.nvim_get_current_buf() })

report.check("acciones deshabilitadas no abren UI vacía", notify_count == 1, notify_count)
report.check("el picker sigue cerrado", state.open == false)

notify_count = 0
katana._on_actions({}, { bufnr = vim.api.nvim_get_current_buf() })
report.check("lista vacía avisa una sola vez", notify_count == 1, notify_count)

notify_count = 0
local stale_token = fetch.new_generation()
fetch.cancel()
katana._on_actions({
  { title = "Stale", source = "user:test" },
}, { bufnr = vim.api.nvim_get_current_buf() }, nil, stale_token)
report.check("respuesta de una generación vieja no avisa ni abre", notify_count == 0)

vim.notify = original_notify
config.options.hide_disabled = old_hide

report.finish()
