local common = require('ai.common')
local provider = require('ai.provider')

local query = {}

-- Normalize a "gemini-3.[567]-flash" model name that may carry a thinking-level suffix
-- (e.g. "gemini-3.5-flash-minimal", "gemini-3.6-flash-medium", "gemini-3.7-flash-high").
-- Mirrors the logic implemented in code-ai-agent/googleai-agent/src/main.ts
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

  return { model = 'gemini-' .. version .. '-flash', thinking_level = level }
end

-- Map an ordered conversation ({ role = "user"|"assistant", content = "..." })
-- into GoogleAI's Step[] shape, mirroring googleai-agent's buildRequestBody():
--   role="user"      -> { type = "user_input",  content = [{ type = "text", text = ... }] }
--   role="assistant" -> { type = "model_output", content = [{ type = "text", text = ... }] }
local function messagesToSteps(messages)
  local steps = {}
  for _, message in ipairs(messages or {}) do
    local step_type = (message.role == 'user') and 'user_input' or 'model_output'
    table.insert(steps, {
      type = step_type,
      content = { { type = 'text', text = message.content } },
    })
  end
  return steps
end

local googleai_runner = provider.createQueryRunner({
  name = "GoogleAI",
  title_tag = "GGL",
  history_prefix = "googleai_",
  api_host = 'https://generativelanguage.googleapis.com',
  api_path = '/v1beta/interactions',
  disabled_response = {
    steps = { { type = "model_output", content = { { text = "GoogleAI models are disabled" } } } },
    usage = { total_input_tokens = 0, total_output_tokens = 0 }
  },
  build_headers = function(api_key)
    return {
      ['Content-type'] = 'application/json',
      ['x-goog-api-key'] = api_key
    }
  end,
  -- `messages` is an ordered array of { role = "user"|"assistant", content = "..." }
  -- built by ai.conversation.build(). We convert it to GoogleAI's Step[] input shape,
  -- matching wire-for-wire what googleai-agent's buildRequestBody() sends today.
  build_request_body = function(model, instruction, messages)
    local normalized = normalizeGeminiFlashModel(model)

    local request_body = {
      model = normalized.model,
      input = messagesToSteps(messages),
      generation_config = {
        temperature = 0.2,
        top_p = 0.5
      }
    }

    if normalized.thinking_level then
      request_body.generation_config.thinking_level = normalized.thinking_level
    end

    if instruction and instruction ~= '' then
      request_body.system_instruction = instruction
    end
    return request_body
  end,
  validate_data = function(data)
    local steps = data['steps']
    if steps == nil or #steps == 0 then
      if data['error'] then
        return '\n#GoogleAI error\n\nGoogleAI stopped with the reason: '
          .. (data['error']['message'] or 'unknown') .. '\n'
      else
        return '\n#GoogleAI error\n\nUnknown error or empty response.\n'
      end
    end

    local last_output = nil
    for i = #steps, 1, -1 do
      if steps[i].type == "model_output" then
        last_output = steps[i]
        break
      end
    end

    if not last_output or not last_output.content or #last_output.content == 0 then
      return '\n#GoogleAI error\n\nNo model output found.\n'
    end

    return nil
  end,
  extract_usage = function(data)
    local usage = data.usage or {}
    return usage.total_input_tokens or 0, usage.total_output_tokens or 0
  end,
  extract_content = function(data)
    local steps = data['steps'] or {}
    for i = #steps, 1, -1 do
      if steps[i].type == "model_output" and steps[i].content and steps[i].content[1] then
        return steps[i].content[1].text or ""
      end
    end
    return ""
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

