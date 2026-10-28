local aiconfig = {}
local common = require("ai.common")
local globpattern = require("ai.globpattern")

-- ===== Prompt rules =====

local DEFAULT_SYSTEM_INSTRUCTIONS = "You are an expert software engineer and coding assistant."

local PLAN_RULES = [[
# Plan Generation Rules
- Generate a comprehensive, step-by-step technical plan based on the user's request and project context.
- Identify the exact files to create, modify, or remove and describe the required changes in detail.
- HARD CONSTRAINT: NEVER output full file contents. Provide only the architectural and implementation plan.
]]

local REWORD_RULES = [[
# Prompt + Plan Rewording Rules
- Merge the Prompt and the plan refine them into adirect prompt to be provided to the implementation model.
- You must enforce  the instruction that the implementation model must provide the full, complete new content of all files to modify or create.
- Answer with the merged and reworded prompt only, without any additional introduction, commentary, or explanation.
- HARD CONSTRAINT: Explicitly instruct the implementation model that it must NEVER return diffs, patches, or isolated snippets, but must provide the complete file contents.
]]

local IMPLEMENT_RULES = [[
# Implementation Rules
- Execute the request based on the provided prompt, plan, and context.
- Always provide the full, complete revised content of every file to modify or create.
- HARD CONSTRAINT: NEVER return diffs, git patches, or isolated code chunks. You must output the complete file contents for every file.
]]

-- ===== Config file lookup =====

-- Path of `filename` in the current working directory, or "" when not readable.
local function find_in_cwd(filename)
  local path = vim.fn.getcwd() .. '/' .. filename
  if vim.fn.filereadable(path) == 1 then
    return path
  end
  return ""
end

function aiconfig.findSystemInstructionsFile()
  return find_in_cwd('.ai-system-instructions.md')
end

function aiconfig.findScannedFilesConfig()
  return find_in_cwd('.ai-scanned-files')
end

-- ===== System instructions and prompt builders =====

---@return string
function aiconfig.getSystemInstructions()
  local user_instructions_path = aiconfig.findSystemInstructionsFile()
  local content = ""
  if user_instructions_path ~= "" then
    local lines = vim.fn.readfile(user_instructions_path)
    if lines and #lines > 0 then
      content = table.concat(lines, "\n")
    else
      common.log("Could not read user system instructions or file is empty: " .. user_instructions_path)
    end
  end
  if vim.trim(content) == "" then
    return DEFAULT_SYSTEM_INSTRUCTIONS
  end
  return content
end

---@return string
function aiconfig.getRewordInstructions()
  return REWORD_RULES
end

---@param prompt string|nil
---@return string
function aiconfig.buildPlanPrompt(prompt)
  return (prompt or "") .. "\n\n" .. PLAN_RULES
end

---@param prompt string|nil
---@return string
function aiconfig.buildImplementPrompt(prompt)
  return (prompt or "") .. "\n\n" .. IMPLEMENT_RULES
end

-- ===== Public accessors (currently unused internally) =====

function aiconfig.getPlanInstructions()
  return aiconfig.getSystemInstructions()
end

function aiconfig.getImplementInstructions()
  return aiconfig.getSystemInstructions()
end

function aiconfig.getPlanRules()
  return PLAN_RULES
end

function aiconfig.getImplementRules()
  return IMPLEMENT_RULES
end

function aiconfig.listScannedFilesAsSentence()
  local analyzed_files_as_array = aiconfig.listScannedFilesFromConfig()
  local num_files = #analyzed_files_as_array

  if num_files == 0 then
    return ""
  end

  local file_names = {}
  for _, file in ipairs(analyzed_files_as_array) do
    -- NOTE: produces a literal "%s"; deferred to functional review.
    table.insert(file_names, string.format("`%%s`", file))
  end

  local analyzed_files_as_string = "The project is composed of " .. num_files .. " file" .. (num_files > 1 and "s" or "") .. ": "

  if num_files == 1 then
    analyzed_files_as_string = analyzed_files_as_string .. file_names[1] .. "."
  elseif num_files == 2 then
    analyzed_files_as_string = analyzed_files_as_string .. table.concat(file_names, " and ") .. "."
  else
    analyzed_files_as_string = analyzed_files_as_string .. table.concat(file_names, ", ", 1, num_files - 1) .. ", and " .. file_names[num_files] .. "."
  end

  return analyzed_files_as_string
end

-- ===== Project root =====

-- Ordered marker finders. Each returns a path (or "") whose parent directory
-- is the project root. Note that `.ai-scanned-files` is only looked up in the
-- current working directory, while the others search upward.
local ROOT_MARKER_FINDERS = {
  function() return aiconfig.findScannedFilesConfig() end,
  function() return vim.fn.finddir(".git", ".;") end,
  function() return vim.fn.findfile(".gitignore", ".;") end,
  function() return vim.fn.findfile("README.md", ".;") end,
}

---@return string
function aiconfig.getProjectRoot()
  for _, find_marker in ipairs(ROOT_MARKER_FINDERS) do
    local marker_path = find_marker()
    if marker_path ~= "" then
      return vim.fn.fnamemodify(marker_path, ":h")
    end
  end
  return vim.fn.getcwd()
end

-- ===== Scanned files =====

-- Split config lines into include ('+') and exclude ('-') glob lists.
-- Lines of one character or less are ignored.
local function parse_scan_patterns(lines)
  local include_globs = {}
  local exclude_globs = {}

  for _, line in ipairs(lines) do
    local trimmed_line = vim.trim(line)
    if #trimmed_line > 1 then
      if vim.startswith(trimmed_line, "+") then
        local pattern = trimmed_line:sub(2)
        table.insert(include_globs, pattern)
        common.log("Include glob pattern: " .. pattern)
      elseif vim.startswith(trimmed_line, "-") then
        local pattern = trimmed_line:sub(2)
        table.insert(exclude_globs, pattern)
        common.log("Exclude glob pattern: " .. pattern)
      end
    end
  end

  return include_globs, exclude_globs
end

local function to_lua_patterns(globs)
  local lua_patterns = {}
  for _, glob in ipairs(globs) do
    local lua_pattern = globpattern.globtopattern(glob)
    table.insert(lua_patterns, lua_pattern)
    common.log("Converted exclude glob '" .. glob .. "' to Lua pattern: " .. lua_pattern)
  end
  return lua_patterns
end

local function is_excluded(relative_path, exclude_patterns)
  for _, exclude_pattern in ipairs(exclude_patterns) do
    if string.match(relative_path, exclude_pattern) then
      common.log("File '" .. relative_path .. "' excluded by pattern: " .. exclude_pattern)
      return true
    end
  end
  return false
end

-- Expand include globs under project_root, drop excluded and duplicate files.
-- Returns an array of { path, size } (path relative to project_root).
local function collect_files(project_root, include_globs, exclude_patterns)
  local files = {}
  local seen = {}

  for _, include_glob in ipairs(include_globs) do
    common.log("Processing include glob pattern: " .. include_glob)
    local matches = vim.fn.glob(project_root .. '/' .. include_glob, false, true)

    for _, full_path in ipairs(matches) do
      local relative_path = string.sub(full_path, #project_root + 2)

      if seen[relative_path] then
        common.log("File '" .. relative_path .. "' already processed, skipping duplicate.")
      elseif not is_excluded(relative_path, exclude_patterns) then
        local file_info = vim.loop.fs_stat(full_path)
        if file_info and file_info.type == 'file' then
          table.insert(files, { path = relative_path, size = file_info.size })
          seen[relative_path] = true
          common.log("File '" .. relative_path .. "' included (Size: " .. file_info.size .. ")")
        else
          common.log("Path '" .. relative_path .. "' is not a file or stat failed, skipping.")
        end
      end
    end
  end

  return files
end

--- List the files selected by `.ai-scanned-files`, largest first.
---@return string[] relative paths
function aiconfig.listScannedFilesFromConfig()
  local config_path = aiconfig.findScannedFilesConfig()
  if config_path == "" then
    common.log("No .ai-scanned-files config found.")
    return {}
  end

  common.log("Reading scanned files config: " .. config_path)
  local lines = vim.fn.readfile(config_path)
  if not lines or #lines == 0 then
    common.log("Config file is empty or could not be read: " .. config_path)
    return {}
  end

  local include_globs, exclude_globs = parse_scan_patterns(lines)
  local exclude_patterns = to_lua_patterns(exclude_globs)
  local files = collect_files(aiconfig.getProjectRoot(), include_globs, exclude_patterns)

  table.sort(files, function(a, b)
    return a.size > b.size
  end)

  local paths = {}
  for _, file in ipairs(files) do
    table.insert(paths, file.path)
  end

  common.log("Total included files after filtering and sorting: " .. #paths)
  return paths
end

---@param file_relative_path string
---@return string
function aiconfig.contentOf(file_relative_path)
  local full_path = aiconfig.getProjectRoot() .. '/' .. file_relative_path
  if vim.fn.filereadable(full_path) == 1 then
    local lines = vim.fn.readfile(full_path)
    if lines then
      return table.concat(lines, "\n")
    end
  end
  common.log("Could not read content of: " .. full_path)
  return ""
end

-- ===== Formatted table rendering =====

local function format_size(size)
  if size > 1024 * 1024 then
    return string.format("%.2f MB", size / (1024 * 1024))
  elseif size > 1024 then
    return string.format("%.2f KB", size / 1024)
  else
    return size .. " B"
  end
end

-- Count number of lines in a file. Returns 0 if not readable.
local function count_file_lines(full_path)
  if vim.fn.filereadable(full_path) ~= 1 then
    return 0
  end
  local lines = vim.fn.readfile(full_path)
  if not lines then
    return 0
  end
  return #lines
end

local function pad_right(str, width)
  if #str >= width then
    return str
  end
  return str .. string.rep(" ", width - #str)
end

local function pad_left(str, width)
  if #str >= width then
    return str
  end
  return string.rep(" ", width - #str) .. str
end

-- Render one markdown table line. `aligns[i]` is "left" or "right"; `fill` is
-- the character placed around cells (" " for content rows, "-" for the separator).
local function format_row(cells, widths, aligns, fill)
  local padded = {}
  for i, cell in ipairs(cells) do
    if aligns[i] == "right" then
      padded[i] = pad_left(cell, widths[i])
    else
      padded[i] = pad_right(cell, widths[i])
    end
  end
  return "|" .. fill .. table.concat(padded, fill .. "|" .. fill) .. fill .. "|"
end

local HEADER_CELLS = { "LoC", "Size", "% size", "File name" }
local ROW_ALIGNS = { "right", "right", "right", "left" }
local HEADER_ALIGNS = { "left", "left", "left", "left" }

-- rows: array of { lines_str, size_str, percent_str, name }
local function build_table(title, rows, total_lines, total_size_str)
  local widths = {}
  for i, header in ipairs(HEADER_CELLS) do
    widths[i] = #header
  end

  for _, row in ipairs(rows) do
    widths[1] = math.max(widths[1], #row.lines_str)
    widths[2] = math.max(widths[2], #row.size_str)
    widths[3] = math.max(widths[3], #row.percent_str)
    widths[4] = math.max(widths[4], #row.name)
  end

  -- NOTE: the totals are never rendered as a row; they only affect column widths.
  local total_lines_str = tostring(total_lines)
  local total_label = "Total (" .. total_size_str .. ")"
  widths[1] = math.max(widths[1], #total_lines_str)
  widths[4] = math.max(widths[4], #total_label)

  local separator_cells = {}
  for i, width in ipairs(widths) do
    separator_cells[i] = string.rep("-", width)
  end

  local out = {}
  table.insert(out, "## " .. title .. "\n")
  table.insert(out, format_row(HEADER_CELLS, widths, HEADER_ALIGNS, " "))
  table.insert(out, format_row(separator_cells, widths, HEADER_ALIGNS, "-"))

  for _, row in ipairs(rows) do
    table.insert(out, format_row({ row.lines_str, row.size_str, row.percent_str, row.name }, widths, ROW_ALIGNS, " "))
  end

  return table.concat(out, "\n")
end

local function to_table_rows(files_data)
  local rows = {}
  for _, data in ipairs(files_data) do
    table.insert(rows, {
      lines_str = data.nb_lines_str,
      size_str = data.size_str,
      percent_str = data.percent_str,
      name = data.path,
    })
  end
  return rows
end

---@param scanned_files_paths string[]|nil defaults to the files from `.ai-scanned-files`
---@return string markdown
function aiconfig.listScannedFilesAsFormattedTable(scanned_files_paths)
  local analyzed_files_paths = scanned_files_paths or aiconfig.listScannedFilesFromConfig()
  local project_root = aiconfig.getProjectRoot()

  if #analyzed_files_paths == 0 then
    return "# No files to analyze under project root " .. project_root
  end

  local files_data = {}
  local total_size = 0
  local total_lines = 0

  common.log("Gathering file data for formatted table (size + line counts)")
  for _, relative_path in ipairs(analyzed_files_paths) do
    local full_path = project_root .. '/' .. relative_path
    local stat = vim.loop.fs_stat(full_path)
    local size = stat and stat.size or 0
    local nb_lines = count_file_lines(full_path)
    total_size = total_size + size
    total_lines = total_lines + nb_lines
    table.insert(files_data, {
      path = relative_path,
      size = size,
      size_str = format_size(size),
      nb_lines = nb_lines,
      nb_lines_str = tostring(nb_lines),
    })
    common.log("Processed: " .. relative_path .. " (Size: " .. size .. ", Lines: " .. nb_lines .. ")")
  end

  for _, data in ipairs(files_data) do
    local percent = total_size > 0 and (data.size / total_size * 100) or 0
    data.percent_str = string.format("%.2f%%", percent)
  end

  local total_size_str = format_size(total_size)
  local num_files = #files_data

  -- files_data keeps the input order, which is already sorted by size (descending).
  local rows_by_size = to_table_rows(files_data)

  local sorted_by_name = vim.list_extend({}, files_data)
  table.sort(sorted_by_name, function(a, b) return a.path < b.path end)
  local rows_by_name = to_table_rows(sorted_by_name)

  local result_lines = {}
  table.insert(result_lines,
    "# Scanned files summary\n\n"
    .. "- Project root: `" .. project_root .. "`\n"
    .. "- Number of files: **" .. num_files .. "**\n"
    .. "- Total size: **" .. total_size_str .. "**\n"
    .. "- Total lines: **" .. total_lines .. "**\n")

  table.insert(result_lines, build_table("File list by size (descending)", rows_by_size, total_lines, total_size_str))
  table.insert(result_lines, "")
  table.insert(result_lines, build_table("File list by name (ascending)", rows_by_name, total_lines, total_size_str))

  return table.concat(result_lines, "\n")
end

return aiconfig
