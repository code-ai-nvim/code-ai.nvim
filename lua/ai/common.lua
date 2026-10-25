local curl = require('plenary.curl')

local common = {}

-- ===== Constants =====

local SUPPORTED_PROVIDERS = { anthropic = true, googleai = true, openai = true }
local TASKS = { 'plan', 'implement', 'reword' }
local IS_TASK = {}
for _, task in ipairs(TASKS) do
  IS_TASK[task] = true
end

local LOG_PATH = "/tmp/aiconfig.log"
local STATS_INGESTION_URL = "https://token-loc-size.m-rktmb.ovh/inject.php"
local UPLOAD_TIMEOUT_MS = 500000
local AGENT_CHUNK_TIMEOUT_MS = 30000
local AGENT_ERROR_PREFIX = "# Agent Error"

--- Prefix used for every error string produced by the agent transport layer.
common.AGENT_ERROR_PREFIX = AGENT_ERROR_PREFIX

-- ===== Logging =====

---@param message string
function common.log(message)
  local timestamp = os.date("%Y-%m-%d %H:%M:%S")
  local full_log_message = "[ " .. timestamp .. " ] -- " .. message .. "\n"

  local file, err = io.open(LOG_PATH, "a")
  if not file then
    pcall(function()
      vim.api.nvim_echo({ { "Error: Could not open log file: " .. LOG_PATH .. " - " .. (err or "unknown error"), "ErrorMsg" } }, false, {})
    end)
    return
  end

  file:write(full_log_message)
  file:close()
end

-- NOTE: this wrapper uses `vim.json.encode`, whereas other call sites use
-- `vim.fn.json_encode`. They differ on edge cases (e.g. empty tables, escaping);
-- deliberately not unified here, deferred to a functional review.
local function json_encode(v)
  return vim.json.encode(v)
end

-- ===== Model specs =====

--- Split a model id of the form '<base>:<suffix>' into its base and effort suffix.
--- Effort levels are treated uniformly across providers: the caller keeps the base
--- model id and maps the suffix to its provider's API field when it recognizes it.
--- Models without a suffix are returned unchanged so that the upstream API can
--- validate model existence.
---@param model string
---@return string base, string|nil suffix
function common.splitModelSuffix(model)
  local base, suffix = model:match('^(.+):(.+)$')
  if base and suffix then
    return base, suffix
  end
  return model, nil
end

--- Parse a model spec in '<provider>/<model>' format (e.g. 'anthropic/claude-sonnet-5:high').
---@param spec string
---@return table|nil parsed { provider, model, full }
---@return string|nil error_message
function common.parseModelSpec(spec)
  if type(spec) ~= 'string' or spec == '' then
    return nil, "Model specification must be a non-empty string"
  end

  local provider, model = spec:match('^([^/]+)/(.+)$')
  if not provider or not model or model == '' then
    return nil, string.format("Invalid model format '%s'. Expected '<provider>/<model>' (e.g. 'anthropic/claude-sonnet-5:high')", spec)
  end

  provider = provider:lower()
  if not SUPPORTED_PROVIDERS[provider] then
    return nil, string.format("Unsupported provider '%s' in model '%s'. Valid providers are 'anthropic', 'googleai', 'openai'.", provider, spec)
  end

  return {
    provider = provider,
    model = model,
    full = spec,
  }
end

-- Extract { plan, implement, reword } from either a flat table
-- ({ plan = ..., implement = ... }) or an array of single-task tables
-- ({ { plan = ... }, { implement = ... } }). Array entries override flat keys.
local function extract_task_models(models)
  local extracted = {}
  if type(models) ~= 'table' then
    return extracted
  end

  for _, task in ipairs(TASKS) do
    if models[task] ~= nil then
      extracted[task] = models[task]
    end
  end

  for _, entry in ipairs(models) do
    if type(entry) == 'table' then
      for key, value in pairs(entry) do
        if IS_TASK[key] and value ~= nil then
          extracted[key] = value
        end
      end
    end
  end

  return extracted
end

--- Resolve models for the plan, implement and reword tasks.
--- Prompt-level definitions take precedence over global ones. Empty strings and
--- 'disabled' are treated as nil, meaning the task is skipped.
---@param prompt_models table|nil
---@param global_models table|nil
---@return table<string, string|nil>
function common.resolveTaskModels(prompt_models, global_models)
  local global_extracted = extract_task_models(global_models)
  local prompt_extracted = extract_task_models(prompt_models)

  local final_models = {}
  for _, task in ipairs(TASKS) do
    local value = prompt_extracted[task]
    if value == nil then
      value = global_extracted[task]
    end
    if type(value) == 'string' and (value == '' or value == 'disabled') then
      value = nil
    end
    final_models[task] = value
  end

  return final_models
end

-- ===== Response handling =====

-- Heuristic: a markdown error title ("# ... error") or a plain "Error:" prefix.
local function looks_like_error(result)
  return result:match('^%s*#.*[Ee]rror') ~= nil or result:match('^Error:') ~= nil
end

-- Build the user-facing text for a non-200 HTTP response.
local function decode_error_result(res, opts)
  local body_text = res.body or "No response body"
  if opts.handleError ~= nil then
    return opts.handleError(res.status, body_text)
  end
  common.log("Error: API responded with the status " .. tostring(res.status) .. '\n\n' .. body_text)
  return 'Error: API responded with the status ' .. tostring(res.status) .. '\n\n' .. body_text
end

-- Turn an HTTP response into (result_text, is_error).
local function build_result(res, opts, formatResult)
  if res.status ~= 200 then
    return decode_error_result(res, opts), true
  end

  local success, data = pcall(vim.fn.json_decode, res.body)
  if not success then
    common.log("Error: Failed to decode JSON response: " .. (res.body or "No response body"))
    return "Error: Failed to decode JSON response from agent.", true
  end

  local formatted, err_flag = formatResult(data, opts.upload_url, opts.upload_token, opts.upload_as_public, opts)
  if err_flag ~= nil then
    return formatted, err_flag
  end
  return formatted, type(formatted) == 'string' and looks_like_error(formatted)
end

---@param res table HTTP response ({ status, body })
---@param opts table { handleError?, handleResult?, callback?, upload_url, upload_token, upload_as_public, stats?, raw_output? }
---@param formatResult function(data, upload_url, upload_token, upload_as_public, opts) -> string, boolean|nil
function common.askCallback(res, opts, formatResult)
  local result, is_error = build_result(res, opts, formatResult)

  if opts.handleResult ~= nil then
    result = opts.handleResult(result)
  end

  if opts.callback ~= nil then
    opts.callback(result, is_error)
  end
end

--- Answer as if the (disabled) model had returned `disabled_response`.
---@param opts table
---@param askCallback function(res, opts)
---@param disabled_response table
function common.handleDisabledModel(opts, askCallback, disabled_response)
  vim.schedule(function()
    askCallback(
      { status = 200, body = json_encode(disabled_response) },
      {
        handleResult = opts.handleResult,
        callback = opts.callback,
        upload_url = opts.upload_url or '',
        upload_token = opts.upload_token or '',
        upload_as_public = opts.upload_as_public or false,
        raw_output = opts.raw_output,
      }
    )
  end)
end

-- ===== Formatting helpers =====

--- Insert a word right after the leading '# ' of the first line (or create a title).
---@param word_to_insert string
---@param text string
---@return string
function common.insertWordToTitle(word_to_insert, text)
  local lines = vim.split(text, '\n', { plain = true })
  if #lines == 0 then
    return text
  end

  if lines[1]:sub(1, 1) == '#' then
    lines[1] = lines[1]:gsub('^# ', '# ' .. word_to_insert .. ' ')
  else
    lines[1] = '# ' .. word_to_insert .. ' ' .. lines[1]
  end

  return table.concat(lines, '\n')
end

---@param count number|string
---@return string
function common.formatTokenCount(count)
  if type(count) ~= 'number' then
    count = tonumber(count) or 0
  end

  if count >= 1000 then
    local value = count / 1000
    if value >= 100 then
      return string.format("%.0fk", value)
    elseif value >= 10 then
      return string.format("%.1fk", value)
    else
      return string.format("%.2fk", value)
    end
  end
  return tostring(count)
end

--- Calculate input statistics (size in bytes and total line count).
---@param instruction string|nil
---@param prompt string|nil
---@param project_context table[]|nil array of { filename, content }
---@return number total_size, number total_lines
function common.calculateInputStats(instruction, prompt, project_context)
  local total_size = 0
  local total_lines = 0

  local function add_text(text)
    if type(text) == 'string' and text ~= '' then
      total_size = total_size + #text
      local _, count = string.gsub(text, "\n", "")
      if not string.match(text, "\n$") and #text > 0 then
        count = count + 1
      end
      total_lines = total_lines + count
    end
  end

  add_text(instruction)
  add_text(prompt)

  if project_context then
    for _, file in ipairs(project_context) do
      add_text(file.content)
    end
  end

  return total_size, total_lines
end

-- ===== Upload and stats =====

local function build_upload_headers(token, is_public, model_name)
  local headers = {
    ['Content-Type'] = 'text/markdown',
    ['X-MarkdownBlog-Token'] = token
  }
  if is_public == true then
    headers['X-MarkdownBlog-Public'] = 'true'
    common.log("Setting upload as public for " .. model_name)
  end
  return headers
end

---@param url string
---@param token string
---@param content string
---@param model_name string
---@param is_public boolean|nil
function common.uploadContent(url, token, content, model_name, is_public)
  if url == '' or token == '' then
    common.log("Upload URL or Token not configured. Skipping upload for " .. model_name .. " response.")
    return
  end

  if model_name == 'disabled' then
    common.log("Model is disabled. Skipping upload.")
    return
  end

  common.log("Attempting to upload " .. model_name .. " response to: " .. url)
  local headers = build_upload_headers(token, is_public, model_name)

  common.log("Uploading content for model: " .. model_name)
  curl.put(url,
    {
      headers = headers,
      body = content,
      timeout = UPLOAD_TIMEOUT_MS,
      callback = function(res)
        if res.status >= 200 and res.status < 300 then
          common.log("Successfully uploaded " .. model_name .. " response. Status: " .. res.status)
        else
          common.log("Failed to upload " .. model_name .. " response. Status: " .. res.status .. ", Body: " .. (res.body or "No response body"))
        end
      end
    })
end

-- Consume the per-request fields of `stats` (clearing them to avoid stale data)
-- and build the ingestion payload.
local function build_stats_payload(stats, input_tokens, output_tokens)
  local model = stats.model
  local input_size = stats.input_size
  local input_lines = stats.input_lines

  stats.model = nil
  stats.input_size = nil
  stats.input_lines = nil

  return {
    model = tostring(model or ""),
    input_size = math.floor(tonumber(input_size) or 0),
    input_lines = math.floor(tonumber(input_lines) or 0),
    input_tokens = math.floor(tonumber(input_tokens) or 0),
    output_tokens = math.floor(tonumber(output_tokens) or 0),
  }
end

--- Send token statistics to the ingestion endpoint.
---@param stats table { model, input_size, input_lines } (cleared by this call)
---@param input_tokens number
---@param output_tokens number
function common.sendIngestionStats(stats, input_tokens, output_tokens)
  -- Required lazily: 'ai' requires this module at load time, so a top-level
  -- require would be circular.
  local ai = require('ai')
  local token = ai.opts.stats_ingestion_token or ""

  if token == "" then
    common.log("sendIngestionStats: stats_ingestion_token is not configured. Skipping sending stats.")
    return
  end

  local payload = build_stats_payload(stats, input_tokens, output_tokens)

  if payload.model == "" or string.match(payload.model, "^%s*$") then
    common.log("sendIngestionStats: Skipping sending stats because model name is empty.")
    return
  end

  common.log("sendIngestionStats: Sending token stats to " .. STATS_INGESTION_URL .. ": " .. vim.fn.json_encode(payload))

  curl.post(STATS_INGESTION_URL, {
    headers = {
      ['Content-Type'] = 'application/json',
      ['Authorization'] = 'Bearer ' .. token,
    },
    body = vim.fn.json_encode(payload),
    callback = function(res)
      if res.status >= 200 and res.status < 300 then
        common.log("sendIngestionStats: Successfully sent token stats. Status: " .. res.status .. ", Response: " .. (res.body or ""))
      else
        common.log("sendIngestionStats: Failed to send token stats. Status: " .. tostring(res.status) .. ", Response: " .. (res.body or ""))
      end
    end
  })
end

-- ===== Agent transport (askHeavy) =====

-- Build the ordered list of chunks sent to the agent. The order is part of the
-- agent protocol: credentials/config first, then files, and finally the prompt,
-- whose arrival triggers the LLM call.
local function build_agent_chunks(api_key, instruction, model, project_context, prompt)
  local chunks = {}

  table.insert(chunks, { type = 'api key', text = api_key })
  table.insert(chunks, { type = 'system instructions', text = instruction })
  table.insert(chunks, { type = 'model', text = model })

  for _, context in pairs(project_context) do
    if context.content ~= nil then
      table.insert(chunks, { type = 'file', filename = context.filename, content = context.content })
    end
  end

  table.insert(chunks, { type = 'prompt', text = prompt })
  return chunks
end

local function chunk_label(chunk)
  if chunk.type == 'file' then
    return chunk.type .. ':' .. (chunk.filename or 'unknown')
  end
  return chunk.type
end

-- First `max_len` characters of a response body, with an ellipsis when truncated.
local function preview_body(body, max_len)
  if not body or #body == 0 then
    return ''
  end
  local preview = string.sub(body, 1, max_len)
  if #body > max_len then
    preview = preview .. '...'
  end
  return preview
end

-- Human-readable message for a chunk the agent refused to store.
local function format_chunk_failure(chunk, index, total, status, body)
  local error_details = body or "No response body"
  local parsed_ok, error_data = pcall(vim.fn.json_decode, body)
  if parsed_ok and error_data and error_data.error then
    error_details = error_data.error
  end

  if chunk.type == 'file' then
    return string.format(
      "Failed to upload file '%s' (chunk %d/%d). Agent returned status %s.\n\nError: %s\n\nThis file may be empty or have invalid content.",
      chunk.filename or 'unknown',
      index,
      total,
      status,
      error_details
    )
  end

  return string.format(
    "Failed to store %s (chunk %d/%d). Agent returned status %s.\n\nError: %s",
    chunk_label(chunk),
    index,
    total,
    status,
    error_details
  )
end

--- Send the conversation context to the agent, one chunk at a time, then process
--- the LLM response returned for the final (prompt) chunk.
---@param agent_host string
---@param api_key string
---@param model string
---@param instruction string
---@param prompt string
---@param project_context table[] array of { filename, content }
---@param opts table callback options (see common.askCallback)
---@param askCallback function(res, opts)
function common.askHeavy(agent_host, api_key, model, instruction, prompt, project_context, opts, askCallback)
  local url = agent_host .. '/'
  local chunks = build_agent_chunks(api_key, instruction, model, project_context, prompt)
  local total_chunks = #chunks
  local current_index = 0
  local failed = false

  common.log(string.format("askHeavy: Starting to send %d chunks to %s", total_chunks, url))

  -- `kind` only labels the log line ("ERROR" or "EXCEPTION").
  local function fail(kind, message)
    failed = true
    common.log("askHeavy: " .. kind .. " - " .. message)
    vim.schedule(function()
      opts.callback(AGENT_ERROR_PREFIX .. "\n\n" .. message, true)
    end)
  end

  local function sendNextChunk()
    if failed then
      common.log("askHeavy: Skipping chunk sending due to previous failure")
      return
    end

    current_index = current_index + 1

    if current_index > total_chunks then
      common.log("askHeavy: All chunks sent successfully")
      return
    end

    local index = current_index
    local chunk = chunks[index]
    local is_last = (index == total_chunks)
    local label = chunk_label(chunk)

    common.log(string.format("askHeavy: Sending chunk %d/%d: %s", index, total_chunks, label))

    -- pcall catches synchronous errors raised by curl.post
    local success, err = pcall(function()
      curl.post(url, {
        headers = { ['Content-type'] = 'application/json' },
        body = json_encode(chunk),
        timeout = AGENT_CHUNK_TIMEOUT_MS,
        callback = function(res)
          local status = res.status or 'nil'
          common.log(string.format("askHeavy: Received response for chunk %d/%d (%s): status=%s, body=%s",
            index, total_chunks, label, tostring(status), preview_body(res.body, 100)))

          if res.status ~= 200 then
            fail("ERROR", format_chunk_failure(chunk, index, total_chunks, tostring(status), res.body))
            return
          end

          if is_last then
            common.log("askHeavy: Final chunk (prompt) processed successfully, invoking askCallback")
            vim.schedule(function()
              askCallback(res, {
                handleResult = opts.handleResult,
                callback = opts.callback,
                upload_url = opts.upload_url,
                upload_token = opts.upload_token,
                upload_as_public = opts.upload_as_public,
                stats = opts.stats,
                raw_output = opts.raw_output,
              })
            end)
          else
            common.log(string.format("askHeavy: Scheduling next chunk %d/%d", index + 1, total_chunks))
            vim.schedule(sendNextChunk)
          end
        end
      })
    end)

    if not success then
      fail("EXCEPTION", string.format("Exception while sending chunk %d/%d (%s): %s",
        index, total_chunks, label, tostring(err)))
    end
  end

  vim.schedule(sendNextChunk)
end

return common
