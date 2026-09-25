# Agent Chat: the big manual test

Run these in Aseprite (1.3.18+) after installing the packaged extension. Tick each box; for failures, note the step number and what happened.

Before starting, make:
- one project folder with two saved sprites (say `chars/knight.aseprite` with a few frames and a tag, and `tiles/grass.aseprite`);
- one saved sprite outside any project;
- a PNG to use as a reference tab.

## 0. Install

Requirements: Claude Code installed and logged in (run `claude` once in a terminal), and Node.js 20 or newer (nodejs.org or `brew install node`; nvm is fine).

1. **Quit Aseprite** completely (Cmd+Q).
2. **Remove the development copy**, so you test the real package:
   ```bash
   rm -rf ~/Library/Application\ Support/Aseprite/extensions/aseprite-agent
   ```
3. **Build the package** (skip this if `dist/aseprite-agent-0.9.0.aseprite-extension` already exists):
   ```bash
   cd ~/projects/aseprite-plugins && scripts/package.sh
   ```
4. **Open Aseprite**, go to **Edit → Preferences → Extensions → Add Extension**, and choose
   `~/projects/aseprite-plugins/dist/aseprite-agent-0.9.0.aseprite-extension`.
5. **Restart Aseprite.** If Aseprite asks permission for the extension to run commands or open files, allow it (and note that it asked).

To go back to developing afterwards: remove the extension in Preferences → Extensions, then run `scripts/dev-install.sh`.

## 1. Install and start
- [ ] 1.1 After the install steps above, **Edit → Agent Chat** appears in the menu.
- [ ] 1.2 **Edit → Agent Chat**. The status shows "Starting the assistant...", then "Connected". No terminal is needed.
- [ ] 1.3 Bind a key in Edit → Keyboard Shortcuts. The key toggles the window, and the chat is still there after reopening.
- [ ] 1.4 Kill the bridge (`kill $(python3 -c "import json;print(json.load(open('$HOME/.aseprite-agent/bridge.json'))['pid'])")`) and press **Reconnect**. It restarts automatically.
- [ ] 1.5 Quit Aseprite. Within 15 minutes, `~/.aseprite-agent/bridge.json` disappears and `ps aux | grep bridge.mjs` shows nothing.
- [ ] 1.6 (Optional) Launch Aseprite with `ASEPRITE_AGENT_NODE=/usr/local/bin/node` (Node v10). The chat says Node 20+ is needed.

## 2. Chat basics
- [ ] 2.1 Ask "What do you see?" You get activity lines, then a streamed reply. The thinking spinner shows while Claude works.
- [ ] 2.2 "What exact colors are in the top-left 4x4?" Claude quotes hex values that match.
- [ ] 2.3 A long URL plus "héllo wörld" plus an en dash (3–4) wrap cleanly; the mouse wheel scrolls.
- [ ] 2.4 Press **Stop** mid-reply. Type a follow-up while Claude is replying: a "Still working" note appears. Enter sends.
- [ ] 2.5 Hide the window mid-reply. The status bar shows "Claude replied…" (or "waiting for your approval").
- [ ] 2.6 Slash commands: `/context`, `/model sonnet`, `/recap`, and `/clear` (starts a new chat).
- [ ] 2.7 Quit and reopen Aseprite. The last chat comes back, and Claude remembers it.

## 3. Edits and approvals
- [ ] 3.1 "Add a 5-step skin ramp". A card shows the colors, with Apply; the main button reads **Deny**. Apply, then one Ctrl+Z removes the whole ramp.
- [ ] 3.2 Press Enter on a card: it's denied, and Claude asks what you'd prefer.
- [ ] 3.3 "Mark where my light source is inconsistent". Marks go on "Agent Notes" only.
- [ ] 3.4 Double-click Apply with two cards queued. The second card is not approved blindly.
- [ ] 3.5 Auto-approve on: a layer rename needs no card. Scripts, exports and commands still ask.

## 4. Drafts
- [ ] 4.1 Drafts off, "draw me a knight": one line saying it won't draw it, plus an offer to help.
- [ ] 4.2 Tick **Allow AI drafts** and ask again. A rough blockout appears on the 40% "AI Draft" layer only.

## 5. Projects
- [ ] 5.1 A loose sprite shows an amber "Tip: …" line. **Set up project** (pick DB32 as the palette, and "Apply to this sprite"): `.artproject/` appears, the chat stays, and one Ctrl+Z reverts the palette.
- [ ] 5.2 An unsaved sprite with **Set up project**: Save As appears first.
- [ ] 5.3 "What's in my brief?", then edit `brief.md` by hand and ask again. Then **Project settings**: change the light direction and save.
- [ ] 5.4 "Remember the hero uses a 2px outline". A card, then the line lands in `memory.md`. "Note in the brief that night scenes use the blue ramp". A card, then it's in `brief.md`.
- [ ] 5.5 "What sprites are in this project?", then ask about an unopened one. It's read without leaving a tab open.
- [ ] 5.6 An edit on an unopened sprite: the card says "(opens it as a tab)". After Apply the tab opens, and you stay on yours.
- [ ] 5.7 Switch to a sprite in another project (or outside any). The chat switches. Mid-reply, it switches only after the reply ends.
- [ ] 5.8 **History**: reopen an older chat. **Attach view**: Claude looks at a snapshot first.
- [ ] 5.9 A PNG reference tab: Claude can compare against it, and refuses to edit it.

## 6. FX and maps
- [ ] 6.1 "Dither the sky between these two blues", "clean up my lineart" (pixel-perfect), "snap to the project palette", "selout the outline". Each gets a card and is one undo.
- [ ] 6.2 A lasso selection then an effect: only the selected pixels change.
- [ ] 6.3 "Add a 1px dark stroke and a drop shadow". New layers appear below (inside the group, if the layer is in one).
- [ ] 6.4 "Make normal maps for the knight": `knight_normal.aseprite` and `knight_height.aseprite` appear. "Show it lit from the top-left" gives a preview only.
- [ ] 6.5 "Is my sprite readable?" shows the value and silhouette views.
- [ ] 6.6 Built-ins: "brighten the Body layer a bit", "blur 3", "invert this region".

## 7. Tools, extensions and scripts
- [ ] 7.1 "Set me up for shading with a 2px brush and vertical symmetry". This applies immediately with no card; painting shades and mirrors.
- [ ] 7.2 "Is there an extension for wave effects?" Wave Warp, with a link. "What extensions do I have?"
- [ ] 7.3 "Write a script that exports every tag as a PNG strip". The card shows the code; it's saved under File → Scripts → Agent. "Run it": a separate card, then the output comes back.
- [ ] 7.4 Edit that script by hand, then ask Claude to run it. It refuses until the script is saved again through the chat.

## 8. Clips, imports and exports
- [ ] 8.1 Select an area, **Edit → Save Selection as Clip**; **Clips** shows a preview; **Insert** adds a "Clip: …" layer with the pixels selected.
- [ ] 8.2 Set `clips.max` to 3 in `project.json` and save 4 clips. The card names the clip that will be removed, and pinned clips stay.
- [ ] 8.3 "Bring the knight's helmet into this sprite, mirrored". This imports from the unopened knight.
- [ ] 8.4 "Export the knight as a sprite sheet at 2x with its normal map". The card lists the real folder and files; `knight_sheet.png/json` and `knight_n_sheet.png/json` are written.
- [ ] 8.5 Set exports to `{"location":"folder","path":"exports","mirrorTree":true}` and export again. Files land in `exports/chars/`.
- [ ] 8.6 Open a `.png` as a sprite and "export it as a PNG". This is refused, because it would overwrite the file itself.
