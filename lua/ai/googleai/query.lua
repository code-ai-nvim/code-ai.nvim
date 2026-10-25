local common = require('ai.common')
local provider = require('ai.provider')

local query = {}

-- Valid Google AI thinking levels.
local THINKING_LEVELS = { minimal = true, low = true, medium = true, high = true }

-- Split an optional effort suffix off the model id (see common.splitModelSuffix).
-- Recognized suffixes map to `thinkingConfig.thinkingLevel`. `none` maps to the
-- cheapest valid level (`low` for Gemini 3.7+, otherwise `minimal`).
-- Unrecognized suffixes are passed through so the upstream API can validate them.
local function normalize_model(model)
  local base_model, suffix = common.splitModelSuffix(model)

  if suffix == nil then
    return { model = model }
  end

  if THINKING_LEVELS[suffix] then
    return { model = base_model, thinking_level = suffix }
  elseif suffix == 'none' then
    local is_gemini_37 = base_model:match('3%.7') ~= nil
    return { model = base_model, thinking_level = is_gemini_37 and 'low' or 'minimal' }
  end

  return { model = model }
end

-- Map an ordered conversation ({ role = "user"|"assistant", content = "..." })
-- into the `generateContent` REST API's Content[] shape, mirroring
-- googleai-agent's buildRequestBody():
--   role="user"      -> { role = "user",  parts = [{ text = ... }] }
--   role="assistant" -> { role = "model", parts = [{ text = ... }] }
local function messages_to_contents(messages)
  local contents = {}
  for _, message in ipairs(messages or {}) do
    local role = (message.role == 'user') and 'user' or 'model'
    table.insert(contents, {
      role = role,
      parts = { { text = message.content } },
    })
  end
  return contents
end

-- Error text shown in the popup. The leading "\n#GoogleAI error" form is
-- intentional (it is matched by the generic error heuristic).
local function googleai_error(body)
  return '\n#GoogleAI error\n\n' .. body .. '\n'
end

local function first_candidate(data)
  return (data['candidates'] or {})[1]
end

-- Parts of the first candidate's content, or nil when absent.
local function first_candidate_parts(data)
  local candidate = first_candidate(data)
  if not candidate or not candidate.content then
    return nil
  end
  return candidate.content.parts
end

local googleai_runner = provider.createQueryRunner({
  name = "GoogleAI",
  title_tag = "GGL",
  history_prefix = "googleai_",
  api_host = 'https://aiplatform.googleapis.com',
  disabled_response = {
    candidates = { { content = { role = "model", parts = { { text = "GoogleAI models are disabled" } } } } },
    usageMetadata = { promptTokenCount = 0, candidatesTokenCount = 0 }
  },
  -- `generateContent` authenticates via the `key` query parameter (see
  -- build_url), so no API-key header is needed.
  build_headers = function()
    return {
      ['Content-type'] = 'application/json',
    }
  end,
  -- The model id and API key live in the URL, so no static `api_path` is used.
  -- POST {api_host}/v1/publishers/google/models/{model}:generateContent?key={api_key}
  build_url = function(api_host, api_key, model)
    local normalized = normalize_model(model)
    return api_host .. '/v1/publishers/google/models/' .. normalized.model .. ':generateContent?key=' .. api_key
  end,
  -- `messages` (from ai.conversation.build()) is converted to the API's
  -- Content[] shape, matching what googleai-agent's buildRequestBody() sends.
  build_request_body = function(model, instruction, messages)
    local normalized = normalize_model(model)

    local request_body = {
      contents = messages_to_contents(messages),
      generationConfig = {
        temperature = 0.2,
        topP = 0.5
      }
    }

    if normalized.thinking_level then
      request_body.generationConfig.thinkingConfig = { thinkingLevel = normalized.thinking_level }
    end

    if instruction and instruction ~= '' then
      request_body.systemInstruction = { parts = { { text = instruction } } }
    end
    return request_body
  end,
  validate_data = function(data)
    local candidates = data['candidates']
    if candidates == nil or #candidates == 0 then
      if data['promptFeedback'] and data['promptFeedback']['blockReason'] then
        local reason = data['promptFeedback']['blockReason']
        local message = data['promptFeedback']['blockReasonMessage'] or ''
        local details = message ~= '' and ('\n\n' .. message) or ''
        return googleai_error('Prompt blocked. Reason: ' .. reason .. details)
      elseif data['error'] then
        return googleai_error('GoogleAI stopped with the reason: ' .. (data['error']['message'] or 'unknown'))
      else
        return googleai_error('Unknown error or empty response.')
      end
    end

    local parts = first_candidate_parts(data)
    if not parts or #parts == 0 then
      local candidate = first_candidate(data)
      if candidate and candidate.finishReason and candidate.finishReason ~= 'STOP' then
        return googleai_error('Generation stopped with reason: ' .. candidate.finishReason)
      end
      return googleai_error('No model output found.')
    end

    return nil
  end,
  extract_usage = function(data)
    local usage = data.usageMetadata or {}
    return usage.promptTokenCount or 0, usage.candidatesTokenCount or 0
  end,
  extract_content = function(data)
    local parts = first_candidate_parts(data)
    if not parts then
      return ""
    end

    local texts = {}
    for _, part in ipairs(parts) do
      if part.text then
        table.insert(texts, part.text)
      end
    end
    return table.concat(texts, "")
  end,
  format_error = function(status, body)
    common.log("Formatting GoogleAI API error: " .. body)
    local success, error_data = pcall(vim.fn.json_decode, body)

    if success and error_data and error_data.error then
      local error_code = error_data.error.code or status
      local error_message = error_data.error.message or "Unknown error occurred"
      local error_status = error_data.error.status or "ERROR"
      return string.format(
        "# GoogleAI API Error (%s)\n\n**Error Code**: %s\n**Status**: %s\n**Message**: %s\n",
        status,
        error_code,
        error_status,
        error_message
      )
    else
      return string.format("# GoogleAI API Error (%s)\n\n```\n%s\n```", status, body)
    end
  end
})

query.askHeavy = googleai_runner.askHeavy
query.askLight = googleai_runner.askLight

return query
