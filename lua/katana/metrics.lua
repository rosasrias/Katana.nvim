---@mod katana.metrics Métricas de latencia para apertura y resolución
local uv = vim.uv or vim.loop

local M = {}
M.timers = {}

function M.start(name)
  M.timers[name] = uv.hrtime()
  return M.timers[name]
end

function M.stop(name)
  local start = M.timers[name]
  if not start then
    return nil
  end
  local elapsed_ns = uv.hrtime() - start
  M.timers[name] = nil
  local ms = elapsed_ns / 1e6
  return ms
end

function M.measure(name, fn, ...)
  M.start(name)
  local res = fn(...)
  local ms = M.stop(name)
  return res, ms
end

return M
