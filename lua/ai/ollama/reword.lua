local curl = require('plenary.curl')
local common = require('ai.common')

local reword = {}

-- NOTE: the leading/trailing whitespace inside this string is intentional for
-- now (it is part of the payload sent to Ollama); the block is deliberately not
-- re-indented. Deferred to a functional review.
local SYSTEM_MESSAGE = [[ 
    You are a helpful assistant that is in charge of rewording prompts, to infer and enumerate the requirements, constraints, and any other relevant information that will help the model to generate an accurate and complete response.
    Be carefull to not change the global idea of the prompt, but to make it more clear and detailed for an AI model to understand and generate a better response.
    You infer the requirements and constraints from the prompt, and you enumerate them in a clear and structured way.
    You do not try to execute the prompt, you only reword it to make it more clear and detailed.
    ]]

local function normalize_host(host)
  if vim.endswith(host, "/") then
    return host:sub(1, -2)
  end
  return host
end

-- Priming conversation that leads the model to reword `prompt`.
local function build_messages(prompt)
  return {
    { role = "system", content = SYSTEM_MESSAGE },
    { role = "user", content = "I need your help to reword a prompt." },
    { role = "assistant", content = "Provide me with the prompt you would like to reword, and I will assist you in elaborating it." },
    { role = "user", content = prompt },
    { role = "assistant", content = "What exactly do you want me to do?" },
    { role = "user", content = "I want you to reword the prompt." }
  }
end

local function handle_response(res, callback)
  if res.status ~= 200 then
    common.log("Ollama API error status: " .. tostring(res.status))
    callback("# Ollama API Error (" .. tostring(res.status) .. ")\n\n" .. (res.body or "No response body"))
    return
  end

  local success, data = pcall(vim.fn.json_decode, res.body)
  if not success or not data or not data.message or not data.message.content then
    common.log("Failed to decode Ollama JSON response: " .. (res.body or "Empty body"))
    callback("# Ollama Error\n\nFailed to parse JSON response from Ollama server.")
    return
  end

  callback(data.message.content)
end

---@param prompt string
---@param opts table plugin options (uses `ollama_host` and `ollama_model`)
---@param callback fun(result: string)
function reword.reword(prompt, opts, callback)
  local host = opts.ollama_host or ''
  local model = opts.ollama_model or ''

  if host == '' or model == '' then
    common.log("Ollama host or model is not configured.")
    callback("# Ollama Error\n\nOllama host or model is not configured. Please set `ollama_host` and `ollama_model` in plugin setup options.")
    return
  end

  local url = normalize_host(host) .. "/api/chat"
  local payload = {
    model = model,
    stream = false,
    messages = build_messages(prompt),
  }

  common.log("Sending prompt rewording request to Ollama server at " .. url)

  curl.post(url, {
    headers = {
      ["Content-Type"] = "application/json"
    },
    body = vim.fn.json_encode(payload),
    callback = function(res)
      vim.schedule(function()
        handle_response(res, callback)
      end)
    end
  })
end

return reword
