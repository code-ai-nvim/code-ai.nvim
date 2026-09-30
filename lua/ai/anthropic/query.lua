local common = require('ai.common')
local provider = require('ai.provider')

local query = {}

-- Normalize a model name that may carry a trailing suffix.
-- Examples:
--   "xxxxxxxxxx-yyy-medium" -> { model = "xxxxxxxxxx-yyy", effort = "low" }
--   "xxxxxxxxxx-yyy-high"   -> { model = "xxxxxxxxxx-yyy", effort = "xhigh" }
--   "xxxxxxxxxx-yyy-low"    -> { model = "xxxxxxxxxx-yyy", thinking = { type = "between_tools" } }
-- Models without a suffix are passed through unchanged.
local function normalizeAnthropicModel(model)
  local base_model, suffix = model:match('^(.*)%-(.+)$')

  if not base_model or not suffix then
    return { model = model }
  end

  if suffix == 'medium' then
    return { model = base_model, effort = 'low' }
  elseif suffix == 'high' then
    return { model = base_model, effort = 'xhigh' }
  else
    return { model = base_model, thinking = { type = 'between_tools' } }
  end
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
    if model and model:match('^claude%-sonnet') then
      headers['anthropic-beta'] = 'context-1m-2025-08-07'
    end
    return headers
  end,
  -- `messages` is an ordered array of { role = "user"|"assistant", content = "..." }
  -- built by ai.conversation.build(). Anthropic's Messages API already accepts this
  -- exact shape (plain string content per turn), so we pass it through as-is,
  -- matching wire-for-wire what anthropic-agent's buildRequestBody() sends today.
  build_request_body = function(model, instruction, messages)
    local normalized = normalizeAnthropicModel(model)

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
  -- Anthropic's Messages API returns `content` as an array of blocks, and the
  -- first block is not guaranteed to be a `text` block (e.g. a `thinking` block
  -- can precede it). Mirror anthropic-agent's transformSuccessResponse() exactly:
  -- filter every block of type `text` with a string `text` field, and join them
  -- with `\n\n`. Previously this only read `data.content[1].text`, which silently
  -- returned an empty string whenever the first block wasn't a `text` block,
  -- causing the response body to be dropped from both the popup and the history
  -- file even though the API call itself succeeded.
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

function query.askHeavy(model, instruction, prompt, opts, api_key, agent_host, upload_url, upload_token, upload_as_public, scanned_files)
  anthropic_runner.askHeavy(model, instruction, prompt, opts, api_key, agent_host, upload_url, upload_token, upload_as_public, scanned_files)
end

function query.askLight(model, instruction, prompt, opts, api_key, upload_url, upload_token, upload_as_public, scanned_files)
  anthropic_runner.askLight(model, instruction, prompt, opts, api_key, upload_url, upload_token, upload_as_public, scanned_files)
end


return query
