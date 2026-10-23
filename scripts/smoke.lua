-- Prueba de humo del motor de Katana (no toca la UI).
--
--   nvim --headless -u NONE -l scripts/smoke.lua
--
-- Valida el contexto, los diagnósticos saneados, los proveedores, las acciones
-- registradas, la priorización/deduplicación, las conversiones byte<->char y la
-- aplicación de un WorkspaceEdit con undo agrupado.

local script = debug.getinfo(1, "S").source:sub(2)
local dir = vim.fn.fnamemodify(script, ":p:h")
local root = vim.fn.fnamemodify(dir, ":h")

vim.opt.rtp:append(root)

local env = dofile(dir .. "/env.lua")
local report = env.reporter()

report.header("Katana.nvim · smoke test")

local katana = require("katana")
katana.setup({ ts = { enabled = false }, resolve_on_open = false })

-------------------------------------------------------------------- contexto
local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local x = 1", "print(x)" })
vim.api.nvim_set_current_buf(bufnr)
vim.api.nvim_win_set_cursor(0, { 1, 0 })

local fetch = require("katana.core.fetch")
local ctx = fetch.build_context(bufnr, vim.api.nvim_get_current_win(), {})
report.check("ctx construido", ctx ~= nil and ctx.bufnr == bufnr)
report.check("ctx.uri", ctx.uri == vim.uri_from_bufnr(bufnr), ctx.uri)
report.check("ctx.range", ctx.range ~= nil and ctx.range.start ~= nil)
report.check("ctx.encoding", ctx.encoding == "utf-16", ctx.encoding)

------------------------------------------------------------- diagnósticos
vim.diagnostic.set(vim.api.nvim_create_namespace("katana_test"), bufnr, {
  { lnum = 0, col = 0, end_lnum = 0, end_col = 5, message = "boom", severity = vim.diagnostic.severity.ERROR, source = "lua_ls" },
})
local diags = fetch.collect_diagnostics(bufnr, ctx.range, "utf-16")
report.check("diagnósticos recogidos", #diags == 1, #diags)
report.check("diagnóstico saneado (sin lnum)", diags[1] and diags[1].lnum == nil and diags[1].message == "boom")
report.check("diagnóstico con range LSP", diags[1] and diags[1].range.start.line == 0 and diags[1].range.start.character == 0)

----------------------------------------------------------------- proveedores
katana.register_provider(function()
  return {
    { title = "Provider action", kind = "source", source = "mi-plugin" },
    { title = "Provider action 2", kind = "refactor.rewrite" },
  }
end, "mi")

local providers = require("katana.core.providers")
local pacts = providers.collect(ctx)
report.check("proveedor devuelve acciones", #pacts == 2, #pacts)
report.check("origen del proveedor", pacts[1].source == "provider:mi-plugin", pacts[1].source)

---------------------------------------------------------- acciones register
katana.register_action({ title = "Registered action", kind = "source", source = "reg" })
katana.register_action({
  title = "Conditional action",
  kind = "source",
  source = "cond",
  when = function()
    return false
  end,
})
local useracts = require("katana.register").get_actions(ctx)
report.check("acciones registradas (when respetado)", #useracts == 1, #useracts)
report.check("origen de acción registrada", useracts[1].source == "user:reg", useracts[1].source)

------------------------------------------------------------ priorización
local prio = require("katana.core.prioritize")
local actions = {
  { title = "Extract function", kind = "refactor.extract", source = "lsp:lua_ls" },
  { title = "Fix typo", kind = "quickfix", source = "lsp:lua_ls", diagnostics = { { range = { start = { line = 0 }, ["end"] = { line = 0 } } } } },
  { title = "Organize imports", kind = "source.organizeImports", source = "lsp:lua_ls" },
  { title = "Other", kind = nil, source = "ts" },
  { title = "Fix typo", kind = "quickfix", source = "lsp:other" },
}
local sorted = prio.filter_and_sort(vim.deepcopy(actions), ctx)
report.check("orden: quickfix con diagnóstico primero", sorted[1].title == "Fix typo", sorted[1].title)
report.check("dedupe fusiona orígenes", #sorted == 4, #sorted)
report.check("orígenes fusionados", sorted[1].sources and #sorted[1].sources == 2, vim.inspect(sorted[1].sources))
report.check("kind jerárquico", prio.kind_rank("refactor.extract.function", { "refactor.extract" }) == 0)
report.check("kind jerárquico (prefijo)", prio.kind_rank("refactor.extractX", { "refactor.extract" }) == 1)

------------------------------------------------------------ rango de la petición
-- El rango que se pide al servidor decide qué code actions aparecen: muchos
-- servidores (Roslyn) sólo ofrecen las suyas si el rango corta el token o el
-- diagnóstico, no si es el punto del cursor.
--
-- "Console.WriteLine(Suma(7, 5.2));"
--  offsets: C=0 ... e=6 .=7 W=8 ... (=17 S=18 u=19 m=20 a=21 (=22
local rbuf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(rbuf, 0, -1, false, { "Console.WriteLine(Suma(7, 5.2));", "   " })
vim.api.nvim_set_current_buf(rbuf)

vim.api.nvim_win_set_cursor(0, { 1, 19 })
local rctx = fetch.build_context(rbuf, vim.api.nvim_get_current_win(), {})

local s_start, s_stop = fetch.word_range(rbuf, 0, 19)
report.check("word_range: identificador bajo el cursor", s_start == 18 and s_stop == 22, vim.inspect({ s_start, s_stop }))
local w_start, w_stop = fetch.word_range(rbuf, 0, 3)
report.check("word_range: identificador a la izquierda", w_start == 0 and w_stop == 7, vim.inspect({ w_start, w_stop }))
local b_start, b_stop = fetch.word_range(rbuf, 0, 22)
report.check("word_range: identificador justo detrás del cursor", b_start == 18 and b_stop == 22, vim.inspect({ b_start, b_stop }))
local n_start, n_stop = fetch.word_range(rbuf, 1, 0)
report.check("word_range: sin identificador", n_start == nil and n_stop == nil, vim.inspect({ n_start, n_stop }))

-- Sin diagnósticos: el rango es el identificador bajo el cursor.
local auto_range = fetch.make_request_range(rctx, "utf-16", {})
report.check("rango auto = identificador", auto_range.start.character == 18 and auto_range["end"].character == 22, vim.inspect(auto_range))

-- Con un diagnóstico: el rango es el del diagnóstico (span exacto del token).
local diag_range = {
  start = { line = 0, character = 18 },
  ["end"] = { line = 0, character = 22 },
}
local diag_ctx = fetch.build_context(rbuf, vim.api.nvim_get_current_win(), {})
local with_diag = fetch.make_request_range(diag_ctx, "utf-16", { { range = diag_range } })
report.check("rango auto = diagnóstico", with_diag.start.character == 18 and with_diag["end"].character == 22, vim.inspect(with_diag))

-- Varios diagnósticos en la línea: se pide el rango que los cubre todos.
local union = fetch.union_range({
  { range = { start = { line = 0, character = 18 }, ["end"] = { line = 0, character = 22 } } },
  { range = { start = { line = 0, character = 26 }, ["end"] = { line = 0, character = 29 } } },
})
report.check("union_range cubre todos los diagnósticos", union.start.character == 18 and union["end"].character == 29, vim.inspect(union))

-- Los modos explícitos siguen respetando el rango pedido.
require("katana.config").options.code_action_range = "cursor"
local cursor_range = fetch.make_request_range(diag_ctx, "utf-16", { { range = diag_range } })
report.check("rango cursor = punto del cursor", cursor_range.start.character == cursor_range["end"].character, vim.inspect(cursor_range))

require("katana.config").options.code_action_range = "line"
local line_range = fetch.make_request_range(diag_ctx, "utf-16", { { range = diag_range } })
report.check("rango line = línea completa", line_range.start.character == 0 and line_range["end"].character == 32, vim.inspect(line_range))

require("katana.config").options.code_action_range = "auto"

-- En modo "auto" se piden varios rangos: el del diagnóstico (o el del
-- identificador) y el de la línea completa. El de la línea es la red de
-- seguridad que hace que Roslyn ofrezca "Generar método X" aunque el cursor
-- esté en otra palabra de la línea.
local auto_ranges = fetch.make_request_ranges(rctx, "utf-16", {})
report.check("auto: dos rangos (identificador + línea)", #auto_ranges == 2, #auto_ranges)
report.check(
  "auto: primer rango = identificador",
  auto_ranges[1].start.character == 18 and auto_ranges[1]["end"].character == 22,
  vim.inspect(auto_ranges[1])
)
report.check(
  "auto: segundo rango = línea completa",
  auto_ranges[2].start.character == 0 and auto_ranges[2]["end"].character == 32,
  vim.inspect(auto_ranges[2])
)

local diag_ranges = fetch.make_request_ranges(diag_ctx, "utf-16", { { range = diag_range } })
report.check("auto con diagnóstico: dos rangos", #diag_ranges == 2, #diag_ranges)
report.check(
  "auto con diagnóstico: primer rango = token",
  diag_ranges[1].start.character == 18 and diag_ranges[1]["end"].character == 22,
  vim.inspect(diag_ranges[1])
)

-- `ranges_equal` y `diagnostics_on_row`.
report.check("ranges_equal (iguales)", fetch.ranges_equal(diag_range, { start = { line = 0, character = 18 }, ["end"] = { line = 0, character = 22 } }))
report.check("ranges_equal (distintos)", not fetch.ranges_equal(diag_range, { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 1 } }))

local on_row = fetch.diagnostics_on_row({
  { range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 5 } } },
  { range = { start = { line = 1, character = 0 }, ["end"] = { line = 1, character = 5 } } },
}, 1)
report.check("diagnostics_on_row filtra por fila", #on_row == 1 and on_row[1].range.start.line == 1, #on_row)

-- El rango visual usa la selección actual (las marcas '< y '> están
-- desactualizadas mientras se está en modo visual).
vim.api.nvim_win_set_cursor(0, { 1, 18 })
vim.cmd("normal! v4l")
local visual = fetch.visual_range(rbuf, vim.api.nvim_get_current_win(), "utf-16")
report.check("rango visual: inicio", visual ~= nil and visual.start.character == 18, vim.inspect(visual))
report.check("rango visual: fin exclusivo", visual ~= nil and visual["end"].character == 23, vim.inspect(visual))

------------------------------------------------------------------ executor
local tmp = vim.fn.tempname() .. ".lua"vim.fn.writefile({ "local a = 1", "local b = 2" }, tmp)
vim.cmd("edit " .. vim.fn.fnameescape(tmp))
local ebuf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(ebuf, 0, -1, false, { "uno", "dos", "tres" })

local workspace = require("katana.lsp.workspace")
-- "a" + emoji (4 bytes, 2 unidades utf-16) + "b" = 6 bytes.
-- Índices de byte 0-based: a=0, emoji=1..4, b=5.
local emoji = "a\240\159\152\128b"
report.check("byte_to_char (inicio)", workspace.byte_to_char(emoji, 0, "utf-16") == 0)
report.check("byte_to_char (ascii)", workspace.byte_to_char(emoji, 1, "utf-16") == 1)
report.check("byte_to_char (dentro de un astral)", workspace.byte_to_char(emoji, 2, "utf-16") == 3)
report.check("byte_to_char (astral)", workspace.byte_to_char(emoji, 5, "utf-16") == 3)
report.check("byte_to_char (utf-8 = bytes)", workspace.byte_to_char(emoji, 2, "utf-8") == 2)
report.check("char_to_byte ida y vuelta", workspace.char_to_byte(emoji, 3, "utf-16") == 5)
report.check("char_to_byte (inicio del astral)", workspace.char_to_byte(emoji, 1, "utf-16") == 1)

-- Preview: `apply_to_lines` debe reemplazar sólo el tramo del `TextEdit`, no la
-- línea completa. Es el caso de clangd insertando un `;` al final de la línea.
local insert_eol = workspace.apply_to_lines(
  { "  int x = 1", "  return 0" },
  {
    {
      range = {
        start = { line = 0, character = 11 },
        ["end"] = { line = 0, character = 11 },
      },
      newText = ";",
    },
  },
  "utf-16"
)
report.check(
  "preview: inserción al final de línea conserva el texto",
  insert_eol[1] == "  int x = 1;" and insert_eol[2] == "  return 0",
  vim.inspect(insert_eol)
)

local replace_inline = workspace.apply_to_lines(
  { "  int x = 1" },
  {
    {
      range = {
        start = { line = 0, character = 2 },
        ["end"] = { line = 0, character = 5 },
      },
      newText = "long",
    },
  },
  "utf-16"
)
report.check(
  "preview: sustitución intra-línea conserva prefijo y sufijo",
  replace_inline[1] == "  long x = 1",
  vim.inspect(replace_inline)
)

local multiline = workspace.apply_to_lines(
  { "line1", "line2", "line3" },
  {
    {
      range = {
        start = { line = 0, character = 2 },
        ["end"] = { line = 1, character = 2 },
      },
      newText = "X\nY",
    },
  },
  "utf-8"
)
report.check(
  "preview: edición multi-línea conserva los extremos",
  table.concat(multiline, "|") == "liX|Yne2|line3",
  vim.inspect(multiline)
)

local multi_edits = workspace.apply_to_lines(
  { "a", "b" },
  {
    {
      range = {
        start = { line = 1, character = 1 },
        ["end"] = { line = 1, character = 1 },
      },
      newText = "!",
    },
    {
      range = {
        start = { line = 0, character = 1 },
        ["end"] = { line = 0, character = 1 },
      },
      newText = "?",
    },
  },
  "utf-8"
)
report.check(
  "preview: varias ediciones se aplican de abajo arriba",
  table.concat(multi_edits, "|") == "a?|b!",
  vim.inspect(multi_edits)
)

-- Las cabeceras usan el label del grupo (no el del primer subkind que aparezca).
local groups = require("katana.core.group").build({
  { title = "Fix all", kind = "source.fixAll.eslint", source = "lsp:eslint" },
})
report.check(
  "cabecera de subkind usa el label del grupo",
  groups[1] and groups[1].label == "Source: Fix All",
  groups[1] and groups[1].label
)

local action = {
  title = "Replace",
  kind = "quickfix",
  source = "lsp:test",
  encoding = "utf-16",
  edit = {
    changes = {
      [vim.uri_from_fname(tmp)] = {
        {
          range = {
            start = { line = 0, character = 0 },
            ["end"] = { line = 0, character = 3 },
          },
          newText = "UNO",
        },
      },
    },
  },
}
require("katana.apply").execute(action, { bufnr = ebuf, win = vim.api.nvim_get_current_win() })
local lines = vim.api.nvim_buf_get_lines(ebuf, 0, -1, false)
report.check("edit aplicado", lines[1] == "UNO dos" or lines[1] == "UNO", vim.inspect(lines))

vim.cmd("undo")
local undone = vim.api.nvim_buf_get_lines(ebuf, 0, -1, false)
report.check("un solo `u` revierte la acción", undone[1] == "uno", vim.inspect(undone))

report.finish()
