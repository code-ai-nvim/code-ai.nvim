local history = {}
local aiconfig = require('ai.aiconfig')
local common = require('ai.common')

local HISTORY_DIR_NAME = '.ai-history'
local MAX_HISTORY_FILES = 15

local function history_dir()
  return aiconfig.getProjectRoot() .. '/' .. HISTORY_DIR_NAME
end

-- Model ids may contain ':' and '/', which are unsafe in file names.
local function sanitize_model_name(model)
  return (string.gsub(model, "[:/]", "_"))
end

--- Create the history directory under the project root if it doesn't exist.
function history.createHistoryDir()
  local dir = history_dir()
  common.log("Checking if history directory exists: " .. dir)
  if vim.fn.isdirectory(dir) ~= 1 then
    vim.fn.mkdir(dir, 'p')
    common.log("Created history directory: " .. dir)
  end
end

---@param model string
---@param content string
---@return string|nil path of the written file, nil on failure
function history.saveToHistory(model, content)
  common.log("Saving history to " .. model .. " history file")
  history.createHistoryDir()
  common.log("Creating history file for " .. model)
  -- Two-digit year ("%y"): the century is not needed in file names.
  local file_name = os.date("%y%m%d%Hh%Mm%Ss") .. "_" .. sanitize_model_name(model) .. ".md"
  local file_path = history_dir() .. '/' .. file_name

  common.log("Writing to history file: " .. file_path)
  -- vim.split keeps empty lines, which preserves the Markdown spacing.
  local lines_to_write = vim.split(content, '\n')

  if vim.fn.writefile(lines_to_write, file_path) == 0 then
    common.log("Successfully wrote history file: " .. file_path)
    history.removeOldestHistoryFiles(MAX_HISTORY_FILES)
    return file_path
  else
    common.log("Failed to write history file: " .. file_path)
    return nil
  end
end

--- List files in the history directory, ordered by file name (oldest first).
---@return string[]
function history.listHistoryFiles()
  local dir = history_dir()
  if vim.fn.isdirectory(dir) ~= 1 then
    common.log("History directory does not exist: " .. dir)
    return {}
  end
  local files = vim.fn.readdir(dir)
  table.sort(files)
  return files
end

--- Remove the oldest history files, keeping only the most recent ones.
---@param numberOfFilesToKeep number
function history.removeOldestHistoryFiles(numberOfFilesToKeep)
  local dir = history_dir()
  local files = history.listHistoryFiles()

  if #files == 0 and vim.fn.isdirectory(dir) ~= 1 then
    -- listHistoryFiles already logged that the directory doesn't exist.
    return
  end

  common.log("Files in history folder (" .. #files .. " total):")
  for i, file in ipairs(files) do
    common.log("File " .. i .. ": " .. file)
  end

  local files_to_remove_count = #files - numberOfFilesToKeep
  if files_to_remove_count > 0 then
    common.log(string.format("Need to remove %d oldest files to keep %d.", files_to_remove_count, numberOfFilesToKeep))
    -- Names sort chronologically, so the oldest files come first.
    for i = 1, files_to_remove_count do
      local file_path = dir .. '/' .. files[i]
      if vim.fn.delete(file_path) == 0 then
        common.log("Deleted oldest history file: " .. file_path)
      else
        common.log("Failed to delete history file: " .. file_path)
      end
    end
  else
    common.log("No old history files to remove (found " .. #files .. ", keeping " .. numberOfFilesToKeep .. ").")
  end
end

return history
