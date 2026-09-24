local window

function init(plugin)
  package.path = app.fs.joinPath(plugin.path, "?.lua") .. ";"
    .. app.fs.joinPath(plugin.path, "?", "init.lua") .. ";" .. package.path
  local ChatWindow = require("agent.chat_window")

  plugin:newCommand{
    id = "AgentChat",
    title = "Agent Chat",
    group = "edit_insert",
    onclick = function()
      if not window then window = ChatWindow.new{ prefs = plugin.preferences } end
      window:toggle()
    end,
  }
end

function exit(plugin)
  if window then window:close() end
end
