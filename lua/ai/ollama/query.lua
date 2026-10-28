local common = require('ai.common')
local conversation = require('ai.conversation')
local client = require('ai.ollama.client')

local query = {}

local LOCAL_TEMPERATURE = 0.2

local function is_empty(value)
  return value == nil or value == ''
end

-- Remove <think>...</think> blocks emitted by reasoning models, then trim.
local function clean_output(text)
  local stripped = text:gsub('<think>.-</think>', '')
  return vim.trim(stripped)
end

--- Light-mode query against the local Ollama server. Mirrors provider.askLight
--- from the pipeline's point of view: `opts.handleResult(text)` is applied if
--- set, then `opts.callback(result, is_error)` is called.
--- Stats, history and upload are intentionally not performed for local models.
---@param model string
---@param instruction string|nil
---@param prompt string
---@param opts table { handleResult?, callback? }
---@param host string
function query.askLight(model, instruction, prompt, opts, host)
  if is_empty(host) or is_empty(model) then
    local message = "# Ollama Error\n\nOllama host or model is not configured. Set `ollama_host` and `ollama_model`."
    common.log("Ollama askLight aborted: host or model is not configured.")
    if opts.callback ~= nil then
      vim.schedule(function()
        opts.callback(message, true)
      end)
    end
    return
  end

  local messages = {}
  if not is_empty(instruction) then
    table.insert(messages, { role = 'system', content = instruction })
  end
  for _, message in ipairs(conversation.build(prompt, nil)) do
    table.insert(messages, message)
  end

  common.log("Ollama askLight: stats, history and upload are skipped for local models.")

  local function on_done(text, is_error)
    local result = text
    if not is_error then
      result = clean_output(text)
      if result == '' then
        result = string.format("# Ollama Error\n\nOllama model '%s' returned an empty response.", model)
        is_error = true
      end
    end

    if opts.handleResult ~= nil then
      result = opts.handleResult(result)
    end

    if opts.callback ~= nil then
      opts.callback(result, is_error)
    end
  end

  client.chat(host, model, messages, on_done, { temperature = LOCAL_TEMPERATURE })
end

return query

