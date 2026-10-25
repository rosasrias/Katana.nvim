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
- `spec.run` (fun(action: KatanaAction)|nil) — nombre recomendado
- `spec.execute_fn` (fun(action: KatanaAction)|nil) — alias histórico
- `spec.edit` (WorkspaceEdit|nil)
- `spec.command` (table|string|nil)
- `spec.when` (fun(ctx: KatanaContext): boolean|nil)
- `spec.disabled` (boolean|table|nil)
- `opts.priority` (number|nil)

`run` y `execute_fn` se normalizan al mismo camino interno (`execute_fn`); si se
pasan los dos, gana `execute_fn`. Ambos reciben la acción normalizada. Un error
lanzado por el callback se convierte en `KatanaResult` con `status = "failed"`
(o `"partial"` si ya se aplicó una edición/comando).

## register_provider(fn, name, opts)
Registra un proveedor. Devuelve una lista de acciones; se normalizan en la
frontera de entrada y aceptan `run` o `execute_fn` (gana este último).
- `opts.priority` (number|nil)

## KatanaAction (contrato)
- `title` string
- `kind` string|nil
- `source` string|nil
- `edit` WorkspaceEdit|nil
- `command` table|string|nil
- `execute_fn` fun(action: KatanaAction)|nil
- `resolve_fn` fun(done: fun(action: KatanaAction, err: any|nil))|nil
- `diagnostics` table[]|nil
- `disabled` boolean|table|nil
- `client_id` number|nil
- `encoding` string|nil
- `variants` KatanaAction[]|nil
- `id` string|number|nil

Los campos opcionales que el servidor envía como `null` se normalizan a `nil`
(«ausente»). Un `isPreferred` nulo es `false`; `false` y `0` reales se conservan.

## Identidad y deduplicación

`dedupe` fusiona acciones sólo cuando coinciden `title`, `kind` **y** payload
(`edit`, `command`, `data`/`raw` de la resolución, `execute_fn`, `id`). Dos
servidores que devuelven el mismo título con ediciones distintas producen dos
filas: aplicar una no equivale a aplicar la otra.

## Ejecución y resultados

`require("katana.apply").execute(action, opts?)` encadena
`resolve_fn -> edit -> command -> execute_fn`.

- Devuelve un `KatanaResult` si termina de forma síncrona.
- Si necesita `codeAction/resolve`, puede devolver un `KatanaExecution` con
  `cancel(reason)`; el resultado final se entrega por `opts.on_result`.
- `opts`: `bufnr`, `win`, `timeout` (ms, por defecto 5000), `notify`
  (`false` desactiva notificaciones), `on_result(result)`, `client_id`.

Estados de `KatanaResult.status`:

| Estado | Significado |
| --- | --- |
| `success` | Todo se ejecutó. No notifica. |
| `failed` | Sin efecto persistente (o revertido). |
| `partial` | Algo se aplicó y un paso posterior falló; no se revierte automáticamente. |
| `cancelled` | Cancelada antes de aplicar. |
| `timed_out` | La resolución no llegó a tiempo; nada aplicado. |

Campos: `action`, `title`, `message`, `error`, `stage`, `reason`, `rollback`
(`not_needed`/`restored`/`failed`), `effects` (`edit`, `command`,
`execute_fn`, `buffers`), `duration_ms`, `notification_error`,
`callback_error`. La notificación centralizada usa INFO/WARN/ERROR según el
estado; un fallo al notificar o en `on_result` queda registrado en el resultado.

## Integridad del `WorkspaceEdit`

`workspace.prepare_edit(edit, bufnr, encoding)` valida todo antes de escribir y
devuelve un plan; `workspace.apply_plan(plan)` escribe y, si falla a mitad,
intenta revertir lo ya escrito de forma verificada.

- `documentChanges` tiene prioridad sobre `changes`; no se aplican ambos.
- Las entradas de la misma URI se fusionan en orden.
- Se rechazan URIs que no sean `file:`, ficheros inexistentes/ilegibles si no
  están abiertos, buffers con `buftype` no normal, rangos inválidos/fuera de
  límites/solapados y versiones de documento obsoletas.
- Se rechazan `createFile`/`renameFile`/`deleteFile`: no se modifica el sistema
  de ficheros.
- Un plan no se aplica dos veces (`plan.applied`).
- No hay transacción entre ficheros. El rollback es best-effort por buffer y
  sólo si su `changedtick` no cambió; se verifica con `undo` o restaurando el
  snapshot. Si no se puede verificar, el resultado es `partial` con
  `rollback = "failed"`.
- El undo agrupado es por buffer: un `u` por cada buffer modificado.
- Los campos opcionales que llegan como `null` JSON (`vim.NIL`) se interpretan
  como ausentes en la frontera de entrada (`core/optional.lua`): una
  `textDocument.version`, un `kind` de `documentChanges` o un `edit` nulo no
  invalidan la edición ni borran datos ya conocidos. `false` y `0` se conservan.

## UI

La interfaz se dibuja con [Volt](https://github.com/NvChad/volt). Hay dos
ventanas: la lista (con alto fijo) y el preview debajo. No hay ventana de
filtro. Opciones relevantes: `border`, `list_max_height`, `preview_split`
(`"horizontal"` = preview debajo), `preview_max_height`, `selection_color`
(fondo de la fila activa) y `selection_accent` (azul del texto de esa fila; no
hay barra de selección).

## Compatibilidad

Ver `TESTPLAN.md`. CI (`.github/workflows/ci.yml`) ejecuta las pruebas headless en
`stable` y `nightly`: `smoke`, `lsp_conformance`, `apply`, `ui`, `icons` y
`e2e`. `e2e` requiere `clangd` y se marca `SKIP` si no está disponible.
