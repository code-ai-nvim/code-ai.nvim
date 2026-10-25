local common = require('ai.common')
local provider = require('ai.provider')

local query = {}

-- Valid `effort` values for Anthropic's `output_config`.
local EFFORT_LEVELS = { low = true, medium = true, high = true, xhigh = true, max = true }

-- Split an optional effort suffix off the model id (see common.splitModelSuffix).
-- Recognized suffixes map to Anthropic API fields: effort levels go to
-- `output_config.effort`, and `none` maps to the `between_tools` thinking mode.
-- Unrecognized suffixes are passed through so the upstream API can validate them.
local function normalize_model(model)
  local base_model, suffix = common.splitModelSuffix(model)

  if suffix == nil then
    return { model = model }
  end

  if EFFORT_LEVELS[suffix] then
    return { model = base_model, effort = suffix }
  elseif suffix == 'none' then
    return { model = base_model, thinking = { type = 'between_tools' } }
  end

  return { model = model }
end

-- Sonnet models are opted in to the 1M-token context window.
local function supports_1m_context(model)
  return model ~= nil and model:match('^claude%-sonnet') ~= nil
end

local anthropic_runner = provider.createQueryRunner({
  name = "Anthropic",
  title_tag = "ANT",
  history_prefix = "anthropic_",
  api_host = 'https://api.anthropic.com',
  api_path = '/v1/messages',
  disabled_response = {
    content = { { type = "text", text = "Anthropic models are disabled" } },
    usage = { input_tokens = 0, output_tokens = 0 }
  },
  build_headers = function(api_key, model)
    local headers = {
      ['Content-type'] = 'application/json',
      ['x-api-key'] = api_key,
      ['anthropic-version'] = '2023-06-01'
    }
    if supports_1m_context(model) then
      headers['anthropic-beta'] = 'context-1m-2025-08-07'
    end
    return headers
  end,
  -- `messages` is an ordered array of { role = "user"|"assistant", content = "..." }
  -- built by ai.conversation.build(). Anthropic's Messages API accepts this exact
  -- shape, so it is passed through as-is (same wire format as anthropic-agent).
  build_request_body = function(model, instruction, messages)
    local normalized = normalize_model(model)

    local request_body = {
      model = normalized.model,
      max_tokens = 128000,
      messages = messages,
    }

    if normalized.thinking then
      request_body.thinking = normalized.thinking
    end

    if normalized.effort then
      request_body.output_config = { effort = normalized.effort }
    end

    if instruction and instruction ~= '' then
      request_body.system = instruction
    end
    return request_body
  end,
  extract_usage = function(data)
    local usage = data.usage or {}
    return usage.input_tokens or 0, usage.output_tokens or 0
  end,
  -- Mirrors anthropic-agent: keep every `text` block (other block types, such as
  -- `thinking`, may come first) and join them with a blank line.
  extract_content = function(data)
    if type(data.content) ~= 'table' then
      return ""
    end

    local text_blocks = {}
    for _, block in ipairs(data.content) do
      if type(block) == 'table' and block.type == 'text' and type(block.text) == 'string' then
        table.insert(text_blocks, block.text)
      end
    end

    return table.concat(text_blocks, "\n\n")
  end,
  format_error = function(status, body)
    common.log("Formatting Anthropic API error: " .. body)
    local success, error_data = pcall(vim.fn.json_decode, body)

    if success and error_data and error_data.error then
      local error_type = error_data.error.type or "unknown_error"
      local error_message = error_data.error.message or "Unknown error occurred"
      return string.format(
        "# Anthropic API Error (%s)\n\n**Error Type**: %s\n**Message**: %s\n",
        status,
        error_type,
        error_message
      )
    else
      return string.format("# Anthropic API Error (%s)\n\n```\n%s\n```", status, body)
    end
  end
})

query.askHeavy = anthropic_runner.askHeavy
query.askLight = anthropic_runner.askLight

return query
