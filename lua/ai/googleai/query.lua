local common = require('ai.common')
local provider = require('ai.provider')

local query = {}

-- Normalize a "gemini-3.[567]-flash" model name that may carry a thinking-level suffix
-- (e.g. "gemini-3.5-flash-minimal", "gemini-3.6-flash-medium", "gemini-3.7-flash-high").
-- Mirrors the logic implemented in code-ai-agent/googleai-agent/src/main.ts
-- The returned `model` field is also the bare model id used to build the
-- `:generateContent` REST endpoint URL.
local function normalizeGeminiFlashModel(model)
  local version, level

  version, level = model:match('^gemini%-(3%.[567])%-flash%-(minimal)$')
  if not version then version, level = model:match('^gemini%-(3%.[567])%-flash%-(low)$') end
  if not version then version, level = model:match('^gemini%-(3%.[567])%-flash%-(medium)$') end
  if not version then version, level = model:match('^gemini%-(3%.[567])%-flash%-(high)$') end

  if not version then
    -- No suffix: still normalize if it matches the base pattern, defaulting to 'low'
    version = model:match('^gemini%-(3%.[567])%-flash$')
    level = version and 'low' or nil
  end

  if not version then
    return { model = model }
  end

  if version == '3.7' and level == 'minimal' then
    level = 'low'
  end

  return { model = 'gemini-' .. version .. '-flash', thinking_level = level }
end

-- Map an ordered conversation ({ role = "user"|"assistant", content = "..." })
-- into the `generateContent` REST API's Content[] shape, mirroring
-- googleai-agent's buildRequestBody():
--   role="user"      -> { role = "user",  parts = [{ text = ... }] }
--   role="assistant" -> { role = "model", parts = [{ text = ... }] }
local function messagesToContents(messages)
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

local googleai_runner = provider.createQueryRunner({
  name = "GoogleAI",
  title_tag = "GGL",
  history_prefix = "googleai_",
  api_host = 'https://aiplatform.googleapis.com',
  disabled_response = {
    candidates = { { content = { role = "model", parts = { { text = "GoogleAI models are disabled" } } } } },
    usageMetadata = { promptTokenCount = 0, candidatesTokenCount = 0 }
  },
  -- The `generateContent` method authenticates via the `key` query parameter
  -- (see build_url below), so no API-key header is needed here.
  build_headers = function()
    return {
      ['Content-type'] = 'application/json',
    }
  end,
  -- The `generateContent` method takes the model id and the API key directly
  -- in the URL, instead of a fixed path + header, so we build the full
  -- request URL here rather than relying on a static `api_path`.
  -- Mirrors: POST {api_host}/v1/publishers/google/models/{model}:generateContent?key={api_key}
  build_url = function(api_host, api_key, model)
    local normalized = normalizeGeminiFlashModel(model)
    return api_host .. '/v1/publishers/google/models/' .. normalized.model .. ':generateContent?key=' .. api_key
  end,
  -- `messages` is an ordered array of { role = "user"|"assistant", content = "..." }
  -- built by ai.conversation.build(). We convert it to the `generateContent` API's
  -- Content[] input shape, matching wire-for-wire what googleai-agent's
  -- buildRequestBody() sends today.
  build_request_body = function(model, instruction, messages)
    local normalized = normalizeGeminiFlashModel(model)

    local request_body = {
      contents = messagesToContents(messages),
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
        return '\n#GoogleAI error\n\nPrompt blocked. Reason: ' .. reason .. details .. '\n'
      elseif data['error'] then
        return '\n#GoogleAI error\n\nGoogleAI stopped with the reason: '
          .. (data['error']['message'] or 'unknown') .. '\n'
      else
        return '\n#GoogleAI error\n\nUnknown error or empty response.\n'
      end
    end

    local first_candidate = candidates[1]
    if not first_candidate or not first_candidate.content or not first_candidate.content.parts or #first_candidate.content.parts == 0 then
      if first_candidate and first_candidate.finishReason and first_candidate.finishReason ~= 'STOP' then
        return '\n#GoogleAI error\n\nGeneration stopped with reason: ' .. first_candidate.finishReason .. '\n'
      end
      return '\n#GoogleAI error\n\nNo model output found.\n'
    end

    return nil
  end,
  extract_usage = function(data)
    local usage = data.usageMetadata or {}
    return usage.promptTokenCount or 0, usage.candidatesTokenCount or 0
  end,
  extract_content = function(data)
    local candidates = data['candidates'] or {}
    local first_candidate = candidates[1]
    if not first_candidate or not first_candidate.content or not first_candidate.content.parts then
      return ""
    end

    local texts = {}
    for _, part in ipairs(first_candidate.content.parts) do
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

function query.askHeavy(model, instruction, prompt, opts, api_key, agent_host, upload_url, upload_token, upload_as_public, scanned_files)
  googleai_runner.askHeavy(model, instruction, prompt, opts, api_key, agent_host, upload_url, upload_token, upload_as_public, scanned_files)
end

function query.askLight(model, instruction, prompt, opts, api_key, upload_url, upload_token, upload_as_public, scanned_files)
  googleai_runner.askLight(model, instruction, prompt, opts, api_key, upload_url, upload_token, upload_as_public, scanned_files)
end

return query

