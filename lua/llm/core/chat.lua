local segment = require('llm.util.segment')
local util = require('llm.util')

local M = {}

---@class ChatPrompt
---@field provider Provider The API provider for this prompt
---@field create fun(input: string, context: Context): string | LlmChatContents Converts input and context to the first message text or LlmChatContents
---@field run fun(messages: LlmChatMessage[], config: ChatConfig): table | fun(set_params: fun(params: table): nil ) ) Converts chat messages and config into completion request params
---@field system? string System instruction
---@field params? table Static request parameters
---@field options? table Provider options

---@class LlmChatMessage
---@field role 'user' | 'assistant'
---@field content string

---@alias ChatConfig { system?: string, params?: table, options?: table }

---@class LlmChatContents
---@field config ChatConfig Configuration for this chat buffer, used by chatprompt.run
---@field messages LlmChatMessage[] Messages in the chat buffer

--- Splits lines into array of { role: 'user' | 'assistant', content: string }
--- If first line starts with '> ', then the rest of that line is system message
---@param text string Text of buffer. '\n======\n' denote alternations between user and assistant roles
---@return { messages: { role: 'user'|'assistant', content: string}[], system?: string }
local function split_messages(text)
  local lines = vim.fn.split(text, '\n')
  local messages = {}

  local system;

  local chunk_lines = {}
  local chunk_is_user = true

  --- Insert message and reset/toggle chunk state. User text is trimmed.
  local function add_message()
    local text_ = table.concat(chunk_lines, '\n')

    table.insert(messages, {
      role = chunk_is_user and 'user' or 'assistant',
      content = chunk_is_user and vim.trim(text_) or text_
    })

    chunk_lines = {}
    chunk_is_user = not chunk_is_user
  end

  for i, line in ipairs(lines) do
    if i == 1 then
      system = line:match('^> (.+)')

      if system == nil then
        table.insert(chunk_lines, line)
      end

    elseif line == '======' then
      add_message()
    else
      table.insert(chunk_lines, line)
    end
  end

  -- add text after last `======` if not empty
  if table.concat(chunk_lines, '') ~= '' then
    add_message()
  end

  return {
    system = system,
    messages = messages
  }
end

---@param text string Input text of buffer
---@return { chat: string, config?: table, rest: string }
local function parse_config(text)

  if text:match('^---$') then
    error('Chat buffer must start with chat name, not config')
  end

  if text:match('^>') then
    error('Chat buffer must start with chat name, not system instruction')
  end

  local chat_name, name_rest = text:match('^(.-)\n(.*)')
  local params_text, rest = name_rest:match('%-%-%-\n(.-)\n%-%-%-\n(.*)')

  if chat_name == '' then
    error('Chat buffer must start with chat name, not empty line')
  end

  if params_text == nil then
    return {
      config = {},
      rest = vim.fn.trim(name_rest),
      chat = chat_name
    }
  else
    local config = vim.fn.luaeval(params_text)

    if type(config) ~= 'table' then
      error('Evaluated config text is not a lua table')
    end

    return {
      config = config,
      rest = vim.fn.trim(rest),
      chat = chat_name
    }
  end
end

--- Parse a chat file. Must start with a chat name, can follow with a lua table
--- of config between `---`. If the next line starts with `> `, it is parsed as
--- the system instruction. The rest of the text is parsed as alternating
--- user/assistant messages, with `\n======\n` delimiters.
---@param text string
---@return { contents: LlmChatContents, chat: string }
function M.parse(text)
  local parsed = parse_config(text)
  local messages_and_system = split_messages(parsed.rest)
  parsed.config.system = messages_and_system.system

  return {
    contents = {
      messages = messages_and_system.messages,
      config = parsed.config
    },
    chat = parsed.chat
  }
end

---@param contents LlmChatContents
---@param name string
---@return string
function M.to_string(contents, name)
  local result = name .. '\n'

  if not vim.tbl_isempty(contents.config) then
    -- TODO consider refactoring this so we're not treating system special
    -- Either remove it from contents.config so that it sits next to config
    -- or just let it be a normal config field
    local without_system = util.table.without(contents.config, 'system')

    result = result .. '---\n' .. vim.inspect(without_system) .. '\n---\n'

    if contents.config.system then
      result = result .. '> ' .. contents.config.system .. '\n'
    end
  end


  for i,message in ipairs(contents.messages) do
    if i ~= 1 then
      result = result .. '\n======\n'
    end

    if message.role == 'user' then
      result = result .. '\n' .. message.content .. '\n'
    else
      result = result .. message.content
    end
  end

  return vim.fn.trim(result, '\n', 2) -- trim trailing newline
end

---@param chat_prompt ChatPrompt
---@param chat_name string
---@param input_context InputContext
function M.create_new_chat(chat_prompt, chat_name, input_context)
  local first_message_or_contents = chat_prompt.create(
    input_context.input,
    input_context.context
  )

  local config = {
    options = chat_prompt.options,
    params = chat_prompt.params,
    system = chat_prompt.system,
  }

  ---@type LlmChatContents
  local chat_contents

  if type(first_message_or_contents) == 'string' then
    chat_contents = {
      config = config,
      messages = {
        {
          role = 'user',
          content = first_message_or_contents
        }
      }
    }
  elseif type(first_message_or_contents) == 'table' then
    chat_contents = vim.tbl_deep_extend(
      'force',
      { config = config },
      first_message_or_contents
    )
  else
    error('ChatPrompt.create() needs to return a string for the first message or an LlmChatContents')
  end

  local new_buffer_text = M.to_string(chat_contents, chat_name)

  vim.cmd.vnew()
  vim.o.ft = 'llmchat'
  vim.cmd.syntax({'sync', 'fromstart'})

  vim.api.nvim_buf_set_lines(
    0,
    0,
    0,
    false,
    vim.fn.split(new_buffer_text, '\n')
  )
end

---@param opts { chats?: table<string, ChatPrompt> }
function M.run_chat(opts)
  local buf_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local parsed = M.parse(
    table.concat(buf_lines, '\n')
  )

  local chat_name = assert(
    parsed.chat,
    'Chat buffer first line must be a chat prompt name'
  )

  ---@type ChatPrompt
  local chat_prompt = assert(
    vim.tbl_get(opts, 'chats', chat_name),
    'Chat "' .. chat_name .. '" not found'
  )

  local run_params = chat_prompt.run(
    parsed.contents.messages,
    parsed.contents.config
  )
  if run_params == nil then
    error('Chat prompt run() returned nil')
  end

  local seg = segment.create_segment_at(#buf_lines, 0)

  local last_line = buf_lines[#buf_lines]
  if not last_line or vim.fn.trim(last_line) ~= '' then
    seg.add('\n')
  end

  seg.add('======\n')

  local handlers = {
    on_partial = seg.add,
    on_finish = function()
      seg.add('\n======\n')
      seg.clear_hl()
    end,
    on_error = error
  }

  local merged_options = vim.tbl_deep_extend(
    'force',
    chat_prompt.options or {},
    parsed.contents.config.options or {}
  )

  if type(run_params) == 'function' then
    run_params(function(params)
      local merged_params = vim.tbl_deep_extend(
        'force',
        chat_prompt.params or {},
        parsed.contents.config.params or {},
        params
      )

      chat_prompt.provider.request_completion(
        handlers,
        merged_params,
        merged_options
      )
    end)
  else
    chat_prompt.provider.request_completion(
      handlers,
      vim.tbl_deep_extend(
        'force',
        chat_prompt.params or {},
        parsed.contents.config.params or {},
        run_params
      ),
      merged_options
    )
  end
end

return M
