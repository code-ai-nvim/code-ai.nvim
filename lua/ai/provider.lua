local curl = require('plenary.curl')
local aiconfig = require('ai.aiconfig')
local common = require('ai.common')
local history = require('ai.history')
local conversation = require('ai.conversation')

local M = {}

-- ===== Constants =====

-- Light-mode requests carrying embedded project files may take longer than a
-- bare-prompt light request; give them a generous timeout (in milliseconds).
local LIGHT_REQUEST_TIMEOUT_MS = 120000

-- ===== Helpers =====

-- Build the project_context array ({ filename, content }) from a list of
-- scanned file relative paths for askHeavy.
-- Files whose content is nil or empty string are skipped (with a logged
-- warning) instead of being propagated further, since server-side (askHeavy
-- path), the agent's handleFile rejects empty content with a hard 400.
local function build_project_context(scanned_files_list)
  local project_context = {}
  local files_list = scanned_files_list or {}

  for _, relative_path in pairs(files_list) do
    local content = aiconfig.contentOf(relative_path)
    if content ~= nil and content ~= '' then
      table.insert(project_context, { filename = relative_path, content = content })
    else
      common.log("build_project_context: Skipping file with empty/unreadable content: " .. tostring(relative_path))
    end
  end

  if #project_context > 0 then
    local names = {}
    for _, item in ipairs(project_context) do
      table.insert(names, item.filename)
    end
    common.log(string.format("build_project_context: %d context file(s) loaded: %s", #project_context, table.concat(names, ", ")))
  else
    common.log("build_project_context: No context files loaded (empty list or all skipped).")
  end

  return project_context
end

-- Options handed to common.askCallback / common.askHeavy.
-- `upload` is { url, token, is_public }.
local function make_callback_opts(opts, upload)
  return {
    handleResult = opts.handleResult,
    callback = opts.callback,
    upload_url = upload.url,
    upload_token = upload.token,
    upload_as_public = upload.is_public,
    stats = opts.stats,
    raw_output = opts.raw_output,
  }
end

-- Send accumulated stats (if any) exactly once, then clear them.
local function flush_stats(opts, input_tokens, output_tokens)
  if opts and opts.stats then
    common.sendIngestionStats(opts.stats, input_tokens, output_tokens)
    opts.stats = nil
  end
end

-- ===== Query runner =====

---@class ProviderConfig
---@field name string Display name (e.g. "Anthropic", "GoogleAI", "OpenAI")
---@field title_tag string Short tag inserted in result titles (e.g. "ANT", "GGL", "OPN")
---@field history_prefix string Prefix of history entries (e.g. "anthropic_")
---@field disabled_response table Fake API response used when the model is "disabled"
---@field api_host string Base URL of the provider API
---@field api_path string|nil Path appended to api_host (alternative to build_url)
---@field build_url (fun(api_host: string, api_key: string, model: string): string)|nil
---  Full URL builder (alternative to api_path), for providers whose REST endpoint
---  embeds the model id and/or API key in the URL (e.g. GoogleAI's `:generateContent?key=...`)
---@field build_headers fun(api_key: string, model: string): table
---@field build_request_body fun(model: string, instruction: string, messages: table[]): table
---@field validate_data (fun(data: table): string|nil)|nil Returns an error string when the response is unusable
---@field extract_usage fun(data: table): number, number Returns input_tokens, output_tokens
---@field extract_content fun(data: table): string
---@field format_error fun(status: number, body: string): string

--- Create a generic query runner for a provider.
---@param config ProviderConfig
function M.createQueryRunner(config)
  local runner = {}

  local function format_footer(model_used, input_tokens, output_tokens)
    return '\n\n'
      .. config.name .. ' ' .. model_used
      .. ' (' .. common.formatTokenCount(input_tokens) .. ' in, ' .. common.formatTokenCount(output_tokens) .. ' out)\n\n'
  end

  -- Save history and upload the formatted result.
  local function persist_result(model_used, prompt_to_save, result, upload)
    history.saveToHistory(config.history_prefix .. model_used, prompt_to_save .. '\n\n' .. result)
    local model_label = config.name .. ' (' .. model_used .. ')'
    common.uploadContent(upload.url, upload.token, result, model_label, upload.is_public)
  end

  function runner.formatResult(data, upload_url, upload_token, upload_as_public, opts, model_used, prompt_to_save)
    common.log("Inside " .. config.name .. " formatResult")

    if config.validate_data then
      local err_result = config.validate_data(data)
      if err_result then
        return err_result, true
      end
    end

    local input_tokens, output_tokens = config.extract_usage(data)
    local content_text = config.extract_content(data)

    if opts and opts.raw_output then
      flush_stats(opts, input_tokens, output_tokens)
      return content_text, false
    end

    local result = content_text .. format_footer(model_used, input_tokens, output_tokens)
    result = common.insertWordToTitle(config.title_tag, result)

    if model_used ~= 'disabled' then
      local upload = { url = upload_url, token = upload_token, is_public = upload_as_public }
      persist_result(model_used, prompt_to_save, result, upload)
      flush_stats(opts, input_tokens, output_tokens)
    else
      common.log(config.name .. " model is disabled: skipping history save and upload.")
    end

    return result, false
  end

  function runner.askCallback(res, opts, model_used, prompt_to_save)
    common.askCallback(
      res,
      {
        handleResult = opts.handleResult,
        handleError = config.format_error,
        callback = opts.callback,
        upload_url = opts.upload_url,
        upload_token = opts.upload_token,
        upload_as_public = opts.upload_as_public,
        stats = opts.stats,
        raw_output = opts.raw_output,
      },
      function(data, upload_url, upload_token, upload_as_public, callback_opts)
        return runner.formatResult(data, upload_url, upload_token, upload_as_public, callback_opts, model_used, prompt_to_save)
      end
    )
  end

  -- Answer a "disabled" model with the provider's canned response.
  local function answer_disabled(model, prompt, opts, upload)
    common.handleDisabledModel(
      make_callback_opts(opts, upload),
      function(res, cb_opts)
        runner.askCallback(res, cb_opts, model, prompt)
      end,
      config.disabled_response
    )
  end

  -- Build and dispatch a provider-specific markdown error string directly through
  -- opts.callback, bypassing formatResult/history/upload entirely. Mirrors the
  -- error path already used by common.askHeavy for chunk-transmission failures.
  local function reportAgentConfigError(opts, message)
    common.log(config.name .. " askHeavy aborted: " .. message)
    if opts.callback ~= nil then
      vim.schedule(function()
        opts.callback(common.AGENT_ERROR_PREFIX .. "\n\n" .. message, true)
      end)
    end
  end

  -- Some providers (e.g. GoogleAI's `:generateContent` method) need the
  -- model id and/or API key embedded directly in the URL rather than a
  -- fixed path + header. When config.build_url is provided, use it;
  -- otherwise fall back to the historical static api_host .. api_path.
  local function resolve_url(api_key, model)
    if config.build_url then
      return config.build_url(config.api_host, api_key, model)
    end
    return config.api_host .. config.api_path
  end

  function runner.askHeavy(model, instruction, prompt, opts, api_key, agent_host, upload_url, upload_token, upload_as_public, scanned_files)
    local upload = { url = upload_url, token = upload_token, is_public = upload_as_public }

    if model == "disabled" then
      answer_disabled(model, prompt, opts, upload)
      return
    end

    if agent_host == nil or agent_host == '' then
      reportAgentConfigError(
        opts,
        string.format(
          "%s agent host is not configured. Set the corresponding `_agent_host` option in your plugin configuration.",
          config.name
        )
      )
      return
    end

    -- Fallback for callers that don't pre-scan the project files.
    local scanned_files_list = scanned_files or aiconfig.listScannedFilesFromConfig()
    local project_context = build_project_context(scanned_files_list)

    local input_size, input_lines = common.calculateInputStats(instruction, prompt, project_context)
    opts.stats = {
      model = model,
      input_size = input_size,
      input_lines = input_lines,
    }

    common.askHeavy(
      agent_host,
      api_key,
      model,
      instruction,
      prompt,
      project_context,
      make_callback_opts(opts, upload),
      function(res, cb_opts)
        runner.askCallback(res, cb_opts, model, prompt)
      end
    )
  end

  function runner.askLight(model, instruction, prompt, opts, api_key, upload_url, upload_token, upload_as_public)
    local upload = { url = upload_url, token = upload_token, is_public = upload_as_public }

    if model == "disabled" then
      answer_disabled(model, prompt, opts, upload)
      return
    end

    local messages = conversation.build(prompt, nil)

    local input_size, input_lines = common.calculateInputStats(instruction, prompt, nil)
    opts.stats = {
      model = model,
      input_size = input_size,
      input_lines = input_lines,
    }

    local request_body = config.build_request_body(model, instruction, messages)
    local headers = config.build_headers(api_key, model)
    local url = resolve_url(api_key, model)

    local success, err = pcall(function()
      curl.post(url, {
        headers = headers,
        body = vim.fn.json_encode(request_body),
        timeout = LIGHT_REQUEST_TIMEOUT_MS,
        callback = function(res)
          common.log("Before " .. config.name .. " callback call")
          vim.schedule(function()
            runner.askCallback(res, make_callback_opts(opts, upload), model, prompt)
          end)
        end
      })
    end)

    if not success then
      local error_msg = string.format("Error: Exception while sending direct API request to %s: %s", config.name, tostring(err))
      common.log(config.name .. " askLight exception: " .. error_msg)
      if opts.callback ~= nil then
        vim.schedule(function()
          opts.callback(error_msg, true)
        end)
      end
    end
  end

  return runner
end

return M
