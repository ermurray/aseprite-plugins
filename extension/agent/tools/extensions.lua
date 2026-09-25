local M = {}

M.DENY = {}
for _, id in ipairs{ "Exit", "CloseFile", "CloseAllFiles", "SaveFile", "SaveFileAs", "SaveFileCopyAs",
  "ExportSpriteSheet", "Options", "KeyboardShortcuts", "RunScript", "DeveloperConsole", "OpenScriptFolder", "AgentChat",
  "AgentSaveClip", "Undo", "Redo", "ReopenClosedFile", "NewFile", "OpenFile", "Launch", "ImportSpriteSheet", "Screenshot" } do
  M.DENY[id] = true
end

function M.list_installed_extensions()
  local dir = app.fs.joinPath(app.fs.userConfigPath, "extensions")
  local out = {}
  if app.fs.isDirectory(dir) then
    for _, name in ipairs(app.fs.listFiles(dir)) do
      local f = io.open(app.fs.joinPath(dir, name, "package.json"), "r")
      if f then
        local ok, pkg = pcall(json.decode, f:read("a"))
        f:close()
        if ok and pkg then
          out[#out + 1] = {
            name = tostring(pkg.name or name),
            displayName = tostring(pkg.displayName or pkg.name or name),
            version = pkg.version and tostring(pkg.version) or nil,
            description = pkg.description and tostring(pkg.description) or nil,
          }
        end
      end
    end
  end
  table.sort(out, function(a, b) return a.displayName:lower() < b.displayName:lower() end)
  return { extensions = out, note = "Commands added by extensions are named by their authors; check each extension's menu or docs." }
end

function M.run_extension_command(args)
  local id = tostring(args.command)
  if M.DENY[id] then error("The command '" .. id .. "' can't be run from the chat.", 0) end
  local ok, fn = pcall(function() return app.command[id] end)
  if not ok or not fn then
    error("Aseprite has no command '" .. id .. "'. Check the extension's menu or docs for its command id.", 0)
  end
  fn()
  app.refresh()
  return { command = id, ran = true }
end

return M
