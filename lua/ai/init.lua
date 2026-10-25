local anthropic = require('ai.anthropic.query')
local googleai = require('ai.googleai.query')
local openai = require('ai.openai.query')
local ollama_reword = require('ai.ollama.reword')
local aiconfig = require('ai.aiconfig')
local common = require('ai.common')

local default_prompts = {
  introduce = {
    command = 'AIIntroduceYourself',
    loading_tpl = 'Loading...',
    prompt_tpl = 'Say who you are, your version, and the currently used model',
    result_tpl = '${output}',
    require_input = false,
  }
}

local M = {}
M.opts = {
  models = {},

  anthropic_agent_host = '',
  googleai_agent_host = '',
  openai_agent_host = '',

  anthropic_api_key = '',
  googleai_api_key = '',
  openai_api_key = '',

  agent_size_threshold_bytes = 102400,

  ollama_host = '',
  ollama_model = '',

  locale = 'en',
  alternate_locale = 'fr',
  result_popup_gets_focus = false,
  upload_url = '',
  upload_token = '',
  upload_as_public = false,

  stats_ingestion_token = '',
}
M.prompts = default_prompts
local win_id

local function splitLines(input)
  local lines = {}
  local offset = 1
  while offset > 0 do
    local i = string.find(input, '\n', offset)
    if i == nil then
      table.insert(lines, string.sub(input, offset, -1))
      offset = 0
    else
      table.insert(lines, string.sub(input, offset, i - 1))
      offset = i + 1
    end
  end
  return lines
end

local function joinLines(lines)
  local result = ""
  for _, line in ipairs(lines) do
    result = result .. line .. "\n"
  end
  return result
end

local function isEmpty(text)
  return text == nil or text == ''
end

function M.hasLetters(text)
  return type(text) == 'string' and text:match('[a-zA-Z]') ~= nil
end

function M.getSelectedText(esc)
  if esc then
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<esc>', true, false, true), 'n', false)
  end
  local vstart = vim.fn.getpos("'<")
  local vend = vim.fn.getpos("'>")
  local ok, lines = pcall(vim.api.nvim_buf_get_text, 0, vstart[2] - 1, vstart[3] - 1, vend[2] - 1, vend[3], {})
  if ok then
    return joinLines(lines)
  else
    lines = vim.api.nvim_buf_get_lines(0, vstart[2] - 1, vend[2], false)
    return joinLines(lines)
  end
end

function M.close()
  if win_id == nil or win_id == vim.api.nvim_get_current_win() then
    return
  end
  pcall(vim.api.nvim_win_close, win_id, true)
  win_id = nil
end

function M.createPopup(initialContent, width, height)
  M.close()
  local bufnr = vim.api.nvim_create_buf(false, true)

  local update = function(content)
    if content == nil then
      content = ''
    end
    local lines = splitLines(content)
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, lines)
    vim.bo[bufnr].modifiable = false
  end

  win_id = vim.api.nvim_open_win(bufnr, false, {
    relative = 'cursor',
    border = 'single',
    title = 'code-ai.md',
    style = 'minimal',
    width = width,
    height = height,
    row = 1,
    col = 0,
  })
  vim.bo[bufnr].filetype = 'markdown'
  vim.api.nvim_win_set_option(win_id, 'wrap', true)


  update(initialContent)
  if M.opts.result_popup_gets_focus then
    vim.api.nvim_set_current_win(win_id)
  end
  return update
end

function M.fill(tpl, args)
  if tpl == nil then
    tpl = ''
  else
    for key, value in pairs(args) do
      local str_value = (value == nil) and '' or tostring(value)
      local escaped_value = str_value:gsub('%%', '%%%%')
      tpl = string.gsub(tpl, '%${' .. key .. '}', escaped_value)
    end
  end
  return tpl
end


local providers = {
  anthropic = anthropic,
  googleai = googleai,
  openai = openai,
}

local function queryProviderRunner(parsed_model, instruction, prompt_text, query_opts, scanned_files, heavy, common_opts)
  local runner_mod = providers[parsed_model.provider]
  local api_key = M.opts[parsed_model.provider .. '_api_key']
  local agent_host = M.opts[parsed_model.provider .. '_agent_host']
  local upload_url = common_opts.upload_url
  local upload_token = common_opts.upload_token
  local upload_as_public = common_opts.upload_as_public

  if heavy then
    runner_mod.askHeavy(
      parsed_model.model,
      instruction,
      prompt_text,
      query_opts,
      api_key,
      agent_host,
      upload_url,
      upload_token,
      upload_as_public,
      scanned_files
    )
  else
    runner_mod.askLight(
      parsed_model.model,
      instruction,
      prompt_text,
      query_opts,
      api_key,
      upload_url,
      upload_token,
      upload_as_public,
      scanned_files
    )
  end
end

function M.handle(name, input)
  local def = M.prompts[name]
  if not def then
    common.log("Command '" .. tostring(name) .. "' not found in prompts configuration.")
    return
  end

  local width = vim.fn.winwidth(0)
  local height = vim.fn.winheight(0)
  local args = {
    locale = M.opts.locale,
    alternate_locale = M.opts.alternate_locale,
    input = input,
    input_encoded = vim.fn.json_encode(input),
  }

  -- Resolve models for this prompt
  local task_models = common.resolveTaskModels(def.models, M.opts.models)
  local implement_spec = task_models.implement
  local plan_spec = task_models.plan
  local reword_spec = task_models.reword

  -- Validate mandatory 'implement' model
  if not implement_spec or implement_spec == '' then
    local err_msg = string.format("# Configuration Error\n\nNo 'implement' model configured for command '%s'.", name)
    common.log(err_msg)
    local update = M.createPopup(err_msg, width - 8, height - 4)
    update(err_msg)
    return
  end

  local implement_parsed, implement_err = common.parseModelSpec(implement_spec)
  if not implement_parsed then
    local err_msg = string.format("# Configuration Error\n\nInvalid 'implement' model for '%s': %s", name, implement_err)
    common.log(err_msg)
    local update = M.createPopup(err_msg, width - 8, height - 4)
    update(err_msg)
    return
  end

  local implement_api_key = M.opts[implement_parsed.provider .. '_api_key']
  if not implement_api_key or implement_api_key == '' then
    local err_msg = string.format(
      "# Configuration Error\n\nMissing API key for '%s' provider (`%s_api_key`) required by 'implement' model '%s'.",
      implement_parsed.provider, implement_parsed.provider, implement_spec
    )
    common.log(err_msg)
    local update = M.createPopup(err_msg, width - 8, height - 4)
    update(err_msg)
    return
  end

  -- Validate optional 'plan' and 'reword' models
  -- Both must be present to enable planning; if either is absent/nil/disabled, planning is skipped.
  local has_planning = false
  local plan_parsed = nil
  local reword_parsed = nil

  if plan_spec and reword_spec then
    local p_parsed, p_err = common.parseModelSpec(plan_spec)
    if not p_parsed then
      local err_msg = string.format("# Configuration Error\n\nInvalid 'plan' model for '%s': %s", name, p_err)
      common.log(err_msg)
      local update = M.createPopup(err_msg, width - 8, height - 4)
      update(err_msg)
      return
    end

    local r_parsed, r_err = common.parseModelSpec(reword_spec)
    if not r_parsed then
      local err_msg = string.format("# Configuration Error\n\nInvalid 'reword' model for '%s': %s", name, r_err)
      common.log(err_msg)
      local update = M.createPopup(err_msg, width - 8, height - 4)
      update(err_msg)
      return
    end

    local p_api_key = M.opts[p_parsed.provider .. '_api_key']
    if not p_api_key or p_api_key == '' then
      local err_msg = string.format(
        "# Configuration Error\n\nMissing API key for '%s' provider (`%s_api_key`) required by 'plan' model '%s'.",
        p_parsed.provider, p_parsed.provider, plan_spec
      )
      common.log(err_msg)
      local update = M.createPopup(err_msg, width - 8, height - 4)
      update(err_msg)
      return
    end

    local r_api_key = M.opts[r_parsed.provider .. '_api_key']
    if not r_api_key or r_api_key == '' then
      local err_msg = string.format(
        "# Configuration Error\n\nMissing API key for '%s' provider (`%s_api_key`) required by 'reword' model '%s'.",
        r_parsed.provider, r_parsed.provider, reword_spec
      )
      common.log(err_msg)
      local update = M.createPopup(err_msg, width - 8, height - 4)
      update(err_msg)
      return
    end

    plan_parsed = p_parsed
    reword_parsed = r_parsed
    has_planning = true
  end

  -- Determine query mode (agent vs standalone)
  local query_mode = def.query_mode
  local is_heavy = false
  local scanned_files_list = nil

  if query_mode == "standalone" then
    is_heavy = false
    scanned_files_list = nil
    common.log("Using standalone mode (forced by command configuration)")
  elseif query_mode == "agent" then
    is_heavy = true
    scanned_files_list = aiconfig.listScannedFilesFromConfig()
    common.log("Using agent mode (forced by command configuration)")
  else
    scanned_files_list = aiconfig.listScannedFilesFromConfig()
    local total_size = aiconfig.getScannedFilesTotalSize(scanned_files_list)
    local threshold = def.agent_size_threshold_bytes or M.opts.agent_size_threshold_bytes or 102400

    if #scanned_files_list == 0 then
      is_heavy = false
      common.log("Using standalone mode (no files to scan)")
    elseif total_size >= threshold then
      is_heavy = true
      common.log(string.format("Using agent mode (scanned files total size %d bytes >= threshold %d bytes)", total_size, threshold))
    else
      is_heavy = false
      common.log(string.format("Using standalone mode (scanned files total size %d bytes < threshold %d bytes)", total_size, threshold))
    end
  end

  local show_files_table = (scanned_files_list ~= nil and #scanned_files_list > 0)
  local scanned_files_table = show_files_table and aiconfig.listScannedFilesAsFormattedTable(scanned_files_list) or ""

  local function renderStatus(status_text)
    local content = status_text
    if show_files_table then
      content = content .. "\n\n" .. scanned_files_table
    end
    return content
  end

  local initial_status = has_planning
    and string.format("[1/3] Planning (%s)...", plan_parsed.full)
    or string.format("Implementing (%s)...", implement_parsed.full)

  local update = M.createPopup(renderStatus(initial_status), width - 8, height - 4)
  local original_prompt = M.fill(def.prompt_tpl, args)

  local common_query_opts = {
    upload_url = M.opts.upload_url,
    upload_token = M.opts.upload_token,
    upload_as_public = M.opts.upload_as_public,
  }

  -- Step 3: Implement
  local function executeImplement(final_implement_prompt)
    if has_planning then
      update(renderStatus(string.format("[3/3] Implementing (%s)...", implement_parsed.full)))
    else
      update(renderStatus(string.format("Implementing (%s)...", implement_parsed.full)))
    end

    local query_opts = {
      raw_output = false,
      handleResult = function(output)
        args.output = output
        args[implement_parsed.provider .. '_output'] = output
        update(M.fill(def.result_tpl or '${output}', args))
        return output
      end,
      callback = function(res, is_error)
        if is_error or (type(res) == 'string' and string.sub(res, 1, 13) == "# Agent Error") then
          update(res)
        end
      end,
      upload_url = common_query_opts.upload_url,
      upload_token = common_query_opts.upload_token,
      upload_as_public = common_query_opts.upload_as_public,
    }

    queryProviderRunner(
      implement_parsed,
      aiconfig.getImplementInstructions(),
      final_implement_prompt,
      query_opts,
      scanned_files_list,
      is_heavy,
      common_query_opts
    )
  end

  -- Step 2: Reword (only when has_planning is true)
  local function executeReword(plan_text)
    update(renderStatus(string.format("[2/3] Rewording plan (%s)...", reword_parsed.full)))

    local reword_prompt = string.format(
      "Original user request:\n%s\n\nPlan to execute:\n%s\n\n" ..
      "Refine the plan above into a direct continuation prompt for the implementation model. " ..
      "Enforce that the implementation model must provide the full, complete new content of all files to modify or create, and never return diffs or code snippets.",
      original_prompt,
      plan_text
    )

    local query_opts = {
      raw_output = true,
      handleResult = function(output) return output end,
      callback = function(res, is_error)
        if is_error or (type(res) == 'string' and (string.sub(res, 1, 13) == "# Agent Error" or string.sub(res, 1, 6) == "Error:")) then
          common.log("Error during Reword step: " .. tostring(res))
          update("# Error during Reword step\n\n" .. tostring(res))
          return
        end

        local combined_implement_prompt = original_prompt .. "\n\n### Implementation Plan & Instructions:\n" .. res
        executeImplement(combined_implement_prompt)
      end,
      upload_url = common_query_opts.upload_url,
      upload_token = common_query_opts.upload_token,
      upload_as_public = common_query_opts.upload_as_public,
    }

    queryProviderRunner(
      reword_parsed,
      aiconfig.getRewordInstructions(),
      reword_prompt,
      query_opts,
      nil,
      false,
      common_query_opts
    )
  end

  -- Step 1: Plan (only when has_planning is true)
  local function executePlan()
    update(renderStatus(string.format("[1/3] Planning (%s)...", plan_parsed.full)))

    local query_opts = {
      raw_output = true,
      handleResult = function(output) return output end,
      callback = function(res, is_error)
        if is_error or (type(res) == 'string' and (string.sub(res, 1, 13) == "# Agent Error" or string.sub(res, 1, 6) == "Error:")) then
          common.log("Error during Plan step: " .. tostring(res))
          update("# Error during Plan step\n\n" .. tostring(res))
          return
        end

        executeReword(res)
      end,
      upload_url = common_query_opts.upload_url,
      upload_token = common_query_opts.upload_token,
      upload_as_public = common_query_opts.upload_as_public,
    }

    queryProviderRunner(
      plan_parsed,
      aiconfig.getPlanInstructions(),
      original_prompt,
      query_opts,
      scanned_files_list,
      is_heavy,
      common_query_opts
    )
  end

  if has_planning then
    executePlan()
  else
    executeImplement(original_prompt)
  end
end

function M.rewordPrompt(input)
  local width = vim.fn.winwidth(0)
  local height = vim.fn.winheight(0)
  local update = M.createPopup("Rewording prompt with Ollama...", width - 8, height - 4)

  ollama_reword.reword(input, M.opts, function(result)
    update(result)
  end)
end

function M.assign(table, other)
  for k, v in pairs(other) do
    table[k] = v
  end
  return table
end

function M.setup(opts)
  for k, v in pairs(opts) do
    if k == 'prompts' then
      M.prompts = {}
      M.assign(M.prompts, default_prompts)
      M.assign(M.prompts, v)
    elseif M.opts[k] ~= nil then
      M.opts[k] = v
    end
  end
  for k, v in pairs(M.prompts) do
    if v.command then
      vim.api.nvim_create_user_command(v.command, function(args)
        local text = args['args']
        if isEmpty(text) then
          text = M.getSelectedText(true)
        end
        if not v.require_input or M.hasLetters(text) then
          M.handle(k, text)
        end
      end, { range = true, nargs = '?' })
    end
  end

  -- Check provider API keys for any models configured globally or per-prompt
  local referenced_providers = {}
  local function collectProviders(models_def)
    if type(models_def) ~= 'table' then return end
    local task_models = common.resolveTaskModels(models_def, nil)
    for _, spec in pairs(task_models) do
      local parsed = common.parseModelSpec(spec)
      if parsed then
        referenced_providers[parsed.provider] = true
      end
    end
  end

  collectProviders(M.opts.models)
  for _, prompt_def in pairs(M.prompts) do
    collectProviders(prompt_def.models)
  end

  for provider, _ in pairs(referenced_providers) do
    local api_key = M.opts[provider .. '_api_key']
    if api_key == nil or api_key == '' then
      common.log(provider .. " API key is not configured; calls using this provider will fail.")
    end
  end

  vim.api.nvim_create_user_command('AIRewordPrompt', function(args)
    local text = args['args']
    if isEmpty(text) then
      text = M.getSelectedText(true)
    end
    if M.hasLetters(text) then
      M.rewordPrompt(text)
    end
  end, { range = true, nargs = '?' })

  vim.api.nvim_create_user_command('AIListScannedFiles', function()
    local width = vim.fn.winwidth(0)
    local height = vim.fn.winheight(0)
    local scanned_files = aiconfig.listScannedFilesAsFormattedTable()
    local update = M.createPopup(scanned_files, width - 12, height - 8)
    update(scanned_files)
  end, {})

  vim.api.nvim_create_user_command('AIShowSystemInstructions', function()
    local width = vim.fn.winwidth(0)
    local height = vim.fn.winheight(0)
    local instructions = aiconfig.getSystemInstructions()
    local update = M.createPopup(instructions, width - 12, height - 8)
    update(instructions)
  end, {})
end

vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
  callback = M.close,
})

return M
