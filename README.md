# Cortexy

A side-of-the-screen notes app for macOS 26+. Push the pointer against the screen edge or press **⌃⌥N** and the panel
slides out. It is only as tall as what it shows, hanging from the top of the screen like the Dynamic Island: a short
note makes a short panel, and the panel grows as you type, up to the height of the screen.

Current version: **0.14.2**. What each version added or fixed: [CHANGELOG.md](CHANGELOG.md) (in Thai).

## Build and install

Only the Xcode Command Line Tools are needed (`xcode-select --install`): no Xcode, no Apple Developer account.

```bash
./build.sh install   # build → /Applications/Cortexy.app → launch
./build.sh           # build only → build/Cortexy.app
./build.sh test      # run the tests
```

- Manual test checklist, feature by feature (how to use it, what you should see): [TESTING.md](TESTING.md) (in Thai)
- Smoothness meter (hitch ms per second; the screen must be awake and unlocked): `tools/smooth/tour.sh [scenario]`,
  or compare with an older version: `REF=v0.2.1 tools/smooth/tour.sh typing`
- Plan for moving to Xcode (App Intents, widgets, share extension, notarizing): [XCODE_PLAN.md](XCODE_PLAN.md) (in Thai)

The app is signed ad hoc, so a build made on your own Mac opens straight away.

### Running it on another Mac

```bash
./build.sh dist      # → build/Cortexy-<version>.zip, for both Apple silicon and Intel
```

What the other Mac needs:
- **macOS 26 (Tahoe) or later**: the app uses macOS 26's Liquid Glass. Intel Macs work if they run macOS 26 (the last
  release for Intel).
- Nothing else to install: unzip and drag `Cortexy.app` into Applications.
- **First launch**: the app is signed ad hoc (not with a Developer ID), so macOS says it can't verify the developer.
  Open it once, then go to System Settings → Privacy & Security, scroll down and click **Open Anyway**
  (or in Terminal: `xattr -dr com.apple.quarantine /Applications/Cortexy.app`).
- macOS asks for permissions the first time a feature needs them: **Notifications** (task reminders), **Screen
  Recording** (Insert Screenshot), Keychain (Touch ID for locked notes). Accessibility is not needed.
- The first launch adds guide notes covering every feature, in English and Thai (`Sources/Cortexy/Welcome.swift`).
  Delete them whenever you like.
- Data lives in `~/Library/Application Support/Cortexy` (can be moved to an iCloud Drive folder in Settings → Data).

**Trying it as a first-time user without touching the Cortexy you use**
- Closest to a new Mac: System Settings → Users & Groups → Add User, then log in as that user (put the zip in
  `/Users/Shared`). Notes, settings, hotkeys and the lock password are all separate from yours.
- Quicker: quit your running Cortexy first (two copies fight over the hotkeys), then run from Terminal
  `CORTEXY_DATA_DIR=~/Desktop/cortexy-demo ~/Downloads/Cortexy.app/Contents/MacOS/Cortexy`.
  The notes go into the new folder (with the full guide), but **settings are shared with your real copy**, so don't
  change themes, shortcuts or Data settings while trying it. To stop, quit and open `/Applications/Cortexy.app` as
  usual; `~/Desktop/cortexy-demo` can be deleted.

To give it to people without the Open Anyway step, you need the Apple Developer Program ($99 a year): sign with a
Developer ID certificate and notarize (`xcrun notarytool` comes with the Command Line Tools; no Xcode needed).

## Features

**Opening the panel**: push the pointer against the screen edge (the corners are left for hot corners) · a hotkey
(your choice) · the Open Bar, a thin strip at the screen edge · the menu bar icon · opening the app again from
Finder or Spotlight. Works over full-screen apps, with Stage Manager and on several displays ·
**⇧⌘P keeps the panel open** while you click other apps · adjustable **opacity** · **hide from screen sharing and
recordings** (Settings → General)

**Organizing**: folders nest without limit · notes can live on the home page, outside any folder · sort notes by
date edited, date created, title or by hand (per folder, in the ⋯ menu) · **Recently Deleted**: Undo (or ⌘Z) right
after deleting, restore within 30 days · **Archive** takes notes out of folders and search results · fold and unfold
subfolders in place (the arrow before a folder) · click the page title to jump to the folder above · drag notes and
folders onto a folder to move them (folders: drop on the middle of the row) or onto Recently Deleted to delete ·
select several (⌘-click, ⇧-click, ⌘A), then move, color, pin, archive or delete them at once · folder icons (SF
Symbols or emoji) · the home page has Folders / Smart Folders / Library (Archive, Recently Deleted) / Tags / Notes ·
duplicate a note · Outline jumps to a heading · colors (background or side bar) · pins · drag to reorder notes and
folders (dragging into or out of the pinned group pins or unpins) · fold long notes · move folders · search every
folder · reopens where you left off

**Search and links**: **⌘O** quick open (notes, folders, #tags, fuzzy) · **⌘P** command palette (or type `>` in ⌘O) ·
`#tag` (click to see its notes, a tag list on the home page, suggestions as you type `#`) ·
`[[Note title]]` / `[[Note title|text]]` link to another note (a missing note is created, suggestions as you type
`[[`, renaming a note updates the links to it) · `[[Note#Heading]]` goes to a heading (type `#` for its headings),
`[[#Heading]]` within the same note, `[[Note#^id]]` goes to the line ending in `^id` ·
**Embeds**: `![[Note]]` on a line of its own shows that note read-only, `![[Note#Heading]]` just that section. With the
caret on the line you see `![[…]]` to edit, with the card under it; elsewhere just the card. Click its title to open
the note · **frontmatter** (Obsidian's `---` properties) shows dimmed and is never taken as the title, `tags:` count as
tags, `aliases:` are other names to link to · under a note, "N linked here" = backlinks, "N links" = outgoing links,
"N mentions" = notes that name it without linking (one click links them) · **⌘] Forward** · **Random note** (⌘P) ·
**Rename tag** (right-click a tag on the home page; an existing name merges them) and nested tags as a tree ·
**Show Attachments** (⌘P): every attachment, and clearing out unused ones · graph **Color by** folder or tag ·
Version History shows a **diff** against now · reading time, and a word goal with `goal:` in the frontmatter ·
**⌘G Graph**: dots are notes, lines are `[[links]]` (optionally #tags as teal dots, or hide notes without links).
Drag dots to arrange, drag the background to pan, scroll or pinch to zoom, hover a dot to highlight its links, click
to open the note in the panel; "Around this note" shows only notes within 2 links (right-click a note → Show in
Graph) · the search field has helpers: `#` lists tags · `is:` filters (todo, done, pinned…) · `path:` a folder ·
`"phrase"` · `-word` · `>` commands; Tab takes the first · **Lock a folder** (right-click a folder → Lock Folder…):
every note in it and its subfolders is encrypted with the locked-notes password and stays out of search, tags, ⌘O,
the graph and previews until unlocked; notes written while it's open are encrypted when it locks again ·
advanced search: `"phrase"` `-exclude` `#tag` `tag:x` `path:Work` `is:todo` `is:done` `is:task` `is:pinned`
`is:archived` · search only the open folder · matches highlighted · **Save as Smart Folder** keeps a search as a folder

**Writing**: **Markdown tables** (the ⊞ button in the bottom bar; columns line up by themselves, `:-:` centers, `--:`
right-aligns; click into a table to edit its source, Tab/⇧Tab to the next or previous cell, Tab in the last cell or ↩
at a row's end adds a row) · **code colors** by the language after ``` (swift, js/ts, python, go, rust, java/kotlin,
c/c++, ruby, shell, sql, json/yaml) · `==highlight==` (`==🔴…==` 🟠 🟢 🔵 🟣 for other colors) · **Callouts**
`> [!tip] Title` (a box colored by type; `-`/`+` makes it foldable) · **`/` menu** at the start of a line · a
**floating format bar** over selected text · image size `![alt|400](…)` (right-click an image → Image Size) ·
**Read Only** per note · footnotes `[^1]` (click to go to `[^1]: text`) · **Templates**: notes in a "Templates"
folder → ⋯ → New from Template (variables `{{date}}` `{{time}}` `{{weekday}}` `{{folder}}` `{{date:MMMM yyyy}}`,
`{{cursor}}` = where typing starts) · **⌘D daily note** in a "Daily" folder (**⇧⌘D calendar**: hover a day to see
its note and tasks, orange marks = days with tasks, click a day or a week number, weekly and monthly notes with their
own templates, `{{week}}`). Folder name, template, date format and hotkey are set in Settings

**Power**: **Version history** (right-click → Version History; hover a version to preview it, Restore with Undo;
kept in `History/`) · **floating windows** (right-click → Open in Window: always on top, remembers its place, stays
open across relaunches) · **web images** `![](https://…)` (loaded in the background and cached; can be turned off) ·
**due dates** `- [ ] task 📅 2026-10-05 14:30` (or `@2026-10-05`, or the calendar button under the editor): red =
overdue, orange = today, theme color = later · an **Upcoming** page and macOS **notifications** (click one to open
the note at the task's line; snooze buttons for 10 minutes, 1 hour, tomorrow) · ticked tasks sink below the open ones
(right-click → Delete Checked Items) · task states `- [/]` in progress, `- [-]` cancelled · **repeating tasks**
`🔁 every week` / `🔁 ทุกเดือน` (ticking one adds the next) · **math in notes**: a line ending in `=` shows its result,
`name = value` sets a variable · **Lock a note** (right-click → Lock Note: one password for all, AES-GCM; files,
backups, history and exports hold no plain text; locks itself when the panel closes or the screen sleeps; Touch ID
works; **a forgotten password can't be recovered**)

**Note cards**: just the title (search results add the matching line; Settings → Appearance can show several lines,
looking as they do when the note is open) · **hover a card** for a fixed-size preview card beside the panel, level
with the row, showing the whole note; it scrolls, goes away when the pointer leaves, click to edit · hover a
**folder** (or a Smart Folder, Archive, Upcoming, Recently Deleted) to preview its contents; click a subfolder to go
into it inside the same card (the path bar on top goes back), hover a note in the list for a same-size reading card
beside it, click a note or ↗ to open it in the panel (Settings → General: on/off, delay before showing, delay
before hiding, width) · **web images** in a note wait for Load, note by note (loading tells the website you opened
the note), or can be allowed for every note in Settings

**In Settings**: General: screen edge, panel open and close delays at the edge, width, previews, tags on the home
page, how long Undo stays offered, Tab in code mode · Appearance: color theme, font (says clearly which fonts lack
Thai or English), size, line and paragraph spacing, heading sizes, list indent, code font, density, corner radius,
lines per card, Light/Dark · Shortcuts: global shortcuts and your own (a new note from a template into a chosen
folder, or opening a note; inside Cortexy or from any app) · Data: data folder, change the locked-notes password,
how long Recently Deleted keeps notes, how many backups to keep

**Content**: Markdown with its markup hidden (`# heading`, `**bold**`, `*italic*`, `~~strike~~`, `` `code` ``, code
blocks, quotes, `[link](url)`) · checklists tick both in the editor and on cards · Return continues a list,
Tab/⇧Tab indents · images (paste, drag, choose a file, or **take a screenshot**) · attached files and folders
(double-click to open) · `#ff8800` shows as its color · **⌥⌘↑/↓ moves lines** · **⌘-click** copies a code block,
heading, list item or quote (⌥⌘-click copies a link) · a ⧉ copy button on each code block · double-click an
attachment for **Quick Look** · **paste a link over selected words** to link them, a bare pasted link gets **the
page's title** (`utm_…` and other trackers stripped) · paste from the web, Notes, Docs or Word as **Markdown**, pasted
code goes into a code block, ⌥⇧⌘V pastes plain text · copying out to Mail or Pages keeps rich text · **hover a link**
for a preview of the note or a card of the web page (asking websites can be turned off in Settings) · **Snippets**
(click the card to copy) · **Code mode** per note · drag text, files, images or links from other apps to make a new
note (drag to the screen edge and the panel opens to take it) · hover buttons on cards: copy / fold

**Smooth**: typing in long notes doesn't lag (only edited paragraphs are restyled) · saving happens in the
background · images are decoded at the size they're shown (a 12 MP photo doesn't take tens of MB of memory) and load
in the background on cards · one animation timing across the app, all of it off with Reduce Motion

**Look**: Liquid Glass · 42 color themes, plus your own (panel, card and accent colors) · **type chosen apart from the
theme**: any font on the Mac (or the theme's suggestion), size, line and paragraph spacing, heading sizes, code
font · **Layout**: density, corner radius, lines per card, hide the format bar or dates · force Light, Dark or
follow the system · Reduce Motion · VoiceOver labels

**Data**: saves by itself · daily backups kept for 14 days · a damaged file is set aside, never overwritten · choose
your own data folder → put it in **iCloud Drive, OneDrive or Dropbox to sync between Macs** (edited on two Macs at
once, the other version is kept as a conflict file) · export every note as `.md` · **Print / Save as PDF**
(right-click a note) · **Markdown mirror** (Settings → Data): a `.md` copy of every note, updated on each save
(`Markdown/` in the data folder by default; only changed files are written; no locked notes) · **two-way** (turn on
"Bring edits made in the copy back"): edit the files in Obsidian and the notes follow; a new `.md` file = a new note,
renaming or moving a file renames or moves its note, deleting a file sends its note to Recently Deleted, edited on
both sides at once = both versions kept · **Import** a Markdown folder (an Obsidian vault, a Bear or Apple Notes
export, TextBundles: subfolders, frontmatter, images `![[…]]`/`![](…)`, links to .md files → `[[…]]`) ·
**Spotlight** finds notes (never locked ones) · export or copy a note as an image · no analytics, no telemetry

## Keyboard shortcuts

| | |
|---|---|
| Show / hide the panel | ⌃⌥N (change it in Settings → Shortcuts) · Esc / ⌘W hides |
| New note / new folder | ⌘N / ⇧⌘N, in the open folder (a global "New note" hotkey can be set) |
| Daily note | ⌘D (a global "Today's note" hotkey can be set) · ⇧⌘D calendar |
| Search / back | ⌘F (in a note: find in it, ⌘G next · ⇧⌘F: search all notes) / ⌘[ or ← (back where you came from, search results included) · ⌘] forward |
| Quick open / command palette | ⌘O / ⌘P |
| Link graph | ⌘G |
| Keep the panel open | ⇧⌘P |
| Select / open / fold / delete | ↑ ↓ / ↩ or → / Space / ⌘⌫ |
| Move a note to another folder | ⇧⌘M |
| Select several | ⌘-click · ⇧-click · ⌘A · Esc cancels · ⌘⌫ deletes the selection |
| Formatting | ⌘B · ⌘I · ⌘E code · ⌘K link · ⌘L checklist · ⇧⌘X strike · ⇧⌘8 bullets · ⇧⌘7 numbers · ⇧⌘9 quote · ⇧⌘H highlight · ⇥ indent (the Aa button in the format bar also has code block and divider) |
| Move lines | ⌥⌘↑ / ⌥⌘↓ |
| Paste as plain text | ⌥⇧⌘V |
| Settings | ⌘, |

Shortcuts work with a Thai keyboard layout too.

## AI agents and the command line

`Cortexy.app/Contents/Helpers/cortexy`: `list` · `search <words>` · `read <note title>` · `new <text> [--folder F]` ·
`append <text> [--to inbox|today|title]` · `mcp`.
It only reads `cortexy.json`; writes go through the app (`cortexy://`). It never sees locked notes, locked folders or
Recently Deleted.

```bash
claude mcp add cortexy -- "/Applications/Cortexy.app/Contents/Helpers/cortexy" mcp   # Claude Code
```

Claude Desktop: Settings → Data → Copy for Claude Desktop, then paste into its config. Tools: `search_notes`,
`read_note`, `list_notes`, `create_note`, `append_to_note`.

## Working with other apps (Raycast, Alfred, Shortcuts, PopClip)

**URL scheme**

```bash
open "cortexy://new?text=Buy%20milk&folder=Home"
```

`cortexy://show` · `hide` · `toggle` · `new?text=…&folder=…` · `append?text=…&to=inbox|today|title` · `capture` ·
`search?q=…` · `open?title=…` · `tag/name`

**AppleScript** (in Shortcuts, use the "Run AppleScript" action)

```applescript
tell application "Cortexy" to add note "Buy milk" in folder "Home"
tell application "Cortexy" to append text "milk" in note "Groceries" -- without "in note": the Inbox note
tell application "Cortexy" to search notes "milk"
tell application "Cortexy" to toggle panel
```

**Capture box**: set its shortcut in Settings → Shortcuts; type and press ↩ to add to the Inbox or today's note
without opening the panel (`cortexy://capture` opens it too) · **Web clipper**: Settings → Shortcuts → Copy
Bookmarklet, then paste it as a browser bookmark's address (saves the page title, link and selected text into a
Clippings folder) · **notes tied to an app** (right-click a note → Show With App) · **OCR**: search finds words in
images (read on the Mac, Thai and English, kept in `OCR/`; images in locked notes are never read), right-click an
image → Copy Text, Screenshot as Text · PDFs show their first page

**Services**: select text in any app → right-click → Services → **New Cortexy Note** (give it a shortcut in System
Settings → Keyboard → Keyboard Shortcuts → Services)

## Where the data is

By default `~/Library/Application Support/Cortexy/`: `cortexy.json` (all notes), `attachments/` (images and files),
`Backups/`, `History/` (each note's versions), `OCR/` (text read from images, for search), `Markdown/` (if the mirror
is on). Change it in Settings → Data.

## Limits without Xcode or an Apple Developer account

- **Native Shortcuts actions** (App Intents) need an Xcode build → use AppleScript or the URL scheme from Shortcuts
- **Share extension and widgets** need Xcode → use the Services menu
- **CloudKit sync** needs a Developer Team → use a folder in iCloud Drive

[XCODE_PLAN.md](XCODE_PLAN.md) lays out the steps for each.

## Code map

| File | What it does |
|---|---|
| `CortexyApp.swift` | entry point, menu bar, URL scheme, Services |
| `Panel.swift` | the side panel, hot edge, hotkeys (Carbon), Open Bar, keyboard shortcuts, settings keys (`Prefs`) |
| `Nav.swift` | navigation state and shared actions (create, delete, drag and drop, screenshots, export, links, daily notes) |
| `Views.swift` | root view, header, editor screen, toolbar, menus, calendar, attachments page |
| `Lists.swift` | folder and note lists, cards, drag and drop |
| `Preview.swift` | the hover preview cards (notes, folders, web pages, calendar days, version diffs) |
| `Graph.swift` | the link graph window |
| `NoteWindow.swift` | a note in its own floating window |
| `Reminders.swift` | notifications for tasks with due dates, snooze |
| `Lock.swift` | encrypting locked notes and folders, Keychain, Touch ID |
| `Editor.swift` | MarkdownTextView: loading, drawing (checkboxes, callouts, sums, embed cards), clicks and keys, paste and copy, the suggestion list, link previews, Quick Look |
| `Styler.swift` | live Markdown styling, fonts and sizes (`TextStyle`), image/file/PDF attachments, embed cards, callout types |
| `MarkdownEditor.swift` | the editor in SwiftUI, the floating format bar, the suggestion list |
| `Markdown.swift` | line-level Markdown logic: links, tags, frontmatter, embeds, tables, tasks and dates, search (tested) |
| `Clipboard.swift` | pasting links and code, HTML → Markdown, Markdown → HTML |
| `Calc.swift` | math in notes (its own parser) |
| `Store.swift` | models, saving, backups, sync, attachments, export (tested) |
| `Media.swift` | web images, web link titles and cards, OCR of images |
| `Library.swift` | Markdown mirror (two-way), importing .md folders, Spotlight |
| `Welcome.swift` | the guide notes added on first launch (English and Thai) |
| `Sources/cortexy-cli/main.swift` | the `cortexy` command and MCP server (in the app's `Contents/Helpers`) |
| `Theme.swift` | the 42 themes and your own |
| `Settings.swift` | the Settings window, hotkey recorder, moving the data folder |
| `Scripting.swift` + `Resources/Cortexy.sdef` | AppleScript, Services |
| `Snapshot.swift` | debug only: walks every screen to take test screenshots |
| `tools/smooth/` | the smoothness meter (`tour.sh`) |
| `tools/demo/` | scripts that record the feature demo video |
| `tools/make-icon.swift` | builds `Resources/AppIcon.icns` from `Resources/AppIcon-art.png` |
