-- Pruebas del contrato de edición y ejecución de Katana (sin UI ni LSP real).
--
--   nvim --headless -u NONE -l scripts/apply.lua
--
-- Cubre:
--   * preparación validada de WorkspaceEdit (URIs, buffers, versiones, rangos),
--   * precedencia de `documentChanges` sobre `changes` y fusión por URI,
--   * aplicación sin doble efecto, rollback verificado y límites de atomicidad,
--   * contrato de resultado del executor (success/failed/partial/cancelled/
--     timed_out), notificaciones y callbacks,
--   * resolución asíncrona: error, timeout, cancelación, respuestas duplicadas
--     y peticiones coalescidas,
--   * normalización de acciones registradas y de proveedores (`run` y
--     `execute_fn`),
--   * selección del cliente LSP para `workspace/executeCommand`,
--   * campos opcionales presentes como `null` JSON (`vim.NIL`) tratados como
--     ausentes en la normalización, el WorkspaceEdit y la resolución.

local script = debug.getinfo(1, "S").source:sub(2)
local dir = vim.fn.fnamemodify(script, ":p:h")
local root = vim.fn.fnamemodify(dir, ":h")

vim.opt.rtp:append(root)

local env = dofile(dir .. "/env.lua")
local report = env.reporter()

report.header("Katana.nvim · apply/workspace")

local katana = require("katana")
katana.setup({ ts = { enabled = false }, resolve_on_open = false })

local workspace = require("katana.lsp.workspace")
local apply = require("katana.apply")
local resolve = require("katana.core.resolve")
local config = require("katana.config")

local function temp_file(name, lines)
  local directory = vim.fn.tempname()
  vim.fn.mkdir(directory, "p")
  local path = directory .. "/" .. name
  vim.fn.writefile(lines or {}, path)
  return path
end

local function load(path)
  local bufnr = vim.fn.bufadd(path)
  vim.fn.bufload(bufnr)
  return bufnr
end

local function uri(path)
  return vim.uri_from_fname(path)
end

local function lines(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

local function replace(path, line, start_char, stop_char, new_text, version)
  return {
    textDocument = { uri = uri(path), version = version },
    edits = {
      {
        range = {
          start = { line = line, character = start_char },
          ["end"] = { line = line, character = stop_char },
        },
        newText = new_text,
      },
    },
  }
end

local function changes_edit(path, line, start_char, stop_char, new_text)
  return {
    changes = {
      [uri(path)] = {
        {
          range = {
            start = { line = line, character = start_char },
            ["end"] = { line = line, character = stop_char },
          },
          newText = new_text,
        },
      },
    },
  }
end

--------------------------------------------------------------------------------
-- 1. Preparación y aplicación multi-archivo
--------------------------------------------------------------------------------

local p1 = temp_file("one.txt", { "alpha", "beta" })
local p2 = temp_file("two.txt", { "gamma", "delta" })
local b1 = load(p1)
local b2 = load(p2)

local multi = {
  documentChanges = {
    replace(p1, 0, 0, 5, "ALPHA"),
    replace(p2, 1, 0, 5, "DELTA"),
  },
}

local plan, plan_err = workspace.prepare_edit(multi, b1, "utf-8")
report.check("prepare_edit multi-archivo", plan ~= nil, plan_err)
report.check("prepare_edit no escribe nada", lines(b1)[1] == "alpha" and lines(b2)[2] == "delta")

local applied, apply_err, apply_info = workspace.apply_plan(plan)
report.check("apply_plan multi-archivo", applied, apply_err)
report.check(
  "los dos ficheros se actualizan",
  lines(b1)[1] == "ALPHA" and lines(b2)[2] == "DELTA",
  vim.inspect({ one = lines(b1), two = lines(b2) })
)
report.check("apply_info registra los buffers", #apply_info.applied_buffers == 2, #apply_info.applied_buffers)

local reapplied = workspace.apply_plan(plan)
report.check("un plan no se aplica dos veces", reapplied == false)
report.check("reaplicar no duplica la edición", lines(b1)[1] == "ALPHA", lines(b1)[1])

--------------------------------------------------------------------------------
-- 2. Fallos detectados antes de escribir: nada cambia
--------------------------------------------------------------------------------

local p3 = temp_file("three.txt", { "uno" })
local b3 = load(p3)
local missing = p3:gsub("three%.txt$", "no-existe.txt")

local invalid_target = { documentChanges = { replace(p3, 0, 0, 3, "UNO"), replace(missing, 0, 0, 1, "X") } }
local target_plan, target_err = workspace.prepare_edit(invalid_target, b3, "utf-8")
report.check("destino inexistente rechazado", target_plan == nil, target_err)
report.check("destino inexistente no deja cambios parciales", lines(b3)[1] == "uno", lines(b3)[1])

local out_of_range = { documentChanges = { replace(p3, 5, 0, 0, "X") } }
local range_plan, range_err = workspace.prepare_edit(out_of_range, b3, "utf-8")
report.check("rango fuera del buffer rechazado", range_plan == nil, range_err)

local out_of_column = { documentChanges = { replace(p3, 0, 99, 99, "X") } }
local column_plan, column_err = workspace.prepare_edit(out_of_column, b3, "utf-8")
report.check("columna fuera de la línea rechazada", column_plan == nil, column_err)

local reversed = {
  documentChanges = {
    {
      textDocument = { uri = uri(p3) },
      edits = {
        { range = { start = { line = 0, character = 2 }, ["end"] = { line = 0, character = 1 } }, newText = "X" },
      },
    },
  },
}
local reversed_plan, reversed_err = workspace.prepare_edit(reversed, b3, "utf-8")
report.check("rango invertido rechazado", reversed_plan == nil, reversed_err)

local nested_overlap = {
  documentChanges = {
    {
      textDocument = { uri = uri(p2) },
      edits = {
        { range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 5 } }, newText = "A" },
        { range = { start = { line = 0, character = 1 }, ["end"] = { line = 0, character = 2 } }, newText = "B" },
        { range = { start = { line = 0, character = 3 }, ["end"] = { line = 0, character = 4 } }, newText = "C" },
      },
    },
  },
}
local overlap_plan, overlap_err = workspace.prepare_edit(nested_overlap, b2, "utf-8")
report.check("solapamiento anidado rechazado", overlap_plan == nil, overlap_err)

local same_start = {
  documentChanges = {
    {
      textDocument = { uri = uri(p2) },
      edits = {
        { range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } }, newText = "A" },
        { range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } }, newText = "B" },
      },
    },
  },
}
local same_plan, same_err = workspace.prepare_edit(same_start, b2, "utf-8")
report.check("dos inserciones en el mismo punto rechazadas", same_plan == nil, same_err)

local empty_plan, empty_err = workspace.prepare_edit({ changes = {} }, b3, "utf-8")
report.check("WorkspaceEdit vacío rechazado", empty_plan == nil, empty_err)

local resource = {
  documentChanges = {
    { kind = "createFile", uri = uri(p3), options = { overwrite = false } },
  },
}
local resource_plan, resource_err = workspace.prepare_edit(resource, b3, "utf-8")
report.check("operación de recurso rechazada", resource_plan == nil, resource_err)

local untitled = {
  documentChanges = {
    {
      textDocument = { uri = "untitled:Untitled-1" },
      edits = { { range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } }, newText = "X" } },
    },
  },
}
local untitled_plan, untitled_err = workspace.prepare_edit(untitled, b3, "utf-8")
report.check("URI no file: rechazada", untitled_plan == nil, untitled_err)

--------------------------------------------------------------------------------
-- 3. Versiones y precedencia changes/documentChanges
--------------------------------------------------------------------------------

local p4 = temp_file("four.txt", { "version" })
local b4 = load(p4)

local util = vim.lsp.util
local had_versions = util.buf_versions ~= nil
local old_versions = util.buf_versions
util.buf_versions = util.buf_versions or {}
util.buf_versions[b4] = 10

local stale = { documentChanges = { replace(p4, 0, 0, 7, "STALE", 9) } }
local stale_plan, stale_err = workspace.prepare_edit(stale, b4, "utf-8")
report.check("versión obsoleta rechazada", stale_plan == nil, stale_err)

local current = { documentChanges = { replace(p4, 0, 0, 7, "CURRENT", 10) } }
local current_plan, current_err = workspace.prepare_edit(current, b4, "utf-8")
report.check("versión actual aceptada", current_plan ~= nil, current_err)

util.buf_versions[b4] = old_versions and old_versions[b4] or nil
if not had_versions then
  util.buf_versions = old_versions
end

local p5 = temp_file("five.txt", { "original" })
local b5 = load(p5)

local both = {
  documentChanges = {
    {
      textDocument = { uri = uri(p5) },
      edits = { { range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 8 } }, newText = "DOC" } },
    },
  },
  changes = {
    [uri(p5)] = {
      { range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 8 } }, newText = "CHANGES" },
    },
  },
}
local both_plan = workspace.prepare_edit(both, b5, "utf-8")
report.check("documentChanges tiene prioridad", both_plan ~= nil)
local both_ok, both_err = workspace.apply_plan(both_plan)
report.check("sólo se aplica una vez", both_ok and lines(b5)[1] == "DOC", both_err or lines(b5)[1])

local p6 = temp_file("six.txt", { "abcdef" })
local b6 = load(p6)
local merged = {
  documentChanges = {
    {
      textDocument = { uri = uri(p6) },
      edits = { { range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 1 } }, newText = "A" } },
    },
    {
      textDocument = { uri = uri(p6) },
      edits = { { range = { start = { line = 0, character = 5 }, ["end"] = { line = 0, character = 6 } }, newText = "F" } },
    },
  },
}
local merged_plan, merged_err = workspace.prepare_edit(merged, b6, "utf-8")
report.check("entradas de la misma URI se fusionan", merged_plan ~= nil and #merged_plan.groups == 1, merged_err)
local merged_ok = workspace.apply_plan(merged_plan)
report.check("ediciones fusionadas se aplican", merged_ok and lines(b6)[1] == "AbcdeF", lines(b6)[1])

local conflicting_versions = {
  documentChanges = {
    { textDocument = { uri = uri(p6), version = 1 }, edits = { { range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } }, newText = "X" } } },
    { textDocument = { uri = uri(p6), version = 2 }, edits = { { range = { start = { line = 0, character = 1 }, ["end"] = { line = 0, character = 1 } }, newText = "Y" } } },
  },
}
local conflict_plan, conflict_err = workspace.prepare_edit(conflicting_versions, b6, "utf-8")
report.check("versiones incompatibles para la misma URI rechazadas", conflict_plan == nil, conflict_err)

--------------------------------------------------------------------------------
-- 4. Rollback verificado y límites de atomicidad
--------------------------------------------------------------------------------

local r1 = temp_file("rollback-one.txt", { "first" })
local r2 = temp_file("rollback-two.txt", { "second" })
local rb1 = load(r1)
local rb2 = load(r2)

local rollback_edit = { documentChanges = { replace(r1, 0, 0, 5, "FIRST"), replace(r2, 0, 0, 6, "SECOND") } }
local rollback_plan = workspace.prepare_edit(rollback_edit, rb1, "utf-8")

local real_apply = workspace.apply_edits_to_buffer
local calls = 0
workspace.apply_edits_to_buffer = function(bufnr, edits, encoding)
  calls = calls + 1
  if calls == 2 then
    error("fallo simulado en el segundo fichero")
  end
  return real_apply(bufnr, edits, encoding)
end

local rolled_ok, rolled_err, rolled_info = workspace.apply_plan(rollback_plan)
workspace.apply_edits_to_buffer = real_apply

report.check("fallo a mitad no se presenta como éxito", rolled_ok == false, rolled_err)
report.check("el primer fichero se revierte", lines(rb1)[1] == "first", lines(rb1)[1])
report.check("rollback verificado", rolled_info.rollback == "restored", rolled_info.rollback)

local c1 = temp_file("concurrent-one.txt", { "first" })
local c2 = temp_file("concurrent-two.txt", { "second" })
local cb1 = load(c1)
local cb2 = load(c2)

local concurrent_edit = { documentChanges = { replace(c1, 0, 0, 5, "FIRST"), replace(c2, 0, 0, 6, "SECOND") } }
local concurrent_plan = workspace.prepare_edit(concurrent_edit, cb1, "utf-8")

calls = 0
workspace.apply_edits_to_buffer = function(bufnr, edits, encoding)
  calls = calls + 1
  if calls == 2 then
    -- Simula que otro proceso/usuario tocó el primer buffer entre la escritura
    -- y el fallo: el rollback no debe pisar ese cambio.
    vim.api.nvim_buf_set_lines(cb1, 0, -1, false, { "CONCURRENT" })
    error("fallo simulado tras un cambio concurrente")
  end
  return real_apply(bufnr, edits, encoding)
end

local concurrent_ok, _, concurrent_info = workspace.apply_plan(concurrent_plan)
workspace.apply_edits_to_buffer = real_apply

report.check("rollback no pisa cambios concurrentes", concurrent_ok == false)
report.check("se informa del rollback fallido", concurrent_info.rollback == "failed", concurrent_info.rollback)
report.check("el cambio concurrente se conserva", lines(cb1)[1] == "CONCURRENT", lines(cb1)[1])

--------------------------------------------------------------------------------
-- 5. Executor: contrato de resultado
--------------------------------------------------------------------------------

local function exec(action, opts)
  opts = opts or {}
  opts.bufnr = opts.bufnr or b3
  opts.win = opts.win or vim.api.nvim_get_current_win()
  opts.notify = false
  return apply.execute(action, opts)
end

vim.api.nvim_buf_set_lines(b3, 0, -1, false, { "uno" })
local ok_action = {
  title = "Replace",
  kind = "quickfix",
  source = "lsp:test",
  encoding = "utf-8",
  edit = changes_edit(p3, 0, 0, 3, "UNO"),
}
local ok_result = exec(ok_action)
report.check("executor success", ok_result and ok_result.status == "success", ok_result and ok_result.status)
report.check("executor aplica la edición", lines(b3)[1] == "UNO", lines(b3)[1])
report.check("executor marca effects.edit", ok_result.effects.edit == true)

local partial_action = {
  title = "Partial",
  source = "user:test",
  encoding = "utf-8",
  edit = changes_edit(p3, 0, 0, 3, "PARCIAL"),
  execute_fn = function()
    error("fallo de execute_fn")
  end,
}
local partial_result = exec(partial_action)
report.check("executor partial tras efecto", partial_result.status == "partial", partial_result.status)
report.check("partial conserva el efecto", lines(b3)[1] == "PARCIAL", lines(b3)[1])
report.check("partial indica la etapa", partial_result.stage == "execute_fn", partial_result.stage)

local failed_command = exec({
  title = "Bad command",
  source = "user:test",
  command = { command = "" },
})
report.check("comando inválido falla", failed_command.status == "failed" and failed_command.stage == "command")

local disabled_result = exec({
  title = "Disabled",
  source = "lsp:test",
  disabled = { reason = "not applicable" },
  edit = changes_edit(p3, 0, 0, 3, "NO"),
})
report.check("acción deshabilitada no se aplica", disabled_result.status == "failed" and lines(b3)[1] == "PARCIAL")

local no_effect = exec({ title = "Nothing", source = "user:test" })
report.check("acción sin efectos falla", no_effect.status == "failed" and no_effect.stage == "validate")

local notify_count = 0
local original_notify = vim.notify
vim.notify = function()
  notify_count = notify_count + 1
end
apply.execute({ title = "Notify", source = "user:test", disabled = true }, { bufnr = b3, win = vim.api.nvim_get_current_win() })
apply.execute(
  { title = "Notify off", source = "user:test", disabled = true },
  { bufnr = b3, win = vim.api.nvim_get_current_win(), notify = false }
)
vim.notify = original_notify
report.check("notificación centralizada y única", notify_count == 1, notify_count)

local callback_result = nil
local callback_ok = apply.execute({
  title = "Callback",
  source = "user:test",
  execute_fn = function() end,
}, {
  bufnr = b3,
  win = vim.api.nvim_get_current_win(),
  notify = false,
  on_result = function(result)
    callback_result = result
    error("fallo del callback")
  end,
})
report.check("on_result recibe el resultado", callback_result ~= nil)
report.check("un callback defectuoso no oculta el resultado", callback_ok.status == "success")
report.check("el error del callback se registra", callback_result.callback_error ~= nil)

local invalid_edit = exec({
  title = "Bad target",
  source = "lsp:test",
  encoding = "utf-8",
  edit = changes_edit(p3:gsub("three%.txt$", "missing.txt"), 0, 0, 1, "X"),
})
report.check("destino inválido falla sin efecto", invalid_edit.status == "failed" and invalid_edit.stage == "edit")

--------------------------------------------------------------------------------
-- 6. Resolución asíncrona
--------------------------------------------------------------------------------

local async_path = temp_file("async.txt", { "before" })
local async_buf = load(async_path)

local resolve_calls = 0
local sync_resolved = {
  title = "Resolved",
  source = "lsp:test",
  encoding = "utf-8",
  resolve_fn = function(cb)
    resolve_calls = resolve_calls + 1
    local resolved = {
      title = "Resolved",
      source = "lsp:test",
      encoding = "utf-8",
      edit = changes_edit(async_path, 0, 0, 6, "AFTER"),
    }
    cb(resolved, nil)
  end,
}
local sync_result = exec(sync_resolved, { bufnr = async_buf })
report.check("resolución síncrona devuelve KatanaResult", sync_result ~= nil and sync_result.status == "success", sync_result and sync_result.status)
report.check("resolución síncrona aplica el edit", lines(async_buf)[1] == "AFTER", lines(async_buf)[1])
report.check("resolve_fn se llama una vez", resolve_calls == 1, resolve_calls)

local resolve_error = exec({
  title = "Resolve error",
  source = "lsp:test",
  resolve_fn = function(cb)
    cb(nil, "servidor caído")
  end,
}, { bufnr = async_buf })
report.check("error de resolución falla", resolve_error.status == "failed" and resolve_error.stage == "resolve", resolve_error.status)

local timeout_result = nil
local timeout_handle = apply.execute({
  title = "Timeout",
  source = "lsp:test",
  resolve_fn = function() end,
}, {
  bufnr = async_buf,
  win = vim.api.nvim_get_current_win(),
  notify = false,
  timeout = 50,
  on_result = function(result)
    timeout_result = result
  end,
})
report.check("resolución lenta devuelve un handle", timeout_handle ~= nil and timeout_handle.finished == false)
vim.wait(1000, function()
  return timeout_result ~= nil
end)
report.check("timeout de resolución", timeout_result ~= nil and timeout_result.status == "timed_out", timeout_result and timeout_result.status)
timeout_handle.cancel("tarde")
report.check("cancelar tras terminar no cambia el resultado", timeout_result.status == "timed_out")

local cancel_result = nil
local cancel_handle = apply.execute({
  title = "Cancel",
  source = "lsp:test",
  resolve_fn = function() end,
}, {
  bufnr = async_buf,
  win = vim.api.nvim_get_current_win(),
  notify = false,
  timeout = 5000,
  on_result = function(result)
    cancel_result = result
  end,
})
cancel_handle.cancel("prueba")
report.check("cancelación antes de aplicar", cancel_result ~= nil and cancel_result.status == "cancelled", cancel_result and cancel_result.status)

vim.api.nvim_buf_set_lines(async_buf, 0, -1, false, { "before" })
local duplicate_results = 0
local duplicate_calls = 0
local duplicate = {
  title = "Duplicate",
  source = "lsp:test",
  encoding = "utf-8",
  resolve_fn = function(cb)
    duplicate_calls = duplicate_calls + 1
    local resolved = {
      title = "Duplicate",
      source = "lsp:test",
      encoding = "utf-8",
      edit = changes_edit(async_path, 0, 0, 6, "DUP"),
    }
    cb(resolved, nil)
    cb(resolved, nil)
  end,
}
exec(duplicate, {
  bufnr = async_buf,
  on_result = function()
    duplicate_results = duplicate_results + 1
  end,
})
report.check("respuestas duplicadas de resolve", duplicate_calls == 1 and duplicate_results == 1, vim.inspect({ duplicate_calls, duplicate_results }))
report.check("la edición duplicada se aplica una vez", lines(async_buf)[1] == "DUP", lines(async_buf)[1])

local pending_resolve = nil
local coalesced_action = {
  title = "Coalesced",
  source = "lsp:test",
  resolve_fn = function(cb)
    resolve_calls = resolve_calls + 1
    pending_resolve = cb
  end,
}
resolve_calls = 0
local first_cb = nil
local second_cb = nil
resolve.resolve_single(coalesced_action, function(action, err)
  first_cb = { action = action, err = err }
end)
resolve.resolve_single(coalesced_action, function(action, err)
  second_cb = { action = action, err = err }
end)
report.check("resoluciones en curso se coalescen", resolve_calls == 1, resolve_calls)
pending_resolve(coalesced_action, nil)
report.check("todos los interesados reciben la resolución", first_cb and second_cb and first_cb.action == coalesced_action and second_cb.action == coalesced_action)

resolve.resolve_single(coalesced_action, function(action)
  coalesced_again = action
end)
report.check("una acción resuelta no vuelve a pedir resolve", resolve_calls == 1 and coalesced_again == coalesced_action, resolve_calls)

--------------------------------------------------------------------------------
-- 7. Normalización de acciones propias y proveedores
--------------------------------------------------------------------------------

local register = require("katana.register")
local providers = require("katana.core.providers")
register.clear()
providers.clear()

local received = nil
register.register({
  title = "Run action",
  kind = "source",
  source = "test",
  run = function(action)
    received = action
  end,
})
local registered = register.get_actions({ bufnr = b3, win = vim.api.nvim_get_current_win() })
report.check("register normaliza run a execute_fn", #registered == 1 and type(registered[1].execute_fn) == "function")
report.check("origen de acción registrada", registered[1].source == "user:test", registered[1].source)
exec(registered[1])
report.check("run recibe la acción normalizada", received == registered[1] and received.title == "Run action")

register.clear()
local run_called = false
local execute_called = false
register.register({
  title = "Both",
  source = "test",
  run = function()
    run_called = true
  end,
  execute_fn = function()
    execute_called = true
  end,
})
local both_action = register.get_actions({ bufnr = b3, win = vim.api.nvim_get_current_win() })[1]
exec(both_action)
report.check("execute_fn tiene prioridad sobre run", execute_called and not run_called)

local invalid_register = pcall(register.register, { title = "Bad", run = "no-fn" })
report.check("run no función rechazado al registrar", invalid_register == false)
register.clear()

local provider_action = nil
providers.register(function()
  return {
    {
      title = "Provider run",
      kind = "source",
      source = "plugin",
      run = function(action)
        provider_action = action
      end,
    },
  }
end, "prov")
local provider_actions, provider_errors = providers.collect({ bufnr = b3, win = vim.api.nvim_get_current_win() })
report.check("proveedor normaliza run", #provider_actions == 1 and #provider_errors == 0, #provider_actions)
report.check("origen del proveedor", provider_actions[1].source == "provider:plugin", provider_actions[1].source)
exec(provider_actions[1])
report.check("run de proveedor recibe la acción normalizada", provider_action == provider_actions[1])
providers.clear()

report.check("register_action inválido no rompe la recogida", pcall(katana.register_action, { title = "x", run = 1 }) == false)

--------------------------------------------------------------------------------
-- 8. Selección del cliente para workspace/executeCommand
--------------------------------------------------------------------------------

local original_get_clients = vim.lsp.get_clients
local exec_called = nil

local fake_clients = {
  {
    id = 1,
    name = "alpha",
    exec_cmd = function(self)
      exec_called = self.name
    end,
  },
  {
    id = 2,
    name = "beta",
    exec_cmd = function(self)
      exec_called = self.name
    end,
  },
}

vim.lsp.get_clients = function()
  return fake_clients
end

local ambiguous = exec({
  title = "Ambiguous",
  source = "user:test",
  command = { command = "workspace.doThing" },
})
report.check("varios clientes sin client_id falla", ambiguous.status == "failed" and ambiguous.stage == "command", ambiguous.message)

exec_called = nil
local explicit = exec({
  title = "Explicit",
  source = "user:test",
  command = { command = "workspace.doThing" },
}, { client_id = 2 })
report.check("client_id explícito selecciona el cliente", explicit.status == "success" and exec_called == "beta", tostring(exec_called))

exec_called = nil
local by_name = exec({
  title = "By name",
  source = "lsp:alpha",
  command = { command = "workspace.doThing" },
})
report.check("origen lsp:<nombre> selecciona el cliente", by_name.status == "success" and exec_called == "alpha", tostring(exec_called))

local stale_client = exec({
  title = "Stale",
  source = "lsp:desaparecido",
  command = { command = "workspace.doThing" },
})
report.check("cliente LSP ausente falla", stale_client.status == "failed" and stale_client.stage == "command")

vim.lsp.get_clients = original_get_clients

--------------------------------------------------------------------------------
-- 9. Deduplicación con payload de resolución
--------------------------------------------------------------------------------

local prioritize = require("katana.core.prioritize")

local function lsp_action(source, data)
  return {
    title = "Same",
    kind = "quickfix",
    source = source,
    data = data,
    resolve_fn = function() end,
  }
end

local d1 = prioritize.filter_and_sort({ lsp_action("lsp:a", { id = 1 }), lsp_action("lsp:b", { id = 1 }) })
report.check("dedupe fusiona mismo data/resolve", #d1 == 1, #d1)

local d2 = prioritize.filter_and_sort({ lsp_action("lsp:a", { id = 1 }), lsp_action("lsp:b", { id = 2 }) })
report.check("dedupe conserva distinto data", #d2 == 2, #d2)

local raw1 = { title = "Raw", kind = "quickfix", source = "lsp:a", raw = { payload = "same" }, resolve_fn = function() end }
local raw2 = { title = "Raw", kind = "quickfix", source = "lsp:b", raw = { payload = "same" }, resolve_fn = function() end }
report.check("dedupe usa raw si no hay data", #prioritize.filter_and_sort({ raw1, raw2 }) == 1)

local function make_exec()
  return function() end
end
local e1 = { title = "Exec", kind = "source", source = "user:a", execute_fn = make_exec() }
local e2 = { title = "Exec", kind = "source", source = "user:b", execute_fn = make_exec() }
report.check("dedupe conserva execute_fn distintos", #prioritize.filter_and_sort({ e1, e2 }) == 2)

--------------------------------------------------------------------------------
-- 10. JSON null (vim.NIL) en campos opcionales
--------------------------------------------------------------------------------
--
-- Los servidores envían `null` para campos opcionales; `vim.json.decode` lo
-- convierte en `vim.NIL` (truthy). El executor debe interpretarlo como ausente.

local p7 = temp_file("null-fields.txt", { "nulo" })
local b7 = load(p7)

local null_version = {
  documentChanges = {
    {
      kind = vim.NIL,
      textDocument = { uri = uri(p7), version = vim.NIL },
      edits = {
        { range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 4 } }, newText = "NULO" },
      },
    },
  },
}
local null_plan, null_err = workspace.prepare_edit(null_version, b7, "utf-8")
report.check("versión null se trata como ausente", null_plan ~= nil, null_err)
report.check("kind null se ignora", null_plan ~= nil and #null_plan.groups == 1, null_err)
local null_applied = null_plan and workspace.apply_plan(null_plan)
report.check("edición con campos null se aplica", null_applied == true and lines(b7)[1] == "NULO", lines(b7)[1])

local null_document_changes = {
  documentChanges = vim.NIL,
  changes = {
    [uri(p7)] = {
      { range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 4 } }, newText = "NULL" },
    },
  },
}
local fallback_plan, fallback_err = workspace.prepare_edit(null_document_changes, b7, "utf-8")
report.check("documentChanges null permite usar changes", fallback_plan ~= nil, fallback_err)
local fallback_ok = fallback_plan and workspace.apply_plan(fallback_plan)
report.check("changes se aplica tras documentChanges null", fallback_ok == true and lines(b7)[1] == "NULL", lines(b7)[1])

local action_module = require("katana.core.action")
local null_action, null_action_err = action_module.normalize({
  title = "Nulls",
  source = "user:test",
  kind = vim.NIL,
  edit = vim.NIL,
  command = vim.NIL,
  resolve_fn = vim.NIL,
  execute_fn = vim.NIL,
  run = vim.NIL,
  data = vim.NIL,
  diagnostics = vim.NIL,
  disabled = vim.NIL,
  isPreferred = vim.NIL,
  id = vim.NIL,
  client_id = vim.NIL,
  encoding = vim.NIL,
  variants = vim.NIL,
  priority = vim.NIL,
})
report.check("acción con campos null se normaliza", null_action ~= nil, null_action_err)
report.check(
  "los campos null quedan ausentes",
  null_action
    and null_action.kind == nil
    and null_action.edit == nil
    and null_action.command == nil
    and null_action.data == nil
    and null_action.diagnostics == nil
    and null_action.disabled == nil
    and null_action.isPreferred == false,
  null_action and vim.inspect(null_action)
)
report.check("una acción con sólo nulls no tiene efectos", not action_module.has_effect(null_action))
report.check("validate_edit acepta null como ausente", apply.validate_edit(vim.NIL) == true)

local fetch = require("katana.core.fetch")
local null_client = {
  name = "nulls",
  id = 707,
  offset_encoding = "utf-8",
  supports_method = function(_, method)
    return method == "codeAction/resolve"
  end,
  request = function(_, method, _, callback)
    if method == "codeAction/resolve" then
      callback(nil, { edit = vim.NIL, command = vim.NIL, data = vim.NIL, isPreferred = vim.NIL })
    end
  end,
}
local lsp_actions = fetch.normalize_lsp_actions({
  {
    title = "Null LSP",
    kind = vim.NIL,
    edit = vim.NIL,
    command = vim.NIL,
    data = { id = 1 },
    diagnostics = vim.NIL,
    isPreferred = vim.NIL,
    disabled = vim.NIL,
  },
}, null_client, { bufnr = b7, encoding = "utf-8", diagnostics = {} })
report.check("acción LSP con nulls se normaliza", #lsp_actions == 1, #lsp_actions)

local lsp_action = lsp_actions[1]
local existing_edit = { changes = {} }
local resolve_done = false
if lsp_action then
  lsp_action.edit = existing_edit
end
if lsp_action and lsp_action.resolve_fn then
  lsp_action.resolve_fn(function(resolved, resolve_err)
    resolve_done = true
    report.check("resolve null no devuelve error", resolve_err == nil, resolve_err)
    report.check("resolve null conserva el edit existente", resolved.edit == existing_edit)
    report.check("resolve null no deja command", resolved.command == nil)
    report.check("resolve null conserva el data existente", type(resolved.data) == "table" and resolved.data.id == 1)
    report.check("resolve null no marca preferred", resolved.isPreferred == false)
  end)
end
report.check("resolve_fn de una acción con data se ejecuta", resolve_done)

report.finish()
