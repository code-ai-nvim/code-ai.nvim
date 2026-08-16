local curl = require('plenary.curl')
local aiconfig = require('ai.aiconfig')
local common = require('ai.common')
local history = require('ai.history')
local conversation = require('ai.conversation')

local M = {}

-- Light-mode requests carrying embedded project files may take longer than a
-- bare-prompt light request; give them a generous timeout (in milliseconds).
local LIGHT_REQUEST_TIMEOUT_MS = 120000

-- Shared helper: build the project_context array ({ filename, content }) from a
-- list of scanned file relative paths. Used by both askHeavy and askLight so
-- both code paths get identical, safe handling of empty/unreadable files.
-- Files whose content is nil or empty string are skipped (with a logged
-- warning) instead of being propagated further, since:
--   - Server-side (askHeavy path), the agent's handleFile rejects empty
--     content with a hard 400, which previously killed the entire heavy
--     request sequence because of a single bad file.
--   - Client-side (askLight path), an empty file entry would otherwise be
--     embedded as a confusing empty file content block in the conversation.
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

  return project_context
end

-- Create a generic query runner for a provider
function M.createQueryRunner(config)
  -- config requires:
  --   name: string (e.g. "Anthropic", "GoogleAI", "OpenAI")
  --   title_tag: string (e.g. "ANT", "GGL", "OPN")
  --   history_prefix: string (e.g. "anthropic_", "googleai_", "openai_")
  --   disabled_response: table
  --   api_host: string
  --   api_path: string (used unless build_url is provided)
  --   build_url: function(api_host, api_key, model) -> string (optional; when
  --     provided, overrides api_path-based URL construction, used by
  --     providers whose REST endpoint embeds the model id and/or API key
  --     directly in the URL, e.g. GoogleAI's `:generateContent?key=...`)
  --   build_headers: function(api_key, model) -> table
  --   build_request_body: function(model, instruction, messages) -> table
  --   extract_usage: function(data) -> input_tokens, output_tokens
  --   extract_content: function(data) -> string
  --   format_error: function(status, body) -> string

  local runner = {}

  function runner.formatResult(data, upload_url, upload_token, upload_as_public, opts, model_used, prompt_to_save)
    common.log("Inside " .. config.name .. " formatResult")

    if config.validate_data then
      local err_result = config.validate_data(data)
      if err_result then
        return err_result
      end
    end

    local input_tokens, output_tokens = config.extract_usage(data)
    local formatted_input_tokens = common.formatTokenCount(input_tokens)
    local formatted_output_tokens = common.formatTokenCount(output_tokens)

    local content_text = config.extract_content(data)

    local result = content_text
      .. '\n\n'
      .. config.name .. ' ' .. model_used
      .. ' (' .. formatted_input_tokens .. ' in, ' .. formatted_output_tokens .. ' out)\n\n'

    result = common.insertWordToTitle(config.title_tag, result)

    if model_used ~= 'disabled' then
      history.saveToHistory(config.history_prefix .. model_used, prompt_to_save .. '\n\n' .. result)
      local model_label = config.name .. ' (' .. model_used .. ')'
      common.uploadContent(upload_url, upload_token, result, model_label, upload_as_public)

      if opts and opts.stats then
        common.sendIngestionStats(opts.stats, input_tokens, output_tokens)
        opts.stats = nil
      end
    else
      common.log(config.name .. " model is disabled: skipping history save and upload.")
    end

    return result
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
      },
      function(data, upload_url, upload_token, upload_as_public, callback_opts)
        return runner.formatResult(data, upload_url, upload_token, upload_as_public, callback_opts, model_used, prompt_to_save)
      end
    )
  end

  -- Build and dispatch a provider-specific markdown error string directly through
  -- opts.callback, bypassing formatResult/history/upload entirely. Mirrors the
  -- error path already used by common.askHeavy for chunk-transmission failures.
  local function reportAgentConfigError(opts, message)
    common.log(config.name .. " askHeavy aborted: " .. message)
    if opts.callback ~= nil then
      vim.schedule(function()
        opts.callback("# Agent Error\n\n" .. message)
      end)
    end
  end

  function runner.askHeavy(model, instruction, prompt, opts, api_key, agent_host, upload_url, upload_token, upload_as_public, scanned_files)
    if model == "disabled" then
      common.handleDisabledModel(config.name, model,
        {
          handleResult = opts.handleResult,
          callback = opts.callback,
          upload_url = upload_url,
          upload_token = upload_token,
          upload_as_public = upload_as_public
        },
        function(res, cb_opts)
          runner.askCallback(res, cb_opts, model, prompt)
        end,
        config.disabled_response
      )
      return
    end

    if agent_host == nil or agent_host == '' then
      reportAgentConfigError(
        opts,
        string.format(
          "%s agent mode was selected but no agent host is configured. " ..
          "Set the corresponding `_agent_host` option, force `query_mode = \"standalone\"` for this command, " ..
          "or reduce the scanned files size below the configured threshold.",
          config.name
        )
      )
      return
    end

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
      {
        handleResult = opts.handleResult,
        callback = opts.callback,
        upload_url = upload_url,
        upload_token = upload_token,
        upload_as_public = upload_as_public,
        stats = opts.stats,
      },
      function(res, cb_opts)
        runner.askCallback(res, cb_opts, model, prompt)
      end
    )
  end

  function runner.askLight(model, instruction, prompt, opts, api_key, upload_url, upload_token, upload_as_public, scanned_files)
    if model == "disabled" then
      common.handleDisabledModel(config.name, model,
        {
          handleResult = opts.handleResult,
          callback = opts.callback,
          upload_url = upload_url,
          upload_token = upload_token,
          upload_as_public = upload_as_public
        },
        function(res, cb_opts)
          runner.askCallback(res, cb_opts, model, prompt)
        end,
        config.disabled_response
      )
      return
    end

    -- Build project_context (possibly empty) so every light call goes through
    -- the exact same conversation-shaping code path, regardless of whether
    -- project files are being embedded or not.
    local project_context = build_project_context(scanned_files)
    local messages = conversation.build(prompt, project_context)

    local input_size, input_lines = common.calculateInputStats(instruction, prompt, project_context)
    opts.stats = {
      model = model,
      input_size = input_size,
      input_lines = input_lines,
    }

    local request_body = config.build_request_body(model, instruction, messages)
    local headers = config.build_headers(api_key, model)

    -- Some providers (e.g. GoogleAI's `:generateContent` method) need the
    -- model id and/or API key embedded directly in the URL rather than a
    -- fixed path + header. When config.build_url is provided, use it;
    -- otherwise fall back to the historical static api_host .. api_path.
    local url
    if config.build_url then
      url = config.build_url(config.api_host, api_key, model)
    else
      url = config.api_host .. config.api_path
    end

    curl.post(url, {
      headers = headers,
      body = vim.fn.json_encode(request_body),
      timeout = LIGHT_REQUEST_TIMEOUT_MS,
      callback = function(res)
        common.log("Before " .. config.name .. " callback call")
        vim.schedule(function()
          runner.askCallback(res, {
            handleResult = opts.handleResult,
            callback = opts.callback,
            upload_url = upload_url,
            upload_token = upload_token,
            upload_as_public = upload_as_public,
            stats = opts.stats,
          }, model, prompt)
        end)
      end
    })
  end

  return runner
end

return M

