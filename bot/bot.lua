package.path = package.path .. ';./bot/?.lua;./lua-telegram-bot/?.lua;./libs/?.lua;./?.lua'

require("./utils")

local f = assert(io.popen('/usr/bin/git describe --tags', 'r'))
VERSION = assert(f:read('*a'))
f:close()

msg_text_max = 4000

-- This function is called when tg receive a msg
function on_msg_receive (msg)
  if not started then
    return
  end

  local receiver = get_receiver(msg)

  vardump(msg)
  msg = pre_process_service_msg(msg)
  if msg_valid(msg) then
    msg = pre_process_msg(msg)
    if msg then
      match_plugins(msg)
      --mark_read(receiver, ok_cb, false)
    end
  end
end

function ok_cb(extra, success, result)
end

function on_binlog_replay_end()
  started = true
  -- See plugins/isup.lua as an example for cron

  _config = load_config()

  -- load plugins
  plugins = {}
  load_plugins()
end

function msg_valid(msg)
  -- Don't process outgoing messages
  if msg.out then
    print('\27[36mNot valid: msg from us\27[39m')
    return false
  end

  -- Before bot was started
  if msg.date < now then
    print('\27[36mNot valid: old msg\27[39m')
    return false
  end

  if msg.unread == 0 then
    print('\27[36mNot valid: readed\27[39m')
    return false
  end

  if not msg.chat.id then
    print('\27[36mNot valid: To id not provided\27[39m')
    return false
  end

  if not msg.from.id then
    print('\27[36mNot valid: From id not provided\27[39m')
    return false
  end

  if msg.from.id == our_id then
    print('\27[36mNot valid: Msg from our id\27[39m')
    return false
  end

  if msg.chat.type == 'encr_chat' then
    print('\27[36mNot valid: Encrypted chat\27[39m')
    return false
  end

  if msg.from.id == 777000 then
    print('\27[36mNot valid: Telegram message\27[39m')
    return false
  end

  return true
end

--
function pre_process_service_msg(msg)
   if msg.service then
      local action = msg.action or {type=""}
      -- Double ! to discriminate of normal actions
      msg.text = "!!tgservice " .. action.type

      -- wipe the data to allow the bot to read service messages
      if msg.out then
         msg.out = false
      end
      if msg.from.id == our_id then
         msg.from.id = 0
      end
   end
   return msg
end

-- Apply plugin.pre_process function
function pre_process_msg(msg)
  for name,plugin in pairs(plugins) do
    if plugin.pre_process and msg then
      print('Preprocess', name)
      msg = plugin.pre_process(msg)
    end
  end

  return msg
end

-- Go over enabled plugins patterns.
function match_plugins(msg)
  for name, plugin in pairs(plugins) do
    match_plugin(plugin, name, msg)
  end
end

-- Check if plugin is on _config.disabled_plugin_on_chat table
local function is_plugin_disabled_on_chat(plugin_name, receiver)
  local disabled_chats = _config.disabled_plugin_on_chat
  -- Table exists and chat has disabled plugins
  if disabled_chats and disabled_chats[receiver] then
    -- Checks if plugin is disabled on this chat
    for disabled_plugin,disabled in pairs(disabled_chats[receiver]) do
      if disabled_plugin == plugin_name and disabled then
        local warning = 'Plugin '..disabled_plugin..' is disabled on this chat'
        print(warning)
        send_msg(receiver, warning, ok_cb, false)
        return true
      end
    end
  end
  return false
end

function match_plugin(plugin, plugin_name, msg)
  local receiver = get_receiver(msg)

  -- Go over patterns. If one matches it's enough.
  for k, pattern in pairs(plugin.patterns) do
    local matches = match_pattern(pattern, msg.text)
    if matches then
      print("msg matches: ", pattern)

      if is_plugin_disabled_on_chat(plugin_name, receiver) then
        print('Disabled')
        return nil
      end
      -- Function exists
      if plugin.run then
        -- If plugin is for privileged users only
        if not warns_user_not_allowed(plugin, msg) then
          local result = plugin.run(msg, matches)
          if result then
            send_msg(receiver, result)
          end
        else
          print('Warn')
        end
      end
      -- One patterns matches
      return
    end
  end
end

-- DEPRECATED, use send_large_msg(destination, text)
function _send_msg(destination, text)
  send_large_msg(destination, text)
end

function send_photo(receiver, file_path, cb, cb_extra)
  bot.sendPhoto(receiver, file_path)
  cb(cb_extra)
end

function original_send_msg(destination, text, cb, extra)
  bot.sendMessage(destination, text, "Markdown")
  cb(extra)
end

function split(str, max_line_length, splitter)
   local lines = {}
   local line
   str:gsub(splitter, function(spc, word)
                            if not line or #line + #spc + #word > max_line_length then
                                table.insert(lines, line)
                                line = word
                            else
                                line = line..spc..word
                            end
                          end)
   table.insert(lines, line)
   return lines
end

function send_queue(extra)
  local messages = extra.messages
  if #messages > 0 then
    local msg = messages[1]
    table.remove(messages, 1)
    local xtr = {
      destination=extra.destination,
      messages=messages
    }
    original_send_msg(extra.destination, msg, send_queue, xtr)
  end
end

function send_msg(destination, text, callback, data)
  msgs = {}
  local space_splitter = '(%s*)(%S+)'
  local line__splitter = '([\n]*)([^\n]+)'
  local parts = 0
  for l, line in ipairs(split(text, msg_text_max, line__splitter)) do
    for w, word in ipairs(split(line, msg_text_max, space_splitter)) do
      table.insert(msgs, word)
      parts = parts + 1
    end
  end
  local xtr = {
    destination=destination,
    messages=msgs
  }
  send_queue(xtr)
end

-- Save the content of _config to config.lua
function save_config( )
  serialize_to_file(_config, './data/config.lua')
  print ('saved config into ./data/config.lua')
end

-- Returns the config from config.lua file.
-- If file doesn't exist, create it.
function load_config( )
  local f = io.open('./data/config.lua', "r")
  -- If config.lua doesn't exist
  if not f then
    print ("Created new config file: data/config.lua")
    create_config()
  else
    f:close()
  end
  local config = loadfile ("./data/config.lua")()
  for v,user in pairs(config.sudo_users) do
    print("Allowed user: " .. user)
  end
  return config
end

-- Create a basic config.json file and saves it.
function create_config( )
  -- A simple config with basic plugins and ourselves as privileged user
  config = {
    enabled_plugins = {
      "9gag",
      "eur",
      "echo",
      "btc",
      "get",
      "giphy",
      "google",
      "gps",
      "help",
      "id",
      "images",
      "img_google",
      "location",
      "media",
      "plugins",
      "channels",
      "set",
      "stats",
      "time",
      "version",
      "weather",
      "xkcd",
      "youtube" },
    sudo_users = {our_id},
    disabled_channels = {}
  }
  serialize_to_file(config, './data/config.lua')
  print ('saved config into ./data/config.lua')
end

function on_our_id (id)
  our_id = id
end

function on_user_update (user, what)
  --vardump (user)
end

function on_chat_update (chat, what)
  --vardump (chat)
end

function on_secret_chat_update (schat, what)
  --vardump (schat)
end

function on_get_difference_end ()
end

-- Enable plugins in config.json
function load_plugins()
  for k, v in pairs(_config.enabled_plugins) do
    print("Loading plugin", v)

    local ok, err =  pcall(function()
      local t = loadfile("plugins/"..v..'.lua')()
      if t.cron ~= nil then
        t.cron_status = 'wait'
      end
      plugins[v] = t
    end)

    if not ok then
      print('\27[31mError loading plugin '..v..'\27[39m')
      print('\27[31m'..err..'\27[39m')
    end

  end
end

-- Cron all the enabled plugins
function cron_plugins()
  -- cron_statuses:
  --   wait
  --   postpone
  --   run
  for name, desc in pairs(plugins) do
    if (desc.cron ~= nil
        and cron_plugin_enabled(desc.name)
        and desc.cron_status == 'wait') then
      desc.cron_status = 'postponed'
      desc.cron_status_change_time = os.date('%d.%m.%Y %H:%M:%S')
      safe_call(desc.cron)
    end
  end
end

-- Start and load values
our_id = 0
now = os.time()
math.randomseed(now)
started = false

local token = tostring(arg[1]) or ""
-- create and configure new bot with set token
bot, extension = require("../lua-telegram-bot/lua-bot-api").configure(token)

local function parseUpdateCallbacks(update)
  if (update) then
    extension.onUpdateReceive(update)
  end
  if (update.message) then
    if (update.message.text) then
      extension.onTextReceive(update.message)
    elseif (update.message.photo) then
      extension.onPhotoReceive(update.message)
    elseif (update.message.audio) then
      extension.onAudioReceive(update.message)
    elseif (update.message.document) then
      extension.onDocumentReceive(update.message)
    elseif (update.message.sticker) then
      extension.onStickerReceive(update.message)
    elseif (update.message.video) then
      extension.onVideoReceive(update.message)
    elseif (update.message.voice) then
      extension.onVoiceReceive(update.message)
    elseif (update.message.contact) then
      extension.onContactReceive(update.message)
    elseif (update.message.location) then
      extension.onLocationReceive(update.message)
    elseif (update.message.left_chat_participant) then
      extension.onLeftChatParticipant(update.message)
    elseif (update.message.new_chat_participant) then
      extension.onNewChatParticipant(update.message)
    elseif (update.message.new_chat_photo) then
      extension.onNewChatPhoto(update.message)
    elseif (update.message.delete_chat_photo) then
      extension.onDeleteChatPhoto(update.message)
    elseif (update.message.group_chat_created) then
      extension.onGroupChatCreated(update.message)
    elseif (update.message.supergroup_chat_created) then
      extension.onSupergroupChatCreated(update.message)
    elseif (update.message.channel_chat_created) then
      extension.onChannelChatCreated(update.message)
    elseif (update.message.migrate_to_chat_id) then
      extension.onMigrateToChatId(update.message)
    elseif (update.message.migrate_from_chat_id) then
      extension.onMigrateFromChatId(update.message)
    else
      extension.onUnknownTypeReceive(update)
    end
  elseif (update.edited_message) then
    extension.onEditedMessageReceive(update.edited_message)
  elseif (update.inline_query) then
    extension.onInlineQueryReceive(update.inline_query)
  elseif (update.chosen_inline_result) then
    extension.onChosenInlineQueryReceive(update.chosen_inline_result)
  elseif (update.callback_query) then
    extension.onCallbackQueryReceive(update.callback_query)
  else
    extension.onUnknownTypeReceive(update)
  end
end

local function run(limit, timeout, upd_interval, cron_function, cron_interval)
  if limit == nil then limit = 1 end
  if timeout == nil then timeout = 0 end
  local offset = 0
  RUNBOT = true
  while RUNBOT == true do
    socket.sleep(upd_interval)
    if cron_function ~= nil and os.time() % cron_interval == 0 then
      cron_function()
    end
    local updates = bot.getUpdates(offset, limit, timeout)
    if(updates) then
      if (updates.result) then
        for key, update in pairs(updates.result) do
          parseUpdateCallbacks(update)
          offset = update.update_id + 1
        end
      end
    end
  end
end

extension.run = run

on_binlog_replay_end()
-- override onMessageReceive function so it does what we want
extension.onTextReceive = function(msg)
  on_msg_receive(msg)
end
extension.onLocationReceive = function(msg)
  msg.text = '[venue]'
  on_msg_receive(msg)
end

-- This runs the internal update and callback handler
-- you can even override run()
extension.run(1, 0, 0.5, cron_plugins, 5)
