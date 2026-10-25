local conversation = {}

-- Canned phrases of the conversation. They must stay in sync with
-- buildConversationMessages() in code-ai-agent (agent-helpers.ts).
local PHRASES = {
  opening_request = 'I need your help on this project.',
  ask_for_file = 'Please provide the content of the `%s` file.',
  file_content = 'Here is the content of the `%s` file:\n```\n%s\n```\n',
  ask_how_to_proceed = 'How would you like to proceed with this project?',
  ask_what_next = 'What would you like to do next?',
  fallback_user_turn = 'Please let me know how you would like to proceed.',
}

--- Build an ordered multi-turn conversation, mirroring the shape produced
--- server-side by code-ai-agent's buildConversationMessages().
---@param prompt string|nil the final user request/prompt
---@param project_context { filename: string, content: string }[]|nil files, in the order they should appear
---@return { role: "user"|"assistant", content: string }[]
function conversation.build(prompt, project_context)
  local files = project_context or {}
  local sanitized_prompt = vim.trim(prompt or '')

  local messages = {}

  table.insert(messages, { role = 'user', content = PHRASES.opening_request })

  for _, entry in ipairs(files) do
    table.insert(messages, {
      role = 'assistant',
      content = string.format(PHRASES.ask_for_file, entry.filename),
    })
    table.insert(messages, {
      role = 'user',
      content = string.format(PHRASES.file_content, entry.filename, entry.content),
    })
  end

  if #files == 0 and sanitized_prompt == '' then
    table.insert(messages, { role = 'assistant', content = PHRASES.ask_how_to_proceed })
  end

  if sanitized_prompt ~= '' then
    table.insert(messages, { role = 'assistant', content = PHRASES.ask_what_next })
    table.insert(messages, { role = 'user', content = sanitized_prompt })
  end

  -- The conversation must end on a user turn.
  local last_message = messages[#messages]
  if last_message == nil or last_message.role ~= 'user' then
    table.insert(messages, { role = 'user', content = PHRASES.fallback_user_turn })
  end

  return messages
end

return conversation
