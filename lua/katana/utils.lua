local M = {}

local kind_map = {
  ["quickfix"] = "Quick Fix",
  ["refactor"] = "Refactor",
  ["refactor.extract"] = "Refactor: Extract",
  ["refactor.inline"] = "Refactor: Inline",
  ["refactor.rewrite"] = "Refactor: Rewrite",
  ["refactor.convert"] = "Refactor: Convert",
  ["source"] = "Source Actions",
  ["source.organizeImports"] = "Source: Organize Imports",
  ["source.fixAll"] = "Source: Fix All",
  ["command"] = "Command",
}

function M.kind_label(kind)
  if not kind then
    return "Other"
  end
  return kind_map[kind] or (kind:gsub("^%l", string.upper):gsub("%.", ": "))
end

function M.kind_group_key(kind)
  if not kind then
    return "other"
  end
  if kind:match("^quickfix") then
    return "quickfix"
  end
  if kind:match("^refactor%.extract") then
    return "refactor.extract"
  end
  if kind:match("^refactor%.inline") then
    return "refactor.inline"
  end
  if kind:match("^refactor%.rewrite") then
    return "refactor.rewrite"
  end
  if kind:match("^refactor%.convert") then
    return "refactor.convert"
  end
  if kind:match("^refactor") then
    return "refactor"
  end
  if kind:match("^source%.organizeImports") then
    return "source.organizeImports"
  end
  if kind:match("^source%.fixAll") then
    return "source.fixAll"
  end
  if kind:match("^source") then
    return "source"
  end
  if kind:match("^command") then
    return "command"
  end
  return "other"
end

function M.compact_title(title)
  if not title then
    return ""
  end
  return title:gsub("\r?\n", " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
end

return M
