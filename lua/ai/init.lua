local anthropic = require('ai.anthropic.query')
local googleai = require('ai.googleai.query')
local openai = require('ai.openai.query')
local ollama_reword = require('ai.ollama.reword')
local ollama_query = require('ai.ollama.query')
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

-- Window id of the current result popup (nil when none is open)
local win_id

local providers = {
  anthropic = anthropic,
  googleai = googleai,
  openai = openai,
}

-- ===== Text helpers =====

local function split_lines(input)
  return vim.split(input, '\n', { plain = true })
end

-- Every line is followed by a newline; an empty list gives "".
local function join_lines(lines)
  if #lines == 0 then
    return ""
  end
  return table.concat(lines, "\n") .. "\n"
end

local function is_empty(text)
  return text == nil or text == ''
end

local function format_context_files(files)
  if not files or #files == 0 then
    return "none"
  end
  local lines = {}
  for _, f in ipairs(files) do
    table.insert(lines, "  - " .. tostring(f))
  end
  return string.format("(%d file(s)):\n%s", #files, table.concat(lines, "\n"))
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
    return join_lines(lines)
  else
    lines = vim.api.nvim_buf_get_lines(0, vstart[2] - 1, vend[2], false)
    return join_lines(lines)
  end
end

--- Fill `${key}` placeholders of a template with the given values.
---@param tpl string|nil
---@param args table<string, any>
---@return string
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

function M.assign(target, source)
  for k, v in pairs(source) do
    target[k] = v
  end
  return target
end

-- ===== Popup =====

function M.close()
  if win_id == nil or win_id == vim.api.nvim_get_current_win() then
    return
  end
  pcall(vim.api.nvim_win_close, win_id, true)
  win_id = nil
end

--- Open the result popup. Returns an `update(content)` function to replace its text.
---@param initialContent string
---@param width number
---@param height number
---@return fun(content: string|nil)
function M.createPopup(initialContent, width, height)
  M.close()
  local bufnr = vim.api.nvim_create_buf(false, true)

  local update = function(content)
    if content == nil then
      content = ''
    end
    local lines = split_lines(content)
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
  vim.wo[win_id].wrap = true

  update(initialContent)
  if M.opts.result_popup_gets_focus then
    vim.api.nvim_set_current_win(win_id)
  end
  return update
end

-- Open a popup sized relative to the current window.
local function show_in_popup(content, width_margin, height_margin)
  local width = vim.fn.winwidth(0)
  local height = vim.fn.winheight(0)
  return M.createPopup(content, width - width_margin, height - height_margin)
end

local function show_config_error(message)
  local err_msg = "# Configuration Error\n\n" .. message
  common.log(err_msg)
  show_in_popup(err_msg, 8, 4)
end

-- ===== Model resolution =====

-- Parse a '<provider>/<model>' spec for `role` (plan, implement or reword).
-- Returns the parsed model, or nil and an error message.
local function parse_model(role, spec, prompt_name)
  local parsed, err = common.parseModelSpec(spec)
  if not parsed then
    return nil, string.format("Invalid '%s' model for '%s': %s", role, prompt_name, err)
  end
  return parsed
end

-- Check the API key (and optionally the agent host) required by a parsed model.
-- requirements = { agent_host = boolean }. Returns true, or nil and an error message.
local function check_credentials(role, spec, parsed, requirements)
  local provider = parsed.provider

  local api_key = M.opts[provider .. '_api_key']
  if not api_key or api_key == '' then
    return nil, string.format(
      "Missing API key for '%s' provider (`%s_api_key`) required by '%s' model '%s'.",
      provider, provider, role, spec
    )
  end

  if requirements.agent_host then
    local agent_host = M.opts[provider .. '_agent_host']
    if not agent_host or agent_host == '' then
      return nil, string.format(
        "Missing agent host for '%s' provider (`%s_agent_host`) required by '%s' model '%s'.",
        provider, provider, role, spec
      )
    end
  end

  return true
end

-- Parse then check credentials. Returns the parsed model, or nil and an error message.
local function resolve_model(role, spec, prompt_name, requirements)
  local parsed, err = parse_model(role, spec, prompt_name)
  if not parsed then
    return nil, err
  end
  local ok, cred_err = check_credentials(role, spec, parsed, requirements)
  if not ok then
    return nil, cred_err
  end
  return parsed
end

-- Build the descriptor of the local (Ollama) reword model from the plugin
-- options. Returns the descriptor, or nil and an error message.
local function resolve_local_reword_model(name)
  if is_empty(M.opts.ollama_host) then
    return nil, string.format("Reword model for '%s' is 'local' but `ollama_host` is not configured.", name)
  end
  if is_empty(M.opts.ollama_model) then
    return nil, string.format("Reword model for '%s' is 'local' but `ollama_model` is not configured.", name)
  end
  return {
    provider = 'ollama',
    model = M.opts.ollama_model,
    full = 'local (ollama/' .. M.opts.ollama_model .. ')',
    is_local = true,
  }
end

local function show_local_only_for_reword(name, task)
  show_config_error(string.format(
    "'local' is only supported for the 'reword' model (command '%s', task '%s').",
    name, task
  ))
end

-- Resolve and validate the models of a prompt. On failure the error is shown
-- and nil is returned. Planning is enabled only when both 'plan' and 'reword'
-- models are configured.
local function resolve_pipeline_models(name, def)
  local task_models = common.resolveTaskModels(def.models, M.opts.models)

  local implement_spec = task_models.implement
  if not implement_spec or implement_spec == '' then
    show_config_error(string.format("No 'implement' model configured for command '%s'.", name))
    return nil
  end

  if common.isLocalModelSpec(implement_spec) then
    show_local_only_for_reword(name, 'implement')
    return nil
  end

  local implement, err = resolve_model('implement', implement_spec, name, { agent_host = true })
  if not implement then
    show_config_error(err)
    return nil
  end

  local result = { implement = implement, has_planning = false }

  local plan_spec = task_models.plan
  local reword_spec = task_models.reword
  if plan_spec and reword_spec then
    if common.isLocalModelSpec(plan_spec) then
      show_local_only_for_reword(name, 'plan')
      return nil
    end

    local reword_is_local = common.isLocalModelSpec(reword_spec)

    -- Phase 1: parse both specs.
    local plan, plan_err = parse_model('plan', plan_spec, name)
    if not plan then
      show_config_error(plan_err)
      return nil
    end

    local reword, reword_err
    if reword_is_local then
      reword, reword_err = resolve_local_reword_model(name)
    else
      reword, reword_err = parse_model('reword', reword_spec, name)
    end
    if not reword then
      show_config_error(reword_err)
      return nil
    end

    -- Phase 2: credentials. 'plan' runs through the agent; 'reword' uses
    -- askLight (direct API call), so it needs no agent host. A local reword
    -- needs no API key at all.
    local ok, cred_err = check_credentials('plan', plan_spec, plan, { agent_host = true })
    if not ok then
      show_config_error(cred_err)
      return nil
    end
    if not reword_is_local then
      ok, cred_err = check_credentials('reword', reword_spec, reword, { agent_host = false })
      if not ok then
        show_config_error(cred_err)
        return nil
      end
    end

    result.plan = plan
    result.reword = reword
    result.has_planning = true
  end

  return result
end

-- ===== Pipeline helpers =====

-- run = { parsed, instruction, prompt, query_opts, scanned_files, heavy }
local function run_provider_query(run)
  local parsed = run.parsed
  local query_opts = run.query_opts

  -- Local (Ollama) models: light calls only.
  if parsed.is_local or parsed.provider == 'ollama' then
    if run.heavy then
      common.log("[Pipeline] Local (Ollama) models cannot be used for heavy/agent steps.")
      query_opts.callback("# Configuration Error\n\nLocal (Ollama) models cannot be used for heavy/agent steps.", true)
      return
    end
    ollama_query.askLight(parsed.model, run.instruction, run.prompt, query_opts, M.opts.ollama_host)
    return
  end

  local runner_mod = providers[parsed.provider]
  local api_key = M.opts[parsed.provider .. '_api_key']
  local agent_host = M.opts[parsed.provider .. '_agent_host']

  if run.heavy then
    runner_mod.askHeavy(
      parsed.model,
      run.instruction,
      run.prompt,
      query_opts,
      api_key,
      agent_host,
      query_opts.upload_url,
      query_opts.upload_token,
      query_opts.upload_as_public,
      run.scanned_files
    )
  else
    runner_mod.askLight(
      parsed.model,
      run.instruction,
      run.prompt,
      query_opts,
      api_key,
      query_opts.upload_url,
      query_opts.upload_token,
      query_opts.upload_as_public
    )
  end
end

-- NOTE: the Implement step only treats "# Agent Error" results as failures,
-- whereas Plan and Reword also treat a plain "Error:" prefix as one. The
-- asymmetry is intentional for now; deferred to a functional review.
local function is_step_error(res, is_error, error_opts)
  if is_error then
    return true
  end
  if type(res) ~= 'string' then
    return false
  end
  if vim.startswith(res, common.AGENT_ERROR_PREFIX) then
    return true
  end
  if error_opts and error_opts.include_plain_errors then
    return vim.startswith(res, "Error:")
  end
  return false
end

local PLAN_REWORD_ERROR_RULES = { include_plain_errors = true }
local IMPLEMENT_ERROR_RULES = { include_plain_errors = false }

-- Returns render_status(text): the status line plus the scanned-files table, if any.
local function make_status_renderer(scanned_files_list)
  local show_files_table = (scanned_files_list ~= nil and #scanned_files_list > 0)
  local scanned_files_table = show_files_table and aiconfig.listScannedFilesAsFormattedTable(scanned_files_list) or ""

  return function(status_text)
    if show_files_table then
      return status_text .. "\n\n" .. scanned_files_table
    end
    return status_text
  end
end

local function log_pipeline_start(name, has_planning, scanned_files_list, original_prompt)
  common.log("================================================================================")
  common.log(string.format("[Pipeline] Starting command: '%s' (has_planning = %s)", name, tostring(has_planning)))
  common.log(string.format("[Pipeline] Context files sent: %s", format_context_files(scanned_files_list)))
  common.log(string.format("[Pipeline] User prompt:\n%s", original_prompt))
  common.log("--------------------------------------------------------------------------------")
end

--- Run a prompt through the (optional plan, reword) and implement pipeline.
---@param name string key in M.prompts
---@param input string text given to the command
function M.handle(name, input)
  local def = M.prompts[name]
  if not def then
    common.log("Command '" .. tostring(name) .. "' not found in prompts configuration.")
    return
  end

  local args = {
    locale = M.opts.locale,
    alternate_locale = M.opts.alternate_locale,
    input = input,
    input_encoded = vim.fn.json_encode(input),
  }

  local models = resolve_pipeline_models(name, def)
  if not models then
    return
  end
  local implement_parsed = models.implement
  local plan_parsed = models.plan
  local reword_parsed = models.reword
  local has_planning = models.has_planning

  local scanned_files_list = aiconfig.listScannedFilesFromConfig()
  local render_status = make_status_renderer(scanned_files_list)

  local initial_status = has_planning
    and string.format("[1/3] Planning (%s)...", plan_parsed.full)
    or string.format("Implementing (%s)...", implement_parsed.full)

  local update = show_in_popup(render_status(initial_status), 8, 4)
  local original_prompt = M.fill(def.prompt_tpl, args)

  log_pipeline_start(name, has_planning, scanned_files_list, original_prompt)

  local common_query_opts = {
    upload_url = M.opts.upload_url,
    upload_token = M.opts.upload_token,
    upload_as_public = M.opts.upload_as_public,
  }

  -- Merge step-specific fields with the shared upload settings.
  local function build_query_opts(fields)
    return vim.tbl_extend('force', common_query_opts, fields)
  end

  local execute_plan, execute_reword, execute_implement

  -- Step 1: Plan (only when has_planning is true)
  execute_plan = function()
    update(render_status(string.format("[1/3] Planning (%s)...", plan_parsed.full)))

    common.log(string.format("[Pipeline] === [1/3] Executing Plan (%s) ===", plan_parsed.full))
    common.log(string.format("[Pipeline] Context files sent to Plan: %s", format_context_files(scanned_files_list)))
    common.log(string.format("[Pipeline] Plan prompt:\n%s", original_prompt))

    local query_opts = build_query_opts({
      raw_output = true,
      handleResult = function(output) return output end,
      callback = function(res, is_error)
        if is_step_error(res, is_error, PLAN_REWORD_ERROR_RULES) then
          common.log(string.format("[Pipeline] Error during Plan step: %s", tostring(res)))
          update("# Error during Plan step\n\n" .. tostring(res))
          return
        end

        common.log(string.format("[Pipeline] Plan output received from %s:\n%s", plan_parsed.full, tostring(res)))
        execute_reword(res)
      end,
    })

    run_provider_query({
      parsed = plan_parsed,
      instruction = aiconfig.getSystemInstructions(),
      prompt = aiconfig.buildPlanPrompt(original_prompt),
      query_opts = query_opts,
      scanned_files = scanned_files_list,
      heavy = true,
    })
  end

  -- Step 2: Reword (only when has_planning is true)
  execute_reword = function(plan_text)
    update(render_status(string.format("[2/3] Rewording plan (%s)...", reword_parsed.full)))

    local reword_prompt = string.format(
      "Original user request:\n%s\n\nPlan to execute:\n%s\n\n" ..
      "Refine the plan above into a direct continuation prompt for the implementation model. " ..
      "Enforce that the implementation model must provide the full, complete new content of all files to modify or create, and never return diffs or code snippets.",
      original_prompt,
      plan_text
    )

    common.log(string.format("[Pipeline] === [2/3] Executing Reword (%s) ===", reword_parsed.full))
    if reword_parsed.is_local then
      common.log(string.format("[Pipeline] Reword runs locally on Ollama at %s", tostring(M.opts.ollama_host)))
    end
    common.log(string.format("[Pipeline] Plan received to reword:\n%s", plan_text))
    common.log(string.format("[Pipeline] Reword prompt:\n%s", reword_prompt))

    local query_opts = build_query_opts({
      raw_output = true,
      handleResult = function(output) return output end,
      callback = function(res, is_error)
        if is_step_error(res, is_error, PLAN_REWORD_ERROR_RULES) then
          common.log(string.format("[Pipeline] Error during Reword step: %s", tostring(res)))
          update("# Error during Reword step\n\n" .. tostring(res))
          return
        end

        common.log(string.format("[Pipeline] Reword output received from %s:\n%s", reword_parsed.full, tostring(res)))

        execute_implement(original_prompt .. "\n\n### Implementation Plan & Instructions:\n" .. res)
      end,
    })

    run_provider_query({
      parsed = reword_parsed,
      instruction = aiconfig.getRewordInstructions(),
      prompt = reword_prompt,
      query_opts = query_opts,
      scanned_files = nil,
      heavy = false,
    })
  end

  -- Step 3: Implement (the only step when planning is skipped)
  execute_implement = function(final_implement_prompt)
    if has_planning then
      update(render_status(string.format("[3/3] Implementing (%s)...", implement_parsed.full)))
      common.log(string.format("[Pipeline] === [3/3] Executing Implement (%s) ===", implement_parsed.full))
      common.log(string.format("[Pipeline] Context files sent to Implement: %s", format_context_files(scanned_files_list)))
      common.log(string.format("[Pipeline] Merged prompt+plan:\n%s", final_implement_prompt))
    else
      update(render_status(string.format("Implementing (%s)...", implement_parsed.full)))
      common.log(string.format("[Pipeline] === Executing Implement directly (%s) ===", implement_parsed.full))
      common.log(string.format("[Pipeline] Context files sent to Implement: %s", format_context_files(scanned_files_list)))
      common.log(string.format("[Pipeline] Implement prompt:\n%s", final_implement_prompt))
    end

    local query_opts = build_query_opts({
      raw_output = false,
      handleResult = function(output)
        args.output = output
        args[implement_parsed.provider .. '_output'] = output
        update(M.fill(def.result_tpl or '${output}', args))
        return output
      end,
      callback = function(res, is_error)
        if is_step_error(res, is_error, IMPLEMENT_ERROR_RULES) then
          common.log(string.format("[Pipeline] Error during Implement step: %s", tostring(res)))
          update(res)
        else
          common.log(string.format("[Pipeline] Implementation completed successfully from %s.", implement_parsed.full))
          common.log("================================================================================")
        end
      end,
    })

    run_provider_query({
      parsed = implement_parsed,
      instruction = aiconfig.getSystemInstructions(),
      prompt = aiconfig.buildImplementPrompt(final_implement_prompt),
      query_opts = query_opts,
      scanned_files = scanned_files_list,
      heavy = true,
    })
  end

  if has_planning then
    execute_plan()
  else
    common.log("[Pipeline] Planning stage skipped (plan or reword model not specified).")
    execute_implement(original_prompt)
  end
end

function M.rewordPrompt(input)
  local update = show_in_popup("Rewording prompt with Ollama...", 8, 4)

  ollama_reword.reword(input, M.opts, function(result)
    update(result)
  end)
end

-- ===== Setup =====

-- Merge user options into M.opts; 'prompts' extends the default prompts.
local function merge_options(opts)
  for k, v in pairs(opts) do
    if k == 'prompts' then
      M.prompts = {}
      M.assign(M.prompts, default_prompts)
      M.assign(M.prompts, v)
    elseif M.opts[k] ~= nil then
      M.opts[k] = v
    end
  end
end

local function register_prompt_commands()
  for k, v in pairs(M.prompts) do
    if v.command then
      vim.api.nvim_create_user_command(v.command, function(args)
        local text = args['args']
        if is_empty(text) then
          text = M.getSelectedText(true)
        end
        if not v.require_input or M.hasLetters(text) then
          M.handle(k, text)
        end
      end, { range = true, nargs = '?' })
    end
  end
end

-- Log a warning for every referenced provider that lacks an API key, and for
-- every plan/implement provider that lacks an agent host. Also warn about
-- misuse of the 'local' spec and an unconfigured local reword.
local function warn_about_missing_credentials()
  local referenced_providers = {}
  local agent_providers = {}
  local uses_local_reword = false

  local function collect_providers(models_def)
    if type(models_def) ~= 'table' then return end
    local task_models = common.resolveTaskModels(models_def, nil)
    for task, spec in pairs(task_models) do
      if common.isLocalModelSpec(spec) then
        if task == 'reword' then
          uses_local_reword = true
        else
          common.log(string.format("Warning: 'local' is only supported for the 'reword' task (found for '%s').", task))
        end
      else
        local parsed = common.parseModelSpec(spec)
        if parsed then
          referenced_providers[parsed.provider] = true
          if task == 'plan' or task == 'implement' then
            agent_providers[parsed.provider] = true
          end
        end
      end
    end
  end

  collect_providers(M.opts.models)
  for _, prompt_def in pairs(M.prompts) do
    collect_providers(prompt_def.models)
  end

  for provider, _ in pairs(referenced_providers) do
    local api_key = M.opts[provider .. '_api_key']
    if api_key == nil or api_key == '' then
      common.log(provider .. " API key is not configured; calls using this provider will fail.")
    end
  end

  for provider, _ in pairs(agent_providers) do
    local agent_host = M.opts[provider .. '_agent_host']
    if agent_host == nil or agent_host == '' then
      common.log("Warning: " .. provider .. " agent host (" .. provider .. "_agent_host) is not configured; plan/implement calls using this provider will fail.")
    end
  end

  if uses_local_reword and (is_empty(M.opts.ollama_host) or is_empty(M.opts.ollama_model)) then
    common.log("Warning: reword is set to 'local' but ollama_host/ollama_model is not configured; rewording will fail.")
  end
end

local function register_utility_commands()
  vim.api.nvim_create_user_command('AIRewordPrompt', function(args)
    local text = args['args']
    if is_empty(text) then
      text = M.getSelectedText(true)
    end
    if M.hasLetters(text) then
      M.rewordPrompt(text)
    end
  end, { range = true, nargs = '?' })

  vim.api.nvim_create_user_command('AIListScannedFiles', function()
    show_in_popup(aiconfig.listScannedFilesAsFormattedTable(), 12, 8)
  end, {})

  vim.api.nvim_create_user_command('AIShowSystemInstructions', function()
    show_in_popup(aiconfig.getSystemInstructions(), 12, 8)
  end, {})
end

---@param opts table user options (see M.opts for the available keys)
function M.setup(opts)
  merge_options(opts)
  register_prompt_commands()
  warn_about_missing_credentials()
  register_utility_commands()
end

-- Close the result popup as soon as the cursor moves.
vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
  callback = M.close,
})

return M

