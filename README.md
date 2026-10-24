# Katana.nvim

Picker de *code actions* para Neovim (>= 0.10) que reúne, en un único menú:

- Las acciones de **todos los clientes LSP** conectados al buffer (`textDocument/codeAction`).
- Un proveedor propio basado en **Tree-sitter** (nodo bajo el cursor).
- **Proveedores** y **acciones** registradas por el usuario.

A diferencia de un picker plano, Katana mantiene su **UI agrupada por kind**
(cabeceras de grupo, iconos, atajos numéricos `1`-`9`) y le añade la
**previsualización reactiva del diff** de la acción seleccionada, debajo de la
lista y con alto limitado.

La interfaz está construida sobre [Volt](https://github.com/NvChad/volt) (el motor
de UI del ecosistema NvChad): no se usa Telescope, snacks ni fzf-lua.

```
┌──────────────────────────────────────────────────────────────────────┐
│  󰁨  Quick Fix ─────────────────────────────────────────────────────   │
│▎1. 󰁨 insert ';'                                         lsp:clangd   │
│                                                                      │
│  󰛹  Refactor: Extract ─────────────────────────────────────────────   │
│ 2. 󰛹 Extract function                                    lsp:clangd   │
│ 3. 󰛹 Extract variable                                    lsp:clangd   │
├──────────────────────────────────────────────────────────────────────┤
│  --- a/main.c                         ← preview (alto máx. + scroll) │
│  +++ b/main.c                                                        │
│  @@ -1,4 +1,4 @@                                                     │
│   int main(void) {                                                   │
│  -  int x = 1                                                        │
│  +  int x = 1;                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

### Aspecto

- Cada **kind tiene su propio icono y su propio color** (no solo la familia). Con
  `mini.icons` se usan sus glifos `nf-md-*` con los grupos `MiniIcons*` del tema;
  si no está disponible se usan los iconos de `config.options.icons` con los
  grupos `Katana*`. El icono conserva ese color **también en la fila seleccionada**. Los
  grupos `MiniIcons*` se replican en el namespace del picker con sus variantes
  `*Sel` para mantener el color sobre la fila activa.
- La fila activa se marca con **fondo propio + barra izquierda `▎`**, de modo que
  se distingue aunque el tema no tenga un color de selección contrastado. El
  fondo se calcula a partir del tema y, si queda demasiado cerca del fondo de la
  flotante, se separa automáticamente; se puede fijar con `selection_color` y
  `selection_accent`.
- Las **cabeceras de grupo** van en azul con una regla horizontal que rellena el
  ancho de la lista.


---

## Instalación

Con [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "rosasrias/Katana.nvim",
  dependencies = {
    "NvChad/volt",          -- obligatorio: motor de la UI
    "nvim-mini/mini.icons", -- opcional: iconos nf-md
  },
  opts = {
    keymap = "<leader>ca",
  },
  config = function(_, opts)
    require("katana").setup(opts)
  end,
}
```

Volt es una dependencia **obligatoria**: Katana lo requiere al cargar la UI
(`lua/katana/ui/window.lua` y `lua/katana/ui/list.lua`). Sin él, el picker falla
con `module 'volt' not found`. `mini.icons` es opcional; si no está, se usan los
iconos de `config.options.icons`.

Si lo tienes en local (`dir = "..."`), cambia la primera entrada por la ruta.

> **Nota sobre `<leader>ca`**: el atajo se define en `katana.setup()`, que se
> ejecuta al cargar el plugin. Katana **no pisa** tus mappings: comprueba
> (`vim.fn.maparg(lhs, "n")`, que expande `<leader>`) si ya existe uno para el
> mismo `lhs` antes de crear el suyo. Si ya tienes `<leader>ca` definido,
> Katana lo respeta y no crea nada.

---

## Uso

| Acción | Resultado |
| --- | --- |
| `:CodeActions` | Abre el picker con el rango del cursor |
| `:CodeActions line` | Abre el picker usando la línea completa como rango |
| `:CodeActions visual` | Abre el picker usando la selección como rango |
| `:KatanaSource` | Abre el picker con sólo las acciones de tipo `source` |
| `:KatanaDebug` | Muestra un informe de la petición (clientes, diagnósticos, rangos, acciones, estado del picker) |
| `<leader>ca` | Igual que `:CodeActions` (en modo normal y visual) |
| `<leader>ca` (modo visual) | Usa la selección como rango |

Dentro del picker (la **lista** tiene el foco al abrir, en modo normal):

| Tecla | Acción |
| --- | --- |
| `j` / `k` / `<Down>` / `<Up>` | Navegar por las acciones |
| `<C-n>` / `<C-p>` | Siguiente / anterior (se mantienen por compatibilidad) |
| `]` / `[` | Saltar al grupo siguiente / anterior |
| `<C-d>` / `<C-u>` | Desplazar el preview (3 líneas abajo / arriba) |
| `<CR>` / `<Space>` | Ejecutar la acción seleccionada |
| `1` … `9` | Ejecutar directamente la acción *n* |
| `q` / `<Esc>` / `<C-c>` | Cerrar |

No hay ventana de filtro: la lista muestra siempre todas las acciones.

El preview aparece **debajo** de la lista (`preview_split = "horizontal"`) y su
alto está limitado por `preview_max_height`: si el diff no cabe, la ventana no
crece y el contenido se desplaza dentro de ella con `<C-d>`/`<C-u>`, la rueda
del ratón o `j`/`k` con el foco en el preview. Se recalcula de forma reactiva al
mover la selección y vuelve al principio en cada cambio.

La lista tiene un alto fijo (`list_max_height`, 20 filas): no crece con el
número de acciones; si hay más, se recorre con `j`/`k`.

---

## Configuración

```lua
require("katana").setup({
  -- Atajo para abrir el picker. "" desactiva el atajo.
  keymap = "<leader>ca",

  preview = true,              -- panel de previsualización del diff
  preview_split = "horizontal",-- "horizontal" (debajo) | "vertical" (derecha)
  preview_max_height = 12,     -- alto máximo del preview; si el diff es más
                               -- largo, se desplaza dentro de la ventana
  width = 0.85,                -- fracción del ancho del editor
  height = 0.85,               -- fracción máxima del alto del editor
  list_max_height = 20,        -- alto fijo de la lista (filas)
  border = "rounded",          -- estilo de borde de las flotantes

  -- Aspecto de la fila seleccionada. Por defecto se derivan del tema; fíjalos si
  -- el tema no distingue lo suficiente (mira `selection_color` en `:KatanaDebug`).
  selection_color = nil,       -- fondo de la fila activa, p. ej. "#3a4252"
  selection_accent = nil,      -- barra izquierda de la fila activa, p. ej. "#61afef"

  show_server_name = true,     -- muestra el origen de la acción
  show_preferred = true,       -- marca las acciones `isPreferred`
  num_shortcuts = true,        -- muestra los atajos numéricos 1-9
  auto_preview = true,         -- actualiza el preview al mover la selección
  group_by_kind = true,        -- agrupa las acciones por kind
  hide_disabled = false,       -- oculta las acciones deshabilitadas

  -- Orden de los grupos en la lista.
  group_order = {
    "quickfix",
    "refactor.extract",
    "refactor.inline",
    "refactor.rewrite",
    "refactor.convert",
    "refactor",
    "source.organizeImports",
    "source.fixAll",
    "source",
    "command",
    "other",
  },

  -- Prioridad de los kinds (índice 0 = máxima). Los kinds no listados quedan al
  -- final. Un kind coincide también con sus sub-kinds: "refactor.extract"
  -- cubre "refactor.extract.function".
  kinds_priority = {
    "quickfix",
    "refactor.extract",
    "refactor.inline",
    "refactor.rewrite",
    "refactor.convert",
    "source.organizeImports",
    "source.fixAll",
    "source",
    "refactor",
    "command",
    "other",
  },
  -- Fusiona sólo acciones con el mismo título, kind **y** payload (edit/command):
  -- dos servidores con el mismo título y ediciones distintas son filas
  -- separadas, porque aplicar una no equivale a aplicar la otra.
  dedupe = true,

  -- Peso por kind y por cliente LSP (desempates dentro de la misma prioridad).
  kind_weights = { quickfix = 25, ["refactor.extract"] = 20 },
  lsp_weights = { lua_ls = 15, clangd = 15 },

  ts = {
    enabled = true,            -- proveedor basado en Tree-sitter
  },

  diff_backend = "vim",        -- "vim" | "delta" | "difftastic"

  resolve_on_open = true,      -- resuelve las acciones al abrir (codeAction/resolve)
  resolve_limit = 20,          -- máximo de acciones resueltas al abrir

  -- Rango que se pide al servidor en `textDocument/codeAction`:
  --   "auto"   -> el rango real de los diagnósticos de la línea del cursor, el
  --                identificador bajo el cursor y la línea completa (se piden
  --                todos y se fusionan las respuestas).
  --   "cursor" -> sólo el punto del cursor (más restrictivo).
  --   "line"   -> la línea completa.
  code_action_range = "auto",

  -- Si el buffer no tiene diagnósticos, se le piden al servidor (pull
  -- diagnostics). Es lo que hace que "Generar método X" aparezca desde el
  -- primer momento con Roslyn, sin esperar a que el proyecto cargue.
  pull_diagnostics = true,
  pull_timeout = 2000,          -- ms de espera de esa petición

  icons = {                    -- iconos por kind (Nerd Font)
    quickfix = "󰃨",
    refactor = "󰛥",
    source = "󰃬",
    command = "󰅉",
    other = "•",
    preferred = "★",
  },
})
```

### Criterios de ordenación

Las acciones se ordenan por una puntuación combinada:

1. **Kind** (peso dominante) según `kinds_priority`.
2. **Diagnóstico bajo el cursor**: las acciones relacionadas con un diagnóstico
   que solapa el cursor suben dentro de su mismo kind.
3. **Origen**: `lsp` > `ts` > `user` > `provider`.

A igualdad se desempata con `kind_weights`, `lsp_weights` y, en último caso, de
forma alfabética.

Con `dedupe = true`, las acciones con el mismo `title` + `kind` se fusionan en una
sola entrada que acumula todos sus orígenes (se muestran separados por comas).

---

## API

### `require("katana").setup(opts?)`

Configura el plugin (opciones, comandos y atajo).

### `require("katana").open(opts?)`

Recoge todas las acciones y abre el picker.

```lua
require("katana").open({
  bufnr = nil,            -- buffer (por defecto, el actual)
  win = nil,              -- ventana (por defecto, la actual)
  scope = "cursor",       -- "cursor" | "line" | "visual"
  only = nil,             -- string[] de kinds LSP a pedir
})
```

En modo visual, `scope` se detecta automáticamente (`"visual"`).

### `require("katana").code_action()`

Alias de `open()`.

### `require("katana").source_action()`

Abre el picker pidiendo sólo las acciones de tipo `source`
(`context.only = { "source" }`).

### `require("katana").register_action(spec)`

Registra una acción propia en el mismo menú:

```lua
require("katana").register_action({
  title = "Convertir a snake_case",
  kind = "refactor.rewrite",   -- opcional
  source = "mi-plugin",        -- opcional
  when = function(ctx)         -- opcional
    return ctx.filetype == "lua"
  end,
  run = function(action)
    -- hacer lo que haga falta
  end,
})
```

### `require("katana").register_provider(fn, name?)`

Registra un proveedor de acciones. Recibe el contexto de la petición y devuelve
una lista de acciones:

```lua
require("katana").register_provider(function(ctx)
  return {
    {
      title = "Mi acción",
      kind = "source",
      source = "mi-plugin",
      execute_fn = function(action) end,
    },
  }
end, "mi-plugin")
```

### `require("katana").close()`

Cierra el picker si está abierto.

### Forma normalizada de una acción

Todas las fuentes producen el mismo tipo (`KatanaAction`):

| Campo | Tipo | Descripción |
| --- | --- | --- |
| `title` | `string` | Título legible |
| `kind` | `string?` | Kind LSP (`quickfix`, `refactor.extract`, ...) |
| `source` | `string` | Origen: `lsp:clangd`, `ts`, `user:mi-plugin`, `provider:x` |
| `raw` | `any` | Payload original |
| `resolve_fn` | `fun(cb)`? | Resolución diferida (`codeAction/resolve`) |
| `execute_fn` | `fun(action)`? | Ejecución propia |
| `edit` | `vim.lsp.WorkspaceEdit?` | Cambios a aplicar |
| `command` | `lsp.Command?` | Comando LSP a ejecutar |
| `diagnostics` | `lsp.Diagnostic[]?` | Diagnósticos relacionados |
| `sources` | `string[]?` | Orígenes fusionados (tras deduplicar) |

---

## Ciclo de vida de una acción

El ejecutor (`katana.apply`) encadena siempre los mismos pasos:

1. **resolve** - si la acción trae `resolve_fn` y no trae `edit`/`command`, se
   espera la resolución (`codeAction/resolve`), con un timeout de 5 s por defecto.
2. **edit** - se aplica el `WorkspaceEdit` (respetando la codificación de
   posiciones del cliente: `utf-8`, `utf-16` o `utf-32`).
3. **command** - se ejecuta el comando LSP mediante `client:exec_cmd`.
4. **execute_fn** - se ejecuta la lógica propia de la acción.

Cualquier error se notifica con `vim.notify(..., vim.log.levels.ERROR)`.

### Undo agrupado

Antes de aplicar los cambios se cierra el bloque de undo previo del buffer
(reasignando `undolevels`, que es la forma documentada en `:help undo-break`).
Consecuencia: **un único `u` deshace la acción completa** y no arrastra la
edición previa del usuario.

---

## Proveedor de Tree-sitter

Con `ts.enabled = true` se añaden acciones sobre el nodo bajo el cursor:

- **Copy node text** - copia el texto del nodo al registro sin nombre.
- **Select node** - selecciona visualmente el nodo.
- **Comment node** - comenta el nodo usando el `commentstring` del buffer.

El proveedor usa `vim.treesitter.get_node` (Neovim 0.12) con respaldo a
`vim.treesitter.get_node_at_pos` (0.10/0.11).

---

## Notas de implementación y limitaciones

### Volt

- El buffer de la lista contiene **todas** las filas (para poder desplazarse) y
  la ventana muestra como mucho `max_rows` (el alto fijo `list_max_height`): en
  cada render se limpia el namespace (`nvim_buf_clear_namespace`) y se
  redimensionan las líneas en blanco antes de redibujar.
- El texto de cada fila es `virt_text` (los *marks* de Volt). `volt.draw`
  **elimina el tercer elemento** de cada mark (donde vive la acción del click),
  por lo que las tablas de marks se reconstruyen en cada render.
- `volt.events.add` se registra **antes** de los keymaps propios: así `<CR>`,
  `<Space>`, `j`/`k` y los atajos numéricos tienen prioridad sobre los de Volt.
- `volt.events.enable()` instala un handler global de `vim.on_key` (para el
  soporte de ratón). Es un efecto secundario de Volt que ya afecta a otros
  plugins del ecosistema (menu, minty).

### LSP

- Los diagnósticos que se envían al servidor se **sanean**: sólo se copian
  `range`, `severity`, `message`, `source` y `code`. Mandar el diagnóstico de
  Neovim tal cual (con `lnum`, `col`, `user_data`, ...) hace fallar a los
  servidores con deserialización estricta (por ejemplo `csharp_ls` responde
  `Internal error: JsonSerializationException`).
- El contexto de la petición incluye siempre `diagnostics` y `triggerKind`
  (`Invoked`), como hace `vim.lsp.buf.code_action()`. `only` sólo se envía si se
  pide explícitamente.
- El filtro de diagnósticos es **por línea**: basta con tener el cursor en la
  línea del error para que su quickfix esté disponible. Es más generoso que
  `vim.lsp.buf.code_action()`, que exige que el cursor caiga dentro del rango
  exacto del diagnóstico (y por eso con `clangd` hay que colocarse sobre la
  línea donde el servidor reporta el error, que no siempre coincide con la
  línea del código que lo provoca).
- La conversión de posiciones (byte ↔ unidad de codificación) está implementada
  a mano en `katana.lsp.workspace`: `vim.str_byteindex` cambió de firma entre
  0.10 (`s, index, use_utf16`) y 0.11/0.12 (`s, encoding, index, strict`), y la
  versión propia funciona igual en todo el rango soportado.
- `lua_ls` no ofrece *code actions* para la mayoría del código Lua (devuelve
  `null`), así que para validar el flujo LSP real conviene usar `clangd` u otro
  servidor que proponga correcciones.

### El rango de la petición

El rango que se manda en `textDocument/codeAction` decide **qué acciones
ofrece el servidor**. La mayoría de los servidores enlaza sus *code actions* a
un diagnóstico o a un token concreto, así que un rango de ancho cero en el
cursor sólo acierta cuando el cursor cae exactamente sobre ese token.

Con `code_action_range = "auto"` (por defecto) Katana pide **varios rangos** y
fusiona las respuestas:

1. **El rango real de los diagnósticos de la línea del cursor.** Es el rango que
   el servidor usa para decidir qué *code action* encaja con qué error.
2. **Si no hay diagnósticos, el identificador bajo el cursor** (la palabra que
   lo rodea, o la que está justo detrás si el cursor está al final).
3. **Si tampoco hay identificador, el punto del cursor.**
4. **Siempre la línea completa.** Es la red de seguridad: aunque el cursor esté
   en otra palabra de la línea, el rango de la línea corta el token con error y
   el servidor ofrece su *quickfix*.

Además, si el buffer **no tiene diagnósticos** (típico con los servidores que
usan *pull diagnostics*, como Roslyn, mientras el proyecto se está cargando),
Katana se los pide al servidor (`textDocument/diagnostic`) antes de calcular el
rango. Se puede desactivar con `pull_diagnostics = false`.

Ejemplo real (C# con `roslyn_ls`):

```csharp
Console.WriteLine(Suma(7, 5.2));   // CS0103: 'Suma' no existe
```

| `code_action_range` | Acciones ofrecidas | ¿Aparece "Generar método Suma"? |
| ------------------- | ------------------ | --------------------------------- |
| `"cursor"` (antiguo) | 8                  | ❌ sólo si el cursor está en `Suma` |
| `"auto"` (nuevo)     | 15                 | ✅ siempre que el cursor esté en la línea |

Los modos `"cursor"` y `"line"` se conservan para forzar el comportamiento
antiguo (o el contrario) desde la configuración.

### Modo visual

Las marcas `'<` y `'>` de Vim sólo se actualizan **al salir** del modo visual,
así que `vim.lsp.util.make_given_range_params()` devuelve la selección
*anterior* (o un rango vacío si nunca se ha hecho ninguna). Katana fuerza la
salida del modo visual para leer la selección **actual** y devuelve el cursor a
su sitio, de forma que las acciones pedidas corresponden a lo que has
seleccionado.

### Diagnóstico: `:KatanaDebug`

Si el picker no muestra lo que esperas, `:KatanaDebug` imprime un informe con
todo lo que determina el resultado de la petición:

- los clientes LSP conectados al buffer (y si soportan `codeAction` y
  `diagnostic`),
- los diagnósticos del buffer y los de la línea del cursor,
- los rangos exactos que se piden al servidor,
- las acciones que se han recibido,
- la **fase del picker**: qué acciones llegaron a la lista, cuántas filas se
  pintaron y el error si algo falló al abrirlo.

Es el primer sitio donde mirar cuando un servidor "no ofrece" nada.

El picker se abre una vez recibida la respuesta del servidor; mientras tanto no
se muestra la UI. `No matching actions` significa que el servidor no devolvió
acciones (o todas eran `disabled`): la lista no filtra, así que no puede ser un
problema de texto.

Si abrir el picker falla, Katana ya **no** se queda en silencio mostrando
`No matching actions`: avisa con un error y guarda el mensaje, que también
aparece en la sección `picker` del informe.

### Diff

- El backend por defecto (`"vim"`) usa `vim.diff`, que devuelve el diff unificado
  **sin** las cabeceras `--- a/fichero` / `+++ b/fichero`: se añaden a mano para
  que `filetype=diff` las coloree.
- Los backends `"delta"` y `"difftastic"` ejecutan la herramienta externa sobre
  ficheros temporales. Si la herramienta no está instalada, se cae de forma
  automática al diff interno. La invocación exacta (`--color=never`,
  `--output=short`) puede necesitar ajustes según la versión instalada.
  - `TODO:` parametrizar los argumentos de las herramientas externas por
    configuración en lugar de fijarlos en el código.

---

## Estructura

```
lua/katana/
├── init.lua              -- API pública: setup, open, register_*
├── config.lua            -- opciones por defecto y merge
├── plugin.lua            -- comandos (:CodeActions, :KatanaSource, :KatanaDebug) y atajo
├── state.lua             -- estado del picker abierto (buffers, ventanas, filas)
├── register.lua          -- acciones registradas por el usuario
├── apply.lua             -- resolve -> edit -> command -> execute_fn
├── utils.lua             -- labels, grupos por kind y títulos compactos
├── core/
│   ├── fetch.lua         -- recogida de acciones (LSP, proveedores, TS, registradas)
│   ├── prioritize.lua    -- priorización, ordenación y deduplicación
│   ├── group.lua         -- agrupación por kind (cabeceras y orden de grupos)
│   ├── resolve.lua       -- codeAction/resolve por lotes
│   ├── providers.lua     -- registro de proveedores
│   ├── debug.lua         -- informe de diagnóstico (:KatanaDebug)
│   └── treesitter.lua    -- proveedor basado en Tree-sitter
├── lsp/
│   └── workspace.lua     -- WorkspaceEdit, codificaciones, undo y diffs
├── ui/
│   ├── window.lua        -- ciclo de vida de las ventanas del picker
│   ├── layout.lua        -- geometría (lista y preview)
│   ├── list.lua          -- render de la lista con Volt
│   ├── mappings.lua      -- keymaps de la lista
│   └── highlights.lua    -- highlights (KatanaSelected, KatanaHeader, MiniIcons*, ...)
└── preview/
    └── diff.lua          -- previsualización reactiva del diff

plugin/katana.lua         -- carga los comandos de usuario
scripts/                  -- pruebas headless (smoke, conformance, ui, icons, e2e)
```

---

## Desarrollo

Pruebas headless (no necesitan interfaz):

```bash
nvim --headless -u NONE -l scripts/smoke.lua           # motor (49 comprobaciones)
nvim --headless -u NONE -l scripts/lsp_conformance.lua # conformidad LSP (11 comprobaciones)
nvim --headless -u NONE -l scripts/ui.lua              # UI sobre Volt (42 comprobaciones)
nvim --headless -u NONE -l scripts/icons.lua           # iconos y colores (8 comprobaciones)
nvim --headless -u NONE -l scripts/e2e.lua             # LSP real con clangd (12 comprobaciones)
```

`scripts/ui.lua` y `scripts/e2e.lua` necesitan el plugin **Volt** (se busca en el
`runtimepath` y en las rutas habituales de lazy.nvim; se puede forzar con
`KATANA_VOLT=/ruta`). `scripts/e2e.lua` necesita **clangd** (`KATANA_CLANGD`).
Si falta alguno, el script lo marca como `SKIP` y termina sin errores.

El plan de pruebas manual está en [TESTPLAN.md](./TESTPLAN.md).

---

## Licencia

MIT
