local curl = require('plenary.curl')
local common = require('ai.common')

local client = {}

-- Local models can be slow (cold start, CPU inference): be generous (milliseconds).
local LOCAL_REQUEST_TIMEOUT_MS = 300000

--- Strip a trailing '/' from the host.
---@param host string
---@return string
function client.normalize_host(host)
  if vim.endswith(host, "/") then
    return host:sub(1, -2)
  end
  return host
end

--- Send a chat request to Ollama (`/api/chat`, non-streaming).
--- The callback is always invoked on the main loop as `callback(text, is_error)`.
---@param host string
---@param model string
---@param messages table[] array of { role, content }
---@param callback fun(text: string, is_error: boolean)
---@param options table|nil Ollama model options (e.g. { temperature = 0.2 })
function client.chat(host, model, messages, callback, options)
  local url = client.normalize_host(host) .. "/api/chat"
  local payload = {
    model = model,
    stream = false,
    messages = messages,
    options = options,
  }

  common.log("Ollama chat request: url=" .. url .. ", model=" .. tostring(model))

  local success, err = pcall(function()
    curl.post(url, {
      headers = {
        ["Content-Type"] = "application/json",
      },
      body = vim.fn.json_encode(payload),
      timeout = LOCAL_REQUEST_TIMEOUT_MS,
      callback = function(res)
        vim.schedule(function()
          if res.status ~= 200 then
            common.log("Ollama API error status: " .. tostring(res.status))
            callback("# Ollama API Error (" .. tostring(res.status) .. ")\n\n" .. (res.body or "No response body"), true)
            return
          end

          local ok, data = pcall(vim.fn.json_decode, res.body)
          if not ok or type(data) ~= 'table' or type(data.message) ~= 'table' or type(data.message.content) ~= 'string' then
            common.log("Failed to decode Ollama JSON response: " .. (res.body or "Empty body"))
            callback("# Ollama Error\n\nFailed to parse JSON response from Ollama server.", true)
            return
          end

          callback(data.message.content, false)
        end)
      end,
    })
  end)

  if not success then
    local message = string.format("# Ollama Error\n\nException while contacting Ollama at %s: %s", url, tostring(err))
    common.log("Ollama chat exception: " .. message)
    vim.schedule(function()
      callback(message, true)
    end)
  end
end

return client

