local conversation = {}

-- Build an ordered multi-turn conversation, mirroring exactly the shape produced
-- server-side by code-ai-agent's buildConversationMessages() (agent-helpers.ts).
--
-- project_context: optional array of { filename = "...", content = "..." }, in the
--   order they should appear in the conversation (same shape as used by
--   provider.lua's askHeavy project_context construction).
-- prompt: optional string, the final user request/prompt.
--
-- Returns: an array of { role = "user"|"assistant", content = "..." } entries.
function conversation.build(prompt, project_context)
  local files = project_context or {}
  local sanitized_prompt = prompt
  if sanitized_prompt == nil then
    sanitized_prompt = ''
  end
  -- Trim leading/trailing whitespace, mirroring `instructions.trim()` / `prompt?.trim()` on the TS side.
  sanitized_prompt = sanitized_prompt:match('^%s*(.-)%s*$') or ''

  local messages = {}

  table.insert(messages, {
    role = 'user',
    content = 'I need your help on this project.',
  })

  for _, entry in ipairs(files) do
    table.insert(messages, {
      role = 'assistant',
      content = string.format('Please provide the content of the `%s` file.', entry.filename),
    })
    table.insert(messages, {
      role = 'user',
      content = string.format('Here is the content of the `%s` file:\n```\n%s\n```\n', entry.filename, entry.content),
    })
  end

  if #files == 0 and sanitized_prompt == '' then
    table.insert(messages, {
      role = 'assistant',
      content = 'How would you like to proceed with this project?',
    })
  end

  if sanitized_prompt ~= '' then
    table.insert(messages, {
      role = 'assistant',
      content = 'What would you like to do next?',
    })
    table.insert(messages, {
      role = 'user',
      content = sanitized_prompt,
    })
  end

  local last_message = messages[#messages]
  if last_message == nil or last_message.role ~= 'user' then
    table.insert(messages, {
      role = 'user',
      content = 'Please let me know how you would like to proceed.',
    })
  end

  return messages
end

return conversation

