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
  anthropic_model = '',
  googleai_model = '',
  openai_model = '',

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
  append_embeded_system_instructions = true,

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


function M.handle(name, input)
  local def = M.prompts[name]
  local width = vim.fn.winwidth(0)
  local height = vim.fn.winheight(0)
  local args = {
    locale = M.opts.locale,
    alternate_locale = M.opts.alternate_locale,
    input = input,
    input_encoded = vim.fn.json_encode(input),
  }

  -- Determine the query mode: per-command override or size-based threshold logic
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
  local update = nil
  if not show_files_table then
    update = M.createPopup(M.fill(def.loading_tpl, args), width - 8, height - 4)
  else
    local scanned_files = aiconfig.listScannedFilesAsFormattedTable(scanned_files_list)
    update = M.createPopup(M.fill(def.loading_tpl .. scanned_files, args), width - 8, height - 4)
  end

  local prompt = M.fill(def.prompt_tpl, args)

  -- Always load system instructions for full conversation parity
  local append_embeded = M.opts.append_embeded_system_instructions
  if def.append_embeded_system_instructions ~= nil then
    append_embeded = def.append_embeded_system_instructions
  end
  local instruction = aiconfig.getSystemInstructions(append_embeded)

  local anthropic_model = def.anthropic_model or M.opts.anthropic_model
  local googleai_model = def.googleai_model or M.opts.googleai_model
  local openai_model = def.openai_model or M.opts.openai_model

  -- If command-level models are set, use them
  if def.anthropic_model and def.anthropic_model ~= '' then
    anthropic_model = def.anthropic_model
  end
  if def.googleai_model and def.googleai_model ~= '' then
    googleai_model = def.googleai_model
  end
  if def.openai_model and def.openai_model ~= '' then
    openai_model = def.openai_model
  end

  -- START: Prepare common options for all LLM queries, including upload details
  local common_query_opts = {
    upload_url = M.opts.upload_url,
    upload_token = M.opts.upload_token,
    upload_as_public = M.opts.upload_as_public,
  }
  -- END: Prepare common options for all LLM queries

  local function handleResult(output, output_key)
    args[output_key] = output
    args.output = (args.anthropic_output or '').. (args.googleai_output or '') .. (args.openai_output or '')
    update(M.fill(def.result_tpl or '${output}', args))
    return output
  end

  local function createProviderOpts(output_key)
    return {
      handleResult = function(output) return handleResult(output, output_key) end,
      callback = function(res)
        -- If res is a string starting with # Agent Error, it means askHeavy failed during chunk transmission
        -- before reaching the final LLM prompt logic. We propagate it to the UI here.
        if type(res) == 'string' and string.sub(res, 1, 13) == "# Agent Error" then
          handleResult(res, output_key)
        end
      end,
      upload_url = common_query_opts.upload_url,
      upload_token = common_query_opts.upload_token,
      upload_as_public = common_query_opts.upload_as_public,
    }
  end

  local askHandleResultAndCallbackAnthropic = createProviderOpts('anthropic_output')
  local askHandleResultAndCallbackGoogleAI = createProviderOpts('googleai_output')
  local askHandleResultAndCallbackOpenAI = createProviderOpts('openai_output')

  if not is_heavy then
    anthropic.askLight(
      anthropic_model,
      instruction,
      prompt,
      askHandleResultAndCallbackAnthropic,
      M.opts.anthropic_api_key,
      common_query_opts.upload_url,
      common_query_opts.upload_token,
      common_query_opts.upload_as_public,
      scanned_files_list
    )
    googleai.askLight(
      googleai_model,
      instruction,
      prompt,
      askHandleResultAndCallbackGoogleAI,
      M.opts.googleai_api_key,
      common_query_opts.upload_url,
      common_query_opts.upload_token,
      common_query_opts.upload_as_public,
      scanned_files_list
    )
    openai.askLight(
      openai_model,
      instruction,
      prompt,
      askHandleResultAndCallbackOpenAI,
      M.opts.openai_api_key,
      common_query_opts.upload_url,
      common_query_opts.upload_token,
      common_query_opts.upload_as_public,
      scanned_files_list
    )
  else
    anthropic.askHeavy(
      anthropic_model,
      instruction,
      prompt,
      askHandleResultAndCallbackAnthropic,
      M.opts.anthropic_api_key,
      M.opts.anthropic_agent_host,
      common_query_opts.upload_url,
      common_query_opts.upload_token,
      common_query_opts.upload_as_public,
      scanned_files_list
    )
    googleai.askHeavy(
      googleai_model,
      instruction,
      prompt,
      askHandleResultAndCallbackGoogleAI,
      M.opts.googleai_api_key,
      M.opts.googleai_agent_host,
      common_query_opts.upload_url,
      common_query_opts.upload_token,
      common_query_opts.upload_as_public,
      scanned_files_list
    )
    openai.askHeavy(
      openai_model,
      instruction,
      prompt,
      askHandleResultAndCallbackOpenAI,
      M.opts.openai_api_key,
      M.opts.openai_agent_host,
      common_query_opts.upload_url,
      common_query_opts.upload_token,
      common_query_opts.upload_as_public,
      scanned_files_list
    )
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

  local providers = {
    { name = 'anthropic', model_key = 'anthropic_model', api_key_key = 'anthropic_api_key' },
    { name = 'googleai', model_key = 'googleai_model', api_key_key = 'googleai_api_key' },
    { name = 'openai', model_key = 'openai_model', api_key_key = 'openai_api_key' },
  }
  for _, provider in ipairs(providers) do
    local model = M.opts[provider.model_key]
    local api_key = M.opts[provider.api_key_key]
    local model_missing = (model == nil or model == '')
    local model_disabled = (model == 'disabled')
    local api_key_missing = (api_key == nil or api_key == '')

    if model_missing then
      M.opts[provider.model_key] = 'disabled'
      common.log(provider.name .. " model is not configured and has been disabled.")
    elseif not model_disabled and api_key_missing then
      M.opts[provider.model_key] = 'disabled'
      common.log(provider.name .. " API key is not configured; provider has been disabled.")
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
