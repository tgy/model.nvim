local curl = require("llm.curl")
local util = require("llm.util")

local M = {}

local function extract_data(event_string)
  local success, data = pcall(util.json.decode, event_string:gsub('^data: ', ''))

  if success and (data or {}).choices ~= nil then
    return {
      content = (data.choices[1].delta or {}).content,
      finish_reason = data.choices[1].finish_reason
    }
  end
end

local function default_prompt_builder(input, _)
  return {
    messages = {
      { content = input,
        role = "user"
      }
    }
  }
end

---@param prompt string
---@param handlers StreamHandlers
---@param params any Additional options for OpenAI endpoint
---@return nil
function M.request_completion_stream(prompt, handlers, params)
  local _all_content = ""

  local function handle_raw(raw_data)
    local items = util.string.split_pattern(raw_data, "\n\ndata: ")

    for _, item in ipairs(items) do
      local data = extract_data(item)

      if data ~= nil then
        if data.content ~= nil then
          _all_content = _all_content .. data.content
          handlers.on_partial(data.content)
        end

        if data.finish_reason ~= nil then
          handlers.on_finish(_all_content, data.finish_reason)
        end
      else
        local response = util.json.decode(item)

        if response ~= nil then
          handlers.on_error(response, 'response')
        else
          if not item:match("^%[DONE%]") then
            handlers.on_error(item, 'item')
          end
        end
      end
    end
  end

  local function handle_error(error)
    handlers.on_error(error, 'curl')
  end

  return curl.stream({
    headers = {
      Authorization = 'Bearer ' .. util.env('OPENAI_API_KEY'),
      ['Content-Type']= 'application/json',
    },
    method = 'POST',
    url = 'https://api.openai.com/v1/chat/completions',
    body = vim.tbl_deep_extend("force", {
      stream = true,
      model = "gpt-3.5-turbo"
    }, M.prompt_builder(prompt, {
        filename = util.buf.filename()
      }), (params or {}))
  }, handle_raw, handle_error)
end

function M.initialize(opts)
  local _opts = opts or {}

  M.api_key = util.env("OPENAI_API_KEY")
  M.prompt_builder = _opts.prompt_builder or default_prompt_builder
end

return M
