# Katana.nvim API

## setup(opts)
Configura el plugin.

## open(opts)
Abre el picker. `opts.scope`: `"cursor"`, `"line"`, `"visual"`. `opts.bufnr`, `opts.win`, `opts.only`.

## register_action(spec, opts)
Registra una acción propia.
- `spec.title` (string, requerido)
- `spec.kind` (string|nil)
- `spec.source` (string|nil)
- `spec.run` (fun()|nil)
- `spec.execute_fn` (fun(action: KatanaAction)|nil)
- `spec.edit` (WorkspaceEdit|nil)
- `spec.command` (table|string|nil)
- `spec.when` (fun(ctx: KatanaContext): boolean|nil)
- `spec.disabled` (boolean|table|nil)
- `opts.priority` (number|nil)

## register_provider(fn, name, opts)
Registra un proveedor. Debe devolver lista de `KatanaAction` normalizadas.
- `opts.priority` (number|nil)

## KatanaAction (contrato)
- `title` string
- `kind` string|nil
- `source` string|nil
- `edit` WorkspaceEdit|nil
- `command` table|string|nil
- `execute_fn` fun(action: KatanaAction)|nil
- `resolve_fn` fun(done: fun(action: KatanaAction))|nil
- `diagnostics` table[]|nil
- `disabled` boolean|table|nil
- `client_id` number|nil
- `encoding` string|nil
- `variants` KatanaAction[]|nil
- `id` string|number|nil

## Identidad y deduplicación

`dedupe` fusiona acciones sólo cuando coinciden `title`, `kind` **y** payload
(`edit`, `command`, `resolve_fn`, `execute_fn`, `id`). Dos servidores que
devuelven el mismo título con ediciones distintas producen dos filas: aplicar
una no equivale a aplicar la otra.

## UI

La interfaz se dibuja con [Volt](https://github.com/NvChad/volt). Opciones
relevantes: `border`, `preview_split` (`"horizontal"` = preview debajo),
`preview_max_height`, `selection_color`, `selection_accent`.

## Compatibilidad

Ver `TESTPLAN.md`. CI (`.github/workflows/ci.yml`) ejecuta las pruebas headless en
`stable` y `nightly`: `smoke`, `lsp_conformance`, `ui`, `icons` y `e2e`. `e2e`
requiere `clangd` y se marca `SKIP` si no está disponible.
