-- Utilidades compartidas por los scripts de prueba.
--
-- Se carga con `dofile` (no con `require`) para que funcione sin depender del
-- `package.path` ni del directorio de trabajo.

local M = {}

--- Añade Volt al `runtimepath` si está disponible.
---@return boolean
function M.ensure_volt()
  if pcall(require, "volt") then
    return true
  end

  local candidates = {}

  if vim.env.KATANA_VOLT then
    candidates[#candidates + 1] = vim.env.KATANA_VOLT
  end

  local data = vim.fn.stdpath("data")
  candidates[#candidates + 1] = data .. "/lazy/volt"
  candidates[#candidates + 1] = data .. "/site/pack/packer/start/volt"
  candidates[#candidates + 1] = data .. "/site/pack/vendor/start/volt"

  for _, path in ipairs(candidates) do
    if vim.fn.isdirectory(path) == 1 then
      vim.opt.rtp:append(path)
      if pcall(require, "volt") then
        return true
      end
    end
  end

  return false
end

--- Localiza el ejecutable de clangd.
---@return string|nil
function M.find_clangd()
  if vim.env.KATANA_CLANGD then
    return vim.env.KATANA_CLANGD
  end

  local exe = vim.fn.exepath("clangd")
  if exe ~= "" then
    return exe
  end

  local data = vim.fn.stdpath("data")
  local candidates = {
    data .. "/mason/bin/clangd",
    data .. "/mason/bin/clangd.exe",
    data .. "/mason/bin/clangd.cmd",
  }

  for _, path in ipairs(candidates) do
    if vim.fn.filereadable(path) == 1 then
      return path
    end
  end

  return nil
end

--- Arranca un cliente LSP (compatible con 0.10, 0.11 y 0.12).
---@param config table
---@return integer client_id
function M.start_client(config)
  if vim.lsp.start then
    local ok, client_id = pcall(vim.lsp.start, config)
    if ok and client_id then
      return client_id
    end
  end

  return vim.lsp.start_client(config)
end

--- Acumula el resultado de las comprobaciones.
---@return table
function M.reporter()
  local out = {}
  local failures = 0

  local reporter = {}

  function reporter.out()
    return out
  end

  function reporter.check(name, cond, extra)
    local line = string.format("  %s  %s%s", cond and "OK  " or "FAIL", name, extra and ("  | " .. tostring(extra)) or "")
    out[#out + 1] = line
    if not cond then
      failures = failures + 1
    end
  end

  function reporter.header(title)
    out[#out + 1] = title
    out[#out + 1] = ""
  end

  function reporter.skip(message)
    out[#out + 1] = "  SKIP  " .. message
  end

  function reporter.finish()
    out[#out + 1] = string.format("\n%d checks, %d fallos", #out - 2, failures)
    io.stdout:write(table.concat(out, "\n") .. "\n")

    if failures > 0 then
      vim.cmd("cquit 1")
    end
  end

  return reporter
end

return M
