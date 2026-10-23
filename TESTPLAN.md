# Plan de pruebas manuales · Katana.nvim

Plan de verificación sobre una instalación real (Neovim 0.12.5 + NvChad +
`lua_ls` / `clangd`). Cada bloque indica el **paso**, el **resultado esperado** y
cómo **diagnosticar** un fallo.

---

## 0. Preparación

El plugin ya está registrado en la configuración de lazy.nvim
(`C:\Users\rosas\AppData\Local\nvim\lua\plugins\katana.lua`):

```lua
{
  dir = "C:/Users/rosas/Documents/code/plugins/Katana.nvim",
  name = "katana.nvim",
  dependencies = { "NvChad/volt" },
  config = function()
    require("katana").setup({})
  end,
}
```

> **Choque de mapping**: si tu spec ya define `<leader>ca` (o `<leader>cA`),
> Katana **no** lo pisa: `require("katana").setup()` comprueba `maparg` antes de
> crear el suyo.

Comprobación previa (sin GUI):

```bash
cd C:/Users/rosas/Documents/code/plugins/Katana.nvim
nvim --headless -u NONE -l scripts/smoke.lua
nvim --headless -u NONE -l scripts/ui.lua
nvim --headless -u NONE -l scripts/e2e.lua
```

Salida esperada: todas las líneas `OK` y el resumen `0 fallos` (49 + 46 + 12
comprobaciones). Si `Volt` o `clangd` no están disponibles, los scripts lo
indican con `SKIP` y terminan sin errores.

---

## 1. Carga del plugin

| Paso | Resultado esperado |
| --- | --- |
| `:lua =require("katana").setup({})` | No error; devuelve la tabla de opciones |
| `:lua print(vim.inspect(vim.api.nvim_get_commands({builtin=false}).CodeActions))` | El comando existe |
| `:lua print(vim.inspect(vim.api.nvim_get_commands({builtin=false}).KatanaSource))` | El comando existe |
| `:messages` tras arrancar | Sin errores ni `E5108` |

Diagnóstico: si `require("katana")` falla, el `dir` de la spec lazy no apunta a
la carpeta correcta o falta `lua/katana/init.lua`.

---

## 2. LSP real (escenario principal)

### 2.1 Provocar un diagnóstico

Crear `demo.lua`:

```lua
local function greet(name)
  local unused = 42
  return "hola " .. name
end

print(greet("mundo"))
```

- `unused` no se usa → diagnóstico *unused variable* de `lua_ls`.
- Verificar con `:lua vim.diagnostic.get(0)` que hay diagnósticos y que
  `vim.diagnostic.get(0)[1].source` es `"lua_ls"`.

> **Aviso**: `lua_ls` **no ofrece code actions** para la mayoría del código Lua
> (responde `null` a `textDocument/codeAction`). Por eso el escenario principal
> de LSP se valida con `clangd` (sección 2.6), y con `lua_ls` sólo se comprueba
> que la petición se hace sin errores.

### 2.2 Abrir el picker

| Paso | Resultado esperado |
| --- | --- |
| Cursor sobre `unused` → `<leader>ca` (o `:CodeActions`) | Se abre el picker (lista + prompt + preview) |
| La lista muestra cabeceras de grupo (`Quick Fix`, `Refactor: Extract`, ...) | Una cabecera por kind, en el orden de `group_order` |
| Cada acción muestra icono, título, atajo numérico y origen (`lsp:lua_ls`) | Textos legibles, fila seleccionada resaltada |
| El panel derecho muestra el diff | Cabeceras `--- a/...` / `+++ b/...` y las líneas cambiadas |

Diagnóstico: si el picker no abre, comprueba `:messages`; si abre vacío,
`lua_ls` no devolvió acciones (es normal, ver el aviso de 2.1).

### 2.3 Filtrado en vivo

| Paso | Resultado esperado |
| --- | --- |
| Escribir `rem` | La lista se reduce a las acciones que coinciden (fuzzy por título/kind/origen) |
| Escribir `zzz` (sin coincidencias) | La lista queda vacía y aparece *No matching actions* |
| Borrar el texto | Vuelven todas las acciones, con la selección en la primera |

Diagnóstico: si el filtro no responde, el evento `TextChangedI` no está
disparando → comprobar `vim.bo[buf].buftype == "prompt"` en la ventana de
filtrado.

Diagnóstico: *No matching actions* sólo significa "la lista filtrada está
vacía". La causa habitual es que la línea del prompt incluya el prefijo: Neovim
guarda los buffers `buftype=prompt` con el prefijo *dentro* de la línea, así que
leerla cruda da `" > "` con el filtro vacío y ninguna acción coincide. El filtro
debe aplicarse sobre el texto **sin** el prefijo (`prompt_getprompt`); el informe
de `:KatanaDebug` muestra en `filtro=` lo que se está aplicando de verdad.

### 2.4 Previsualización reactiva

| Paso | Resultado esperado |
| --- | --- |
| `<C-n>` / `<Down>` | Cambia la fila seleccionada y **el diff de la derecha se actualiza** |
| Moverse sobre una acción sin cambios | El panel indica que no produce cambios (título, origen, kind) |
| `<C-p>` / `<Up>` | Vuelve a la anterior y el diff se regenera |
| `]` / `[` | Salta al grupo siguiente / anterior |

Diagnóstico: si el diff no cambia, revisar `katana.preview.diff` y que la acción
tenga `edit` (las acciones de `lua_ls` normalmente lo traen tras el resolve;
las que ya vienen resueltas lo traen en línea).

### 2.5 Confirmar y deshacer

| Paso | Resultado esperado |
| --- | --- |
| `<CR>` sobre la acción | El picker se cierra, el foco vuelve al buffer y **la edición se aplica** |
| `u` (una sola vez) | Se deshace **sólo** la acción (undo agrupado), sin arrastrar ediciones previas |
| `u` otra vez | Se deshace la edición anterior del usuario |

Este es el test crítico del *undo agrupado*: si un solo `u` revierte también tus
ediciones previas, revisar `katana.lsp.workspace.close_undo_block` (reasignación
de `undolevels`).

### 2.6 Acciones con comando

Algunas acciones llegan como `Command` (no como `WorkspaceEdit`), p. ej. *Rename
file*. Al confirmarlas debe ejecutarse el comando del servidor sin errores en
`:messages`.

### 2.7 LSP real con `clangd` (quickfix verificable)

`clangd` sí ofrece code actions comprobables:

1. Crear `demo.c`:

   ```c
   int main(void) {
     int x = 1
     return 0;
   }
   ```

2. Abrirlo y esperar al diagnóstico (*Expected ';' at end of declaration*).
3. Colocar el cursor **sobre la línea donde `clangd` reporta el diagnóstico**
   (`clangd` lo reporta en la línea siguiente al código que falta el `;`; usa
   `]d` para saltar al diagnóstico).
4. `<leader>ca` → aparece *insert ';'* (kind `quickfix`).
5. El preview muestra el diff con el `;` añadido.
6. `<CR>` → el buffer queda con `int x = 1;`.
7. `u` → vuelve a `int x = 1` (un solo `u`).

> Si no aparece ninguna acción, comprueba que el cursor está en la **misma
> línea** que el diagnóstico: el filtro de diagnósticos de Katana es por línea
> (igual que el de `vim.lsp.buf.code_action()`).

### 2.8 C# con `roslyn_ls`: "Generar método" (escenario del usuario)

Éste es el escenario que motivó el cambio de `csharp_ls` a `roslyn_ls` (el
servidor oficial de Microsoft). `csharp_ls` no implementa las code actions de
Roslyn, así que la acción *Generar método* no aparece.

1. Abrir un proyecto de C# (por ejemplo
   `C:\Users\rosas\Documents\code\cs\Practica_metodos\Program.cs`) con una
   llamada a un método inexistente:

   ```csharp
   Console.WriteLine(Suma(7,5.2));
   ```

2. Esperar al diagnóstico `CS0103` (*El nombre 'Suma' no existe en el contexto
   actual*). Comprobar con `:lua vim.diagnostic.get(0)`.
3. `<leader>ca` → la lista incluye **Generar método "Suma"** (kind `quickfix`,
   origen `lsp:roslyn_ls`).
4. El preview muestra el método nuevo.
5. `<CR>` → se inserta el método en la clase:

   ```csharp
   private static bool Suma(int v1, double v2)
   {
       throw new NotImplementedException();
   }
   ```

6. `u` → vuelve a deshacer sólo ese cambio.

> **El cursor NO tiene que estar sobre `Suma`.** Con `code_action_range = "auto"`
> (por defecto) Katana pide varios rangos y fusiona las respuestas: el rango
> real del diagnóstico, el del identificador bajo el cursor y **el de la línea
> completa**. El último es la red de seguridad: cubre el token con error
> aunque el cursor esté en otra palabra de la línea. Con el rango antiguo
> (`"cursor"`) sólo aparecía si el cursor estaba exactamente sobre el
> identificador.

| `code_action_range` | Acciones | ¿Aparece "Generar método Suma"? |
| ------------------- | -------- | --------------------------------- |
| `"cursor"` (antiguo) | 8        | ❌ sólo con el cursor sobre `Suma`   |
| `"auto"` (nuevo)     | 15       | ✅ con el cursor en cualquier punto de la línea |

Además, aunque el buffer **no tenga diagnósticos publicados** (Roslyn usa *pull
diagnostics* y tarda en cargAR el proyecto), Katana se los pide al servidor
(`textDocument/diagnostic`) antes de calcular el rango, así que la acción sigue
apareciendo. Se puede desactivar con `pull_diagnostics = false`.

Si aun así no aparece, `:KatanaDebug` imprime el informe completo de la
petición: clientes LSP conectados, diagnósticos, rangos pedidos, acciones
recibidas y estado del picker (acciones que llegaron a la lista, cuántas pasan
el filtro, con qué texto y el error si falló al abrirse).

Distinción rápida según lo que muestre la lista:

- `No matching actions` con el filtro vacío → el servidor no devolvió nada.
- `No matching actions` con texto en el filtro → el filtro lo descarta todo
  (`<C-u>` en el prompt lo limpia).

### 2.9 Configurar `roslyn_ls` en Neovim

En `C:\Users\rosas\AppData\Local\nvim`:

- `lua/chadrc.lua` → `M.mason.pkgs` debe incluir `"roslyn-language-server"`
  (Mason instala el binario `roslyn-language-server`).
- `lua/configs/lspconfig.lua` → la lista de servidores debe incluir
  `"roslyn_ls"` y **no** `"csharp_ls"` (dos servidores C# a la vez duplican los
  diagnósticos).
- `lua/plugins/init.lua` → el spec de `nvim-lspconfig` debe llevar
  `lazy = false`.

> **Por qué `lazy = false`**: NvChad carga `nvim-lspconfig` con
> `event = "User FilePost"`. Eso hace que `vim.lsp.enable()` registre su
> autocmd de `FileType` **después** de que el primer fichero abierto ya tenga
> el `filetype` puesto, así que ese buffer se queda sin servidor LSP (y sin
> diagnósticos, sin code actions...). Con `lazy = false` el plugin se carga al
> inicio y todos los buffers encuentran su LSP.

Comprobación rápida (sin GUI):

```bash
nvim --headless -u "C:\Users\rosas\AppData\Local\nvim\init.lua" \
  -l C:\Users\rosas\AppData\Local\Temp\opencode\e2e_katana_roslyn.lua
```

El script deja el informe en `e2e_report.txt`: debe listar `roslyn_ls` como
cliente, el diagnóstico `CS0103` y la acción `Generar método "Suma"`.

---

## 3. Fuentes adicionales

### 3.1 Tree-sitter

Sobre un fichero Lua con un nodo bajo el cursor:

| Paso | Resultado esperado |
| --- | --- |
| Abrir el picker | Aparecen *Copy node text*, *Select node*, *Comment node* (origen `ts`) |
| *Copy node text* | El texto del nodo queda en el registro `"` |
| *Select node* | El nodo queda seleccionado visualmente en el buffer |
| *Comment node* | El nodo queda comentado con el `commentstring` del buffer (`--`) |

Diagnóstico: si no aparecen, comprobar `vim.treesitter.get_node` y que el
`filetype` tenga parser instalado (`nvim-treesitter`).

### 3.2 Acciones registradas por el usuario

```lua
require("katana").register_action({
  title = "Test: acción propia",
  kind = "source",
  source = "manual-test",
  run = function()
    vim.notify("Katana: acción propia ejecutada", vim.log.levels.INFO)
  end,
})
```

| Paso | Resultado esperado |
| --- | --- |
| Abrir el picker | Aparece *Test: acción propia* con origen `user:manual-test` |
| Confirmarla | Se ejecuta el callback y aparece la notificación |

### 3.3 Proveedores

```lua
require("katana").register_provider(function(ctx)
  return {
    { title = "Test: desde proveedor", kind = "codeaction", source = "provider:test", execute_fn = function() end },
  }
end, "test")
```

| Paso | Resultado esperado |
| --- | --- |
| Abrir el picker | Aparece *Test: desde proveedor* con origen `provider:test` |

### 3.4 Dedupe

Registrar dos acciones con el mismo `title` y `kind` pero distinto origen: en el
picker debe aparecer **una sola fila** mostrando ambos orígenes separados por
comas.

---

## 4. Rangos y modos

| Acción | Resultado esperado |
| --- | --- |
| `:CodeActions` | Usa la posición del cursor |
| `:CodeActions line` | Usa la línea completa como rango |
| `:CodeActions visual` (con selección) | Usa el rango seleccionado |
| `:CodeActions` con selección visual | Usa la selección (el scope se detecta automáticamente) |
| `:KatanaSource` | Sólo pide acciones de tipo `source` (`context.only`) |
| `require("katana").open({ scope = "line" })` | Usa la línea completa como rango |
| `:CodeActions bogus` | Mensaje de error indicando los scopes válidos |
| `:KatanaDebug` | Informe de la petición: clientes, diagnósticos, rangos, acciones y estado del picker |

> **Modo visual**: las marcas `'<` y `'>` sólo se actualizan al salir del modo
> visual, así que `make_given_range_params()` devuelve la selección *anterior*.
> Katana fuerza la salida del modo visual para leer la selección **actual** y
> devuelve el cursor a su sitio.

---

## 5. Casos límite y regresión

| Caso | Resultado esperado |
| --- | --- |
| Buffer sin servidor LSP | El picker muestra las acciones de Tree-sitter / registradas; si no hay ninguna, aviso "no code actions found" |
| Terminal estrecho (< 60 columnas) | El panel de previsualización se omite; el picker sigue usable |
| `<C-c>` / `<Esc>` / `q` | Cierra el picker y devuelve el foco al buffer original |
| Abrir el picker dos veces seguidas | No quedan ventanas huérfanas ni buffers filtrados (`:ls` limpio) |
| Acción que falla (p. ej. un servidor que devuelve basura) | `vim.notify` a nivel ERROR, sin excepción no capturada |
| `codeAction/resolve` que no responde | Aviso de timeout a los 5 s, sin bloquear la interfaz |
| Acción deshabilitada (`disabled`) | Se muestra en gris (`KatanaDisabled`) y al confirmarla avisa sin aplicarse |

---

## 6. Multilenguaje (opcional, valida la conversión de posiciones)

Con `clangd` (ya instalado vía mason):

1. Abrir un `.c` con un carácter no-ASCII (`ñ`, emoji en un string o en un
   identificador UTF-8).
2. Provocar un diagnóstico sobre esa línea.
3. `:CodeActions` → confirmar la corrección.

Si la edición se aplica en el sitio equivocado, el problema es la conversión
byte ↔ unidad de codificación: revisar `katana.lsp.workspace.char_to_byte` /
`byte_to_char` y la `encoding` que se envía (utf-16 por defecto).

Con `roslyn_ls` (instalado): es el servidor que se usa para C#. Si aquí
`codeAction` responde sin `Internal error: JsonSerializationException`, el saneado
de diagnósticos (`core.fetch.sanitize_diagnostic`) está funcionando. El
`csharp_ls` antiguo fallaba precisamente con ese error cuando el contexto
llevaba la lista `diagnostics` ausente.

---

## 7. Checklist final

- [ ] `:CodeActions` abre el picker con la lista agrupada por kind
- [ ] Las cabeceras de grupo aparecen en el orden configurado
- [ ] El filtrado en vivo reduce la lista y se puede vaciar
- [ ] El diff del panel derecho es correcto y reactivo
- [ ] Un `u` deshace únicamente la acción
- [ ] El picker se cierra y devuelve el foco
- [ ] Las acciones de Tree-sitter y las registradas por el usuario aparecen
- [ ] `clangd` ofrece *insert ';'* y se aplica en el sitio correcto
- [ ] `roslyn_ls` ofrece *Generar método "Suma"* aunque el cursor no esté sobre `Suma`
- [ ] `roslyn_ls` ofrece *Generar método "Suma"* aunque el buffer todavía no tenga diagnósticos publicados (*pull*)
- [ ] En modo visual, las acciones corresponden a la **selección actual** (no a la anterior)
- [ ] `:KatanaDebug` muestra clientes, diagnósticos, rangos, acciones de la petición y el estado del picker
- [ ] Con el filtro vacío la lista nunca dice *No matching actions* si el servidor devolvió acciones
- [ ] El prefijo del prompt no cuenta como texto del filtro (`filtro=` vacío con el prompt vacío)
- [ ] Si algo falla al abrir el picker, sale un error en vez de quedarse en *No matching actions*
- [ ] La fila seleccionada tiene fondo propio y barra `▎`, y se distinguen del fondo de la flotante
- [ ] El icono conserva su color por kind también en la fila seleccionada
- [ ] Cada kind tiene un icono y un color distintos (sin glifos duplicados)
- [ ] Las cabeceras de grupo muestran su regla horizontal y su icono coloreado
- [ ] Mover la selección (`j`/`k`) repinta la fila activa (el fondo la sigue)
- [ ] No hay errores en `:messages` ni fugas de buffers/ventanas
