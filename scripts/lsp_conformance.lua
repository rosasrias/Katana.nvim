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

report.finish()
