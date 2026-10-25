local common = require('ai.common')
local provider = require('ai.provider')

local query = {}

-- Valid OpenAI `reasoning.effort` values (`none` only where the model supports it).
local REASONING_EFFORTS = { low = true, medium = true, high = true, xhigh = true, max = true, none = true }

-- Split an optional effort suffix off the model id (see common.splitModelSuffix).
-- Recognized suffixes map to `reasoning.effort`. Unrecognized suffixes are passed
-- through so the upstream API can validate them.
local function normalize_model(model)
  local base_model, suffix = common.splitModelSuffix(model)

  if suffix ~= nil and REASONING_EFFORTS[suffix] then
    return { model = base_model, reasoning_effort = suffix }
  end

  return { model = model }
end

-- Append `value` to `out` when it is a non-empty string.
local function append_text(out, value)
  if type(value) == 'string' and value ~= '' then
    table.insert(out, value)
  end
end

-- Parts may be tables ({ text } or { value }) or bare strings.
local function append_content_parts(out, content)
  for _, part in ipairs(content) do
    if type(part) == 'table' then
      append_text(out, part.text or part.value)
    else
      append_text(out, part)
    end
  end
end

local function append_output_item(out, item)
  if type(item) ~= 'table' then
    append_text(out, item)
    return
  end

  append_text(out, item.text)
  if type(item.content) == 'table' then
    append_content_parts(out, item.content)
  else
    append_text(out, item.content)
  end
end

local openai_runner = provider.createQueryRunner({
  name = "OpenAI",
  title_tag = "OPN",
  history_prefix = "openai_",
  api_host = 'https://api.openai.com',
  api_path = '/v1/responses',
  disabled_response = {
    output = {
      { type = "message", role = "assistant", content = { { type = "output_text", text = "" } } },
      { type = "message", role = "assistant", content = { { type = "output_text", text = "OpenAI models are disabled" } } },
    },
    usage = {
      input_tokens = 0,
      output_tokens = 0,
      total_tokens = 0,
    },
  },
  build_headers = function(api_key)
    return {
      ['Content-type'] = 'application/json',
      ['Authorization'] = 'Bearer ' .. api_key,
    }
  end,
  -- `messages` (from ai.conversation.build()) maps directly into OpenAI's `input`
  -- array with plain string content, matching openai-agent's buildRequestBody().
  build_request_body = function(model, instruction, messages)
    local normalized = normalize_model(model)
    local input_messages = {}
    for _, message in ipairs(messages or {}) do
      table.insert(input_messages, {
        role = message.role,
        content = message.content,
      })
    end

    local request_body = {
      model = normalized.model,
      input = input_messages,
    }

    if normalized.reasoning_effort then
      request_body.reasoning = { effort = normalized.reasoning_effort }
    end

    if instruction and instruction ~= '' then
      request_body.instructions = instruction
    end
    return request_body
  end,
  extract_usage = function(data)
    local usage = type(data.usage) == 'table' and data.usage or {}
    return usage.input_tokens or 0, usage.output_tokens or 0
  end,
  -- Collect `output_text` first, then every text found in `output[]`, joined by a blank line.
  extract_content = function(data)
    local out = {}

    if type(data.output_text) == 'table' then
      for _, text in ipairs(data.output_text) do
        append_text(out, text)
      end
    else
      append_text(out, data.output_text)
    end

    if type(data.output) == 'table' then
      for _, item in ipairs(data.output) do
        append_output_item(out, item)
      end
    end

    return table.concat(out, "\n\n")
  end,
  format_error = function(status, body)
    common.log("Formatting OpenAI API error: " .. body)
    local success, error_data = pcall(vim.fn.json_decode, body)

    if success and error_data and error_data.error then
      local error_type = error_data.error.type or "unknown_error"
      local error_message = error_data.error.message or "Unknown error occurred"
      local error_code = error_data.error.code or ""
      local error_param = error_data.error.param or ""

      local error_result = string.format("# OpenAI API Error (%s)\n\n**Error Type**: %s\n", status, error_type)
      if error_code ~= "" then
        error_result = error_result .. string.format("**Error Code**: %s\n", error_code)
      end
      if error_param ~= "" then
        error_result = error_result .. string.format("**Parameter**: %s\n", error_param)
      end
      return error_result .. string.format("**Message**: %s\n", error_message)
    else
      return string.format("# OpenAI API Error (%s)\n\n```\n%s\n```", status, body)
    end
  end
})

query.askHeavy = openai_runner.askHeavy
query.askLight = openai_runner.askLight

return query
