import Foundation

/// What a new library starts with: a guide to every feature, in English and in Thai (a folder each), made of
/// notes that show what they describe — tasks to tick, a table, code, links between them, a template and a
/// smart folder to try. It's all ordinary notes: delete the folders once you know your way around.
enum Welcome {
    static func library(now: Date = Date()) -> [Folder] {
        let tomorrow = MD.dayString(now.addingTimeInterval(86_400))
        let nextWeek = MD.dayString(now.addingTimeInterval(7 * 86_400))
        var home = Folder.builtIn(Folder.rootID, "Cortexy")
        home.notes = [note(start, color: .purple, pinned: true)]

        var english = Folder(name: "Guide (English)")
        english.icon = "book"
        english.color = .purple
        english.notes = guideEnglish(tomorrow: tomorrow, nextWeek: nextWeek).map { note($0) }

        var thai = Folder(name: "คู่มือ (ภาษาไทย)")
        thai.icon = "book.closed"
        thai.color = .pink
        thai.notes = guideThai(tomorrow: tomorrow, nextWeek: nextWeek).map { note($0) }

        var templates = Folder(name: "Templates")
        templates.icon = "doc.on.doc"
        templates.notes = [note(meetingTemplate), note(journalTemplate)]

        var todo = Folder(name: "To Do")
        todo.icon = "checklist"
        todo.query = "is:todo"

        return Store.withBuiltIns([home, english, thai, templates, todo])
    }

    private static func note(_ text: String, color: NoteColor = .none, pinned: Bool = false) -> Note {
        var n = Note()
        n.text = text
        n.color = color
        n.pinned = pinned
        return n
    }

    // MARK: Home

    static let start = """
    # Welcome to Cortexy 👋
    Notes at the edge of your screen. Push the pointer against the right edge, or press ⌃⌥N.

    **English:** open the folder *Guide (English)* — each note there is one part of the app.
    **ภาษาไทย:** เปิดโฟลเดอร์ *คู่มือ (ภาษาไทย)* — แต่ละโน้ตอธิบายแต่ละส่วนของแอป

    - [ ] Tick me: click the box · คลิกช่องนี้เพื่อติ๊ก
    - [ ] Rest the pointer on a note card to preview it · พักเมาส์บนการ์ดเพื่อดู preview

    Delete the guides whenever you like (right-click → Delete). · ลบคู่มือทิ้งได้เมื่อไม่ใช้แล้ว
    """

    // MARK: English

    static func guideEnglish(tomorrow: String, nextWeek: String) -> [String] { [
        """
        # Getting started
        Cortexy is a panel of notes that slides in from the edge of the screen, over whatever you're doing. #guide

        ## Opening and closing
        - Push the pointer against the **right edge** of the screen (away from the corners), or press **⌃⌥N** from any app
        - Or click the menu bar icon, or open Cortexy again from Finder or Spotlight
        - **Esc** or **⌘W** hides it; opened by the pointer, it slides away once the pointer leaves
        - Two-finger swipe toward the edge pushes it away, like Notification Center

        ## Notes and folders
        - **⌘N** new note, **⇧⌘N** new folder — notes can live on the home page too
        - The panel is as tall as what it shows: a short note, a short panel
        - **⌘,** opens Settings: the edge, the width, themes, fonts, shortcuts

        Next: [[Writing]] · All the guides: [[Find anything]]
        """,
        """
        # Writing
        Markdown, shown as you type: the markup hides when you leave the line. #guide

        ## Text
        **Bold** ⌘B · *italic* ⌘I · `code` ⌘E · ~~strike~~ ⇧⌘X · ==highlight== ⇧⌘H · [a link](https://www.apple.com) ⌘K
        Footnotes work too.[^1]

        ## Lists
        - Bullets (⇧⌘8); Tab nests an item, ⇧Tab brings it back
          - like this
        1. Numbered (⇧⌘7) — Return continues, the numbers follow
        2. Return on an empty item ends the list
        > Quotes (⇧⌘9) carry on with Return too

        ## Tables
        Click the ⊞ button under the editor. Tab moves to the next cell, Return at the end of a row adds one.

        | Feature | Shortcut | Works in Thai |
        | --- | :-: | --: |
        | Bold | ⌘B | ✓ |
        | Checklist | ⌘L | ✓ |

        ## Code
        ```swift
        let note = "colored by language"
        print(note)
        ```
        Right-click a note → **Code Mode** turns the whole note into code. The ⧉ at a code block's corner copies it.

        ## Quick moves
        - **⌥⌘↑ / ⌥⌘↓** move the line (or the selected lines) up and down
        - **⌘-click** a code block, heading, list item or quote copies it; **⌥⌘-click** copies a link
        - Double-click an attached file or image to preview it with Quick Look

        ## Callouts and more
        > [!tip] Callouts
        > `> [!tip] Title` makes a colored box (note, info, tip, success, question, warning, danger, bug, example, quote…). Add `-` after `]` to fold it, `+` to fold it open; the chevron at its right end switches.

        - `==🔴text==` highlights in red (🟠 🟢 🔵 🟣 too); plain `==text==` stays yellow
        - Right-click an image → **Image Size**; double-click it to see it full size
        - Type **/** at a line's start for headings, lists, a callout, a table, today's date…
        - Select words: bold, italic, code, highlight and link buttons float above them
        - Right-click a note → **Read Only**: it can't be edited by accident (its checkboxes still tick)

        ## Pasting
        - Paste a link over selected words to link them; a bare link gets its page's title
        - Text copied from a web page, Notes, Docs or Word arrives as Markdown; pasted code goes into a code block; **⌥⇧⌘V** pastes plain
        - Copy from a note and paste into Mail or Pages: the formatting comes along
        - Rest the pointer on a `[[link]]` to read that note, or on a web link to see its page's card

        ## Capture
        - Set a **Capture box** shortcut (Settings → Shortcuts): type a thought from any app, ↩ adds it to your *Inbox* note or today's note without opening the panel
        - Settings → Shortcuts → **Web Clipper**: a bookmark that saves the page you're on as a note in *Clippings*
        - Right-click a note → **Show With App**: opening the panel from that app lists the note first
        - Words in images and screenshots are found by search; right-click an image to copy its text; **Screenshot as Text** (Aa menu) types out what you capture
        - PDFs show their first page; double-click for the whole thing

        ---
        The bar under the editor has all of this; its **More Formatting** button adds headings, a code block, a divider, images and screenshots.

        [^1]: Click the little number to jump here.
        """,
        """
        # Tasks and reminders
        Checklists with dates, gathered on one page. #guide

        - [ ] Click a box to tick it (or ⌘L to make a line a task)
        - [ ] Try the Upcoming page 📅 \(tomorrow)
        - [ ] A task with a time 📅 \(nextWeek) 09:30
        - [x] Done tasks stay, crossed out

        ## Dates
        - Add `📅 2026-10-05` or `@2026-10-05` (a time is optional), or press the calendar button under the editor
        - Red is overdue, orange is today, later ones are in the theme's color
        - **Upcoming** on the home page lists every dated task; pointing at one marks the others from the same note
        - Reminders come as notifications (allow them when asked; Settings → General sets the hour); each has snooze buttons, and clicking one opens the note at the task

        ## More about tasks
        - [/] `- [/]` is in progress, `- [-]` is cancelled (type `/` for **Mark In Progress** or **Mark Cancelled**)
        - [ ] Add `🔁 every week` (or `every 2 days`, `every month`, `ทุกเดือน`): ticking it adds the next one with its new date

        ## Sums
        rent = 12,000
        food = 4,500
        rent + food =

        A line ending in `=` shows its result; `name = …` lines set names for later.

        The smart folder *To Do* on the home page shows every note with something left to do.
        """,
        """
        # Organizing
        Folders inside folders, as deep as you like. #guide

        - **Drag** a note or folder onto a folder to move it; onto *Recently Deleted* to delete it
        - **⌘-click** or **⇧-click** to pick several, **⌘A** for all; then move, color, pin or delete them together
        - Right-click a note: **Pin to Top**, colors, **Duplicate**, **Archive**, **Move to**, **Fold**
        - Right-click a folder: **Icon…** (symbols or emoji), colors, **Rename**; in a folder, ⋯ → **Sort Notes By** (edited, created, title or by hand)
        - The arrow before a folder opens it in place; the title at the top is a menu of the folders above
        - Deleted things wait in **Recently Deleted** (30 days, set in Settings); Undo right after, or ⌘Z
        - **Archive** takes a note out of its folder and out of search, without deleting it
        - **⌘[** or ← goes back to where you were; **⌘]** goes forward again
        - Right-click a tag on the home screen → **Rename**: every note changes (a name that exists merges them); a chevron opens a tag's `#tag/sub-tags`
        - ⌘P → **Show Attachments** lists every file and the notes using it, and clears out the unused ones; **Open a Random Note** rediscovers old ones

        Next: [[Find anything]]
        """,
        """
        # Find anything
        Search, quick open and commands. #guide

        ## Search (⌘F; in a note, ⇧⌘F)
        Click the search field for hints, or type:
        - `#guide` notes with a tag · `tag:guide`
        - `is:todo` `is:done` `is:task` `is:pinned` `is:archived`
        - `path:Work` only in one folder · `"exact phrase"` · `-word` without it
        - **Save as Smart Folder** keeps a search as a folder (like *To Do*)

        ## Quick open and commands
        - **⌘O** jumps to any note, folder or tag as you type (Thai too)
        - **⌘P** runs any command — or type `>` in ⌘O or the search field
        - Arrow keys and Return work in all of these

        ## Tags
        Write `#anything` in a note. The home page lists your tags; click one to see its notes.

        Next: [[Linking notes]]
        """,
        """
        # Linking notes
        Connect ideas, then see them as a map. #guide

        - Type `[[` and pick a note: [[Getting started]] — click it to go there
        - `[[Writing|another name]]` shows other text for the same link
        - `[[Note#Heading]]` opens a note at that heading (type `#` after the title to pick one); `[[#Heading]]` jumps within this note; `[[Note#^id]]` goes to the line ending in `^id`
        - Notes from Obsidian keep their `---` properties at the top: they don't become the title, `tags:` count as tags and `aliases:` are other names links can use
        - A link to a note that doesn't exist makes it when clicked
        - Rename a note and the links to it follow
        - Under a note, **N linked here** lists the notes that link to it
        - **⌘G** opens the graph: dots are notes, lines are links. Drag, zoom, point at a dot to light up its links, click to open. Right-click a note → **Show in Graph** for just its neighbourhood.

        Next: [[Preview and windows]]
        """,
        """
        # Preview and windows
        Read without opening. #guide

        - **Rest the pointer** on a note card: its text shows in a card beside the panel
        - Rest on a **folder**: its contents. Click a subfolder to go in (the path bar goes back); rest on a note in it to read it in a second card
        - Click a preview to open the note in the panel
        - Right-click a note → **Open in Window**: a floating window that stays on top and comes back after a restart
        - Settings → General: the delays, the width, or no preview at all
        - **⇧⌘P** keeps the panel open while you work in other apps (the pin in its header lets it close again); Settings → General also sets its opacity

        Next: [[Templates and daily notes]]
        """,
        """
        # Templates and daily notes
        Start the same kind of note the same way. #guide

        - Notes in the folder **Templates** are templates (two are there to try)
        - Make a note from one: ⋯ → New from Template, ⌘P, or a shortcut of your own
        - In a template: `{{date}}` `{{time}}` `{{weekday}}` `{{folder}}` `{{date:MMMM yyyy}}`, and `{{cursor}}` for where typing starts
        - **⌘D** opens today's note in the folder *Daily* (Settings sets the folder, a template and the date format)
        - **⇧⌘D** opens a calendar: dots mark days with a note, click any day for its note; it also makes this week's and this month's notes (each can have its own template)
        - Under a note: what it links to, what links to it, and notes that **mention** it without a link (one click links them)
        - Put `goal: 500` in a note's frontmatter to see its word count against it
        - Rest on a version in Version History to see what changed since (added in green, removed in red)
        - Settings → Shortcuts → **Your shortcuts**: keys for "new note from template" (into a folder you pick, or home) or for opening a note — in Cortexy, or from any app

        Next: [[Privacy and safety]]
        """,
        """
        # Privacy and safety
        Your notes stay on your Mac, in one file you can see. #guide

        ## Locked notes and folders
        - Right-click a note → **Lock Note…**, or a folder → **Lock Folder…**: sealed with a password (AES-GCM); the title stays visible
        - One password opens them all; Touch ID can stand in for it (Settings → Data)
        - They lock again when the panel closes, the Mac sleeps or the screen locks
        - **If the password is forgotten, they can't be opened, not even by Cortexy.** Settings → Data → Change Password…

        ## Nothing lost
        - **Version history**: right-click → Version History…; rest on a version to see it, Restore (and Undo)
        - Daily backups in the data folder; **Export…** writes every note as a Markdown file
        - Put the data folder in iCloud Drive to share notes between Macs (Settings → Data)
        - Settings → Data → **Keep a Markdown copy of every note**: plain .md files, kept up to date, for Obsidian, iA Writer, AI tools or git
        - Settings → Data → **Import…** brings in an Obsidian vault, a Bear or Apple Notes Markdown export, or any folder of .md files
        - Notes show up in **Spotlight** (locked ones never); pick one there to open it here

        ## Screen sharing
        Settings → General → **Hide Cortexy from screen sharing and recordings** leaves its windows out of meetings, recordings and screenshots.

        ## Web images
        Images from the web wait until you press **Load** in their note: fetching one tells its server you opened the note.

        Next: [[Make it yours]]
        """,
        """
        # Make it yours
        Settings (⌘,). #guide

        - **Appearance**: color themes (or your own), fonts — each font is marked if it has no Thai or no English — sizes, spacing, density, corners, light or dark
        - **General**: which screen edge, how fast it opens and closes, the width, the preview, the menu bar icon, launch at login
        - **Shortcuts**: the global ones, and shortcuts of your own
        - **Data**: where notes are kept, Recently Deleted, backups, versions, locked notes
        - Every tab has **Restore Defaults…**

        That's the tour. Back to the start: [[Getting started]]
        """,
    ] }

    // MARK: Thai

    static func guideThai(tomorrow: String, nextWeek: String) -> [String] { [
        """
        # เริ่มต้นใช้งาน
        Cortexy คือ panel โน้ตที่เลื่อนออกมาจากขอบจอ ทับบนงานที่ทำอยู่ #คู่มือ

        ## เปิดและปิด
        - ดันเมาส์ชน **ขอบขวา** ของจอ (ห่างจากมุมจอ) หรือกด **⌃⌥N** จากแอปไหนก็ได้
        - หรือคลิกไอคอนที่ menu bar หรือเปิด Cortexy อีกครั้งจาก Finder / Spotlight
        - **Esc** หรือ **⌘W** เพื่อซ่อน ถ้าเปิดด้วยเมาส์ เอาเมาส์ออกแล้วจะเลื่อนกลับเอง
        - ปัดสองนิ้วไปทางขอบจอเพื่อดันกลับ เหมือน Notification Center

        ## โน้ตและโฟลเดอร์
        - **⌘N** โน้ตใหม่ **⇧⌘N** โฟลเดอร์ใหม่ วางโน้ตไว้ที่หน้าแรกได้เลย
        - panel สูงเท่าเนื้อหา โน้ตสั้น panel ก็สั้น
        - **⌘,** เปิด Settings: ขอบจอ ความกว้าง ธีม ฟอนต์ คีย์ลัด

        ถัดไป: [[การเขียน]] · ค้นหาทุกอย่าง: [[ค้นหา]]
        """,
        """
        # การเขียน
        เขียนเป็น Markdown แต่เห็นผลทันที เครื่องหมายจะซ่อนเมื่อออกจากบรรทัด #คู่มือ

        ## ข้อความ
        **ตัวหนา** ⌘B · *ตัวเอียง* ⌘I · `โค้ด` ⌘E · ~~ขีดฆ่า~~ ⇧⌘X · ==ไฮไลต์== ⇧⌘H · [ลิงก์](https://www.apple.com/th/) ⌘K
        มีเชิงอรรถด้วย[^1]

        ## รายการ
        - bullet (⇧⌘8) กด Tab เพื่อย่อหน้าเข้า ⇧Tab เพื่อถอยออก
          - แบบนี้
        1. ตัวเลข (⇧⌘7) กด Return แล้วขึ้นข้อถัดไป เลขเรียงเอง
        2. กด Return ที่ข้อว่างเพื่อจบรายการ
        > quote (⇧⌘9) กด Return ก็ต่อให้เหมือนกัน

        ## ตาราง
        กดปุ่ม ⊞ ใต้ editor แล้ว Tab ไปช่องถัดไป Return ท้ายแถวเพื่อเพิ่มแถว

        | ฟีเจอร์ | คีย์ลัด | ภาษาไทย |
        | --- | :-: | --: |
        | ตัวหนา | ⌘B | ✓ |
        | checklist | ⌘L | ✓ |

        ## โค้ด
        ```swift
        let note = "สีตามภาษา"
        print(note)
        ```
        คลิกขวาที่โน้ต → **Code Mode** เพื่อให้ทั้งโน้ตเป็นโค้ด ปุ่ม ⧉ ที่มุม code block คัดลอกโค้ดนั้น

        ## ทางลัด
        - **⌥⌘↑ / ⌥⌘↓** ย้ายบรรทัด (หรือบรรทัดที่เลือก) ขึ้นลง
        - **⌘-click** ที่ code block หัวข้อ รายการ หรือ quote เพื่อคัดลอก · **⌥⌘-click** คัดลอกลิงก์
        - ดับเบิลคลิกไฟล์แนบหรือรูปเพื่อดูด้วย Quick Look

        ## Callout และอื่นๆ
        > [!tip] Callout
        > `> [!tip] หัวข้อ` เป็นกล่องสี (note, info, tip, success, question, warning, danger, bug, example, quote…) ใส่ `-` หลัง `]` เพื่อพับเก็บ หรือ `+` ให้พับได้แต่เปิดไว้ กดลูกศรด้านขวาเพื่อพับ/กาง

        - `==🔴ข้อความ==` ไฮไลต์สีแดง (มี 🟠 🟢 🔵 🟣 ด้วย) ส่วน `==ข้อความ==` ธรรมดาเป็นสีเหลือง
        - คลิกขวารูป → **Image Size** เปลี่ยนขนาด · ดับเบิลคลิกเพื่อดูรูปเต็ม
        - พิมพ์ **/** ต้นบรรทัด เพื่อเลือกหัวข้อ, list, callout, ตาราง, วันที่วันนี้…
        - เลือกข้อความ จะมีปุ่มตัวหนา ตัวเอียง โค้ด ไฮไลต์ และลิงก์ลอยขึ้นมา
        - คลิกขวาโน้ต → **Read Only** กันแก้โดยไม่ตั้งใจ (ยังติ๊ก checkbox ได้)

        ## การวาง
        - วางลิงก์ทับคำที่เลือกไว้ คำนั้นจะกลายเป็นลิงก์ ถ้าวางลิงก์เปล่าๆ จะได้ชื่อหน้าเว็บมาเป็นข้อความ
        - ข้อความที่คัดลอกจากเว็บ, Notes, Docs หรือ Word กลายเป็น Markdown · วางโค้ดจะอยู่ใน code block ให้ · **⌥⇧⌘V** วางแบบข้อความล้วน
        - คัดลอกจากโน้ตไปวางใน Mail หรือ Pages ได้รูปแบบตัวอักษรไปด้วย
        - พักเมาส์บน `[[ลิงก์]]` เพื่ออ่านโน้ตนั้น หรือบนลิงก์เว็บเพื่อดูการ์ดของหน้าเว็บ

        ## จดเร็ว
        - ตั้งคีย์ลัด **Capture box** (Settings → Shortcuts) พิมพ์จากแอปไหนก็ได้ ↩ แล้วต่อท้ายโน้ต *Inbox* หรือโน้ตวันนี้ โดยไม่ต้องเปิด panel
        - Settings → Shortcuts → **Web Clipper** ได้ bookmark ที่เก็บหน้าเว็บที่เปิดอยู่เป็นโน้ตในโฟลเดอร์ *Clippings*
        - คลิกขวาโน้ต → **Show With App** เปิด panel จากแอปนั้นแล้วโน้ตนี้จะขึ้นก่อน
        - ค้นหาเจอคำในรูปและ screenshot ด้วย · คลิกขวารูปเพื่อคัดลอกข้อความในรูป · **Screenshot as Text** (เมนู Aa) จับภาพแล้วได้เป็นข้อความ
        - PDF แสดงหน้าแรก ดับเบิลคลิกเพื่อดูทั้งไฟล์

        ---
        แถบใต้ editor มีทุกอย่างนี้ ปุ่ม **More Formatting** มีหัวข้อ code block เส้นคั่น รูป และภาพหน้าจอเพิ่ม

        [^1]: คลิกตัวเลขเล็กๆ เพื่อกระโดดมาตรงนี้
        """,
        """
        # งานและการแจ้งเตือน
        checklist ที่ใส่วันได้ และรวมไว้ในหน้าเดียว #คู่มือ

        - [ ] คลิกช่องเพื่อติ๊ก (หรือ ⌘L เพื่อทำบรรทัดให้เป็นงาน)
        - [ ] ลองเปิดหน้า Upcoming 📅 \(tomorrow)
        - [ ] งานที่มีเวลา 📅 \(nextWeek) 09:30
        - [x] งานที่เสร็จแล้วยังอยู่ แต่ถูกขีดฆ่า

        ## วันที่
        - เติม `📅 2026-10-05` หรือ `@2026-10-05` (ใส่เวลาหรือไม่ก็ได้) หรือกดปุ่มปฏิทินใต้ editor
        - ใช้ปี พ.ศ. หรือเลขไทยก็ได้ เช่น `📅 ๒๕๖๙-๑๐-๐๕`
        - แดง = เลยกำหนด ส้ม = วันนี้ สีของธีม = วันถัดไป
        - หน้า **Upcoming** ที่หน้าแรกรวมงานที่มีวันทั้งหมด ชี้ที่งานไหน งานอื่นจากโน้ตเดียวกันจะขึ้นสีด้วย
        - แจ้งเตือนผ่าน notification ของ macOS (กดอนุญาตตอนถาม ตั้งเวลาได้ใน Settings → General) มีปุ่มเลื่อนเตือน และคลิกแล้วเปิดโน้ตที่บรรทัดของงาน

        ## งานเพิ่มเติม
        - [/] `- [/]` = กำลังทำ, `- [-]` = ยกเลิก (พิมพ์ `/` แล้วเลือก **Mark In Progress** หรือ **Mark Cancelled**)
        - [ ] ใส่ `🔁 ทุกสัปดาห์` (หรือ `ทุก 2 วัน`, `ทุกเดือน`, `every week`) ติ๊กแล้วจะได้งานรอบถัดไปพร้อมวันใหม่

        ## คิดเลข
        ค่าเช่า = 12,000
        ค่ากิน = 4,500
        ค่าเช่า + ค่ากิน =

        บรรทัดที่ลงท้ายด้วย `=` จะแสดงผลลัพธ์ ส่วนบรรทัด `ชื่อ = …` ตั้งชื่อไว้ใช้ทีหลัง

        smart folder *To Do* ที่หน้าแรกรวมทุกโน้ตที่ยังมีงานค้าง
        """,
        """
        # จัดระเบียบ
        โฟลเดอร์ซ้อนในโฟลเดอร์ได้ไม่จำกัดชั้น #คู่มือ

        - **ลาก** โน้ตหรือโฟลเดอร์ไปวางบนโฟลเดอร์เพื่อย้าย หรือวางบน *Recently Deleted* เพื่อลบ
        - **⌘-click** หรือ **⇧-click** เลือกหลายอัน **⌘A** เลือกทั้งหมด แล้วย้าย ติดสี ปักหมุด หรือลบทีเดียว
        - คลิกขวาที่โน้ต: **Pin to Top**, สี, **Duplicate**, **Archive**, **Move to**, **Fold**
        - คลิกขวาที่โฟลเดอร์: **Icon…** (สัญลักษณ์หรือ emoji), สี, **Rename** ส่วนการเรียงโน้ตอยู่ที่ ⋯ → **Sort Notes By** (วันแก้ วันสร้าง ชื่อ หรือลากเอง)
        - ลูกศรหน้าโฟลเดอร์ = กางในหน้าเดิม ชื่อด้านบนคือเมนูของโฟลเดอร์ชั้นบน
        - ของที่ลบจะรออยู่ใน **Recently Deleted** (30 วัน ตั้งได้) กด Undo ทันทีหรือ ⌘Z
        - **Archive** เก็บโน้ตออกจากโฟลเดอร์และผลค้นหา โดยไม่ลบ
        - **⌘[** หรือ ← ย้อนกลับไปที่เดิม · **⌘]** ไปข้างหน้าอีกครั้ง
        - คลิกขวา tag ที่หน้าแรก → **Rename** เปลี่ยนทุกโน้ต (ถ้าชื่อซ้ำกับ tag ที่มีอยู่จะรวมกัน) · ลูกศรข้าง tag เปิด `#tag/tag-ย่อย`
        - ⌘P → **Show Attachments** ดูไฟล์แนบทั้งหมดว่าโน้ตไหนใช้ และล้างไฟล์ที่ไม่ได้ใช้ · **Open a Random Note** สุ่มเปิดโน้ตเก่า

        ถัดไป: [[ค้นหา]]
        """,
        """
        # ค้นหา
        ค้นหา เปิดเร็ว และคำสั่ง #คู่มือ

        ## ค้นหา (⌘F; ในโน้ตใช้ ⇧⌘F)
        คลิกช่องค้นหาจะมีคำแนะนำ หรือพิมพ์:
        - `#คู่มือ` โน้ตที่มีแท็ก · `tag:คู่มือ`
        - `is:todo` `is:done` `is:task` `is:pinned` `is:archived`
        - `path:Work` เฉพาะโฟลเดอร์เดียว · `"วลีตรงๆ"` · `-คำ` ไม่เอาคำนี้
        - ค้นภาษาไทยได้ แยกวรรณยุกต์ ("ข้าว" ไม่เจอ "ข่าว")
        - **Save as Smart Folder** เก็บการค้นหาเป็นโฟลเดอร์ (เหมือน *To Do*)

        ## เปิดเร็วและคำสั่ง
        - **⌘O** ไปที่โน้ต โฟลเดอร์ หรือแท็กไหนก็ได้ พิมพ์ไทยแค่บางส่วนก็เจอ
        - **⌘P** สั่งงานได้ทุกอย่าง หรือพิมพ์ `>` ใน ⌘O หรือช่องค้นหา
        - ลูกศรและ Return ใช้ได้ทุกที่

        ## แท็ก
        พิมพ์ `#อะไรก็ได้` ในโน้ต (ติดกับคำไทยได้ เช่น `ส่งงาน#ด่วน`) หน้าแรกจะรวมแท็กไว้ คลิกเพื่อดูโน้ต

        ถัดไป: [[เชื่อมโน้ต]]
        """,
        """
        # เชื่อมโน้ต
        เชื่อมความคิดเข้าหากัน แล้วดูเป็นแผนที่ #คู่มือ

        - พิมพ์ `[[` แล้วเลือกโน้ต: [[เริ่มต้นใช้งาน]] คลิกเพื่อไปที่โน้ตนั้น
        - `[[การเขียน|ชื่ออื่น]]` แสดงข้อความอื่นแต่ลิงก์ไปที่เดิม
        - `[[โน้ต#หัวข้อ]]` เปิดโน้ตแล้วไปที่หัวข้อนั้น (พิมพ์ `#` หลังชื่อโน้ตแล้วเลือกหัวข้อได้) · `[[#หัวข้อ]]` ไปหัวข้อในโน้ตนี้ · `[[โน้ต#^id]]` ไปบรรทัดที่ลงท้ายด้วย `^id`
        - โน้ตจาก Obsidian ที่มี `---` properties ด้านบน: ไม่ถูกใช้เป็นชื่อโน้ต, `tags:` นับเป็น tag, `aliases:` เป็นชื่ออื่นที่ลิงก์ใช้ได้
        - ลิงก์ไปโน้ตที่ยังไม่มี คลิกแล้วจะสร้างให้
        - เปลี่ยนชื่อโน้ต ลิงก์ที่ชี้มาจะเปลี่ยนตาม
        - ใต้โน้ต **N linked here** บอกว่ามีโน้ตไหนลิงก์มาหา
        - **⌘G** เปิดกราฟ: จุด = โน้ต เส้น = ลิงก์ ลาก ซูม ชี้ที่จุดเพื่อดูลิงก์ คลิกเพื่อเปิด คลิกขวาโน้ต → **Show in Graph** ดูเฉพาะรอบๆ

        ถัดไป: [[Preview และหน้าต่าง]]
        """,
        """
        # Preview และหน้าต่าง
        อ่านได้โดยไม่ต้องเปิด #คู่มือ

        - **พักเมาส์** บนการ์ดโน้ต จะเห็นเนื้อหาในการ์ดข้าง panel
        - พักบน **โฟลเดอร์** จะเห็นของข้างใน คลิกโฟลเดอร์ย่อยเพื่อเข้าไป (แถบ path กดย้อนได้) พักบนโน้ตในนั้นเพื่ออ่านในการ์ดที่สอง
        - คลิก preview เพื่อเปิดโน้ตใน panel
        - คลิกขวาโน้ต → **Open in Window** เป็นหน้าต่างลอยอยู่บนสุด เปิดแอปใหม่ก็ยังอยู่
        - Settings → General: ตั้งเวลา ความกว้าง หรือปิด preview
        - **⇧⌘P** ให้ panel ค้างไว้ระหว่างทำงานในแอปอื่น (กดหมุดที่หัว panel เพื่อให้ปิดได้อีกครั้ง) และปรับความโปร่งใสได้ใน Settings → General

        ถัดไป: [[Template และโน้ตประจำวัน]]
        """,
        """
        # Template และโน้ตประจำวัน
        เริ่มโน้ตแบบเดิมด้วยหน้าตาเดิมทุกครั้ง #คู่มือ

        - โน้ตในโฟลเดอร์ **Templates** คือ template (มีให้ลอง 2 อัน)
        - สร้างโน้ตจาก template: ⋯ → New from Template, ⌘P หรือคีย์ลัดที่ตั้งเอง
        - ใน template ใช้ `{{date}}` `{{time}}` `{{weekday}}` `{{folder}}` `{{date:d MMMM yyyy}}` และ `{{cursor}}` = ตำแหน่งเริ่มพิมพ์
        - **⌘D** เปิดโน้ตของวันนี้ในโฟลเดอร์ *Daily* (ตั้งชื่อโฟลเดอร์ template และรูปแบบวันที่ได้ใน Settings ตั้งชื่อเดือนเป็นภาษาไทยได้)
        - **⇧⌘D** เปิดปฏิทิน: จุดคือวันที่มีโน้ต คลิกวันไหนก็ได้เพื่อเปิดโน้ตของวันนั้น และสร้างโน้ตประจำสัปดาห์/เดือนได้ (ตั้ง template แยกได้)
        - ใต้โน้ตบอกว่าลิงก์ไปไหน ใครลิงก์มา และโน้ตที่**พูดถึง**โน้ตนี้แต่ยังไม่ได้ลิงก์ (คลิกเดียวเพื่อลิงก์)
        - ใส่ `goal: 500` ใน frontmatter เพื่อดูจำนวนคำเทียบเป้า
        - พักเมาส์บนเวอร์ชันใน Version History เพื่อดูว่าเปลี่ยนอะไรไปบ้าง (เพิ่ม = เขียว, ลบ = แดง)
        - Settings → Shortcuts → **Your shortcuts**: ตั้งคีย์ลัดเอง เช่น "โน้ตใหม่จาก template" (ลงโฟลเดอร์ที่เลือก หรือหน้าแรก) หรือเปิดโน้ต ใช้ใน Cortexy หรือจากทุกแอป

        ถัดไป: [[ความเป็นส่วนตัว]]
        """,
        """
        # ความเป็นส่วนตัว
        โน้ตอยู่ในเครื่องคุณ ในไฟล์เดียวที่เปิดดูได้ #คู่มือ

        ## ล็อกโน้ตและโฟลเดอร์
        - คลิกขวาโน้ต → **Lock Note…** หรือโฟลเดอร์ → **Lock Folder…** เข้ารหัสด้วยรหัสผ่าน (AES-GCM) ยังเห็นชื่อโน้ต
        - รหัสเดียวเปิดได้ทั้งหมด ใช้ Touch ID แทนได้ (Settings → Data)
        - ล็อกเองเมื่อปิด panel เครื่อง sleep หรือล็อกจอ
        - **ถ้าลืมรหัส จะเปิดไม่ได้อีก แม้แต่ Cortexy เอง** เปลี่ยนรหัสได้ที่ Settings → Data → Change Password…

        ## ไม่มีอะไรหาย
        - **ประวัติเวอร์ชัน**: คลิกขวา → Version History… พักเมาส์ดูแต่ละเวอร์ชัน แล้ว Restore (Undo ได้)
        - backup ทุกวันในโฟลเดอร์ข้อมูล **Export…** เขียนทุกโน้ตออกเป็นไฟล์ Markdown
        - ย้ายโฟลเดอร์ข้อมูลไปไว้ใน iCloud Drive เพื่อใช้โน้ตร่วมกันหลายเครื่อง (Settings → Data)
        - Settings → Data → **Keep a Markdown copy of every note** เก็บสำเนาเป็นไฟล์ .md ที่อัปเดตตลอด ใช้กับ Obsidian, iA Writer, เครื่องมือ AI หรือ git ได้
        - Settings → Data → **Import…** นำเข้า Obsidian vault, ไฟล์ Markdown ที่ export จาก Bear หรือ Apple Notes หรือโฟลเดอร์ .md อะไรก็ได้
        - ค้นโน้ตจาก **Spotlight** ได้ (ยกเว้นโน้ตที่ล็อก) เลือกแล้วจะเปิดใน Cortexy

        ## แชร์จอ
        Settings → General → **Hide Cortexy from screen sharing and recordings** ซ่อนหน้าต่างของ Cortexy จากการประชุม การอัดจอ และ screenshot

        ## รูปจากเว็บ
        รูปจากเว็บจะรอให้กด **Load** ในโน้ตนั้นก่อน เพราะการโหลดจะบอกเว็บต้นทางว่าคุณเปิดโน้ต

        ถัดไป: [[ปรับแต่ง]]
        """,
        """
        # ปรับแต่ง
        Settings (⌘,) #คู่มือ

        - **Appearance**: ธีมสี (หรือสร้างเอง) ฟอนต์ ซึ่งบอกชัดว่าฟอนต์ไหนไม่มีตัวไทยหรืออังกฤษ ขนาด ระยะบรรทัด ความหนาแน่น ความโค้ง สว่างหรือมืด
        - **General**: ขอบจอซ้ายหรือขวา ความเร็วเปิดปิด ความกว้าง preview ไอคอน menu bar เปิดตอนเข้าเครื่อง
        - **Shortcuts**: คีย์ลัด global และคีย์ลัดที่ตั้งเอง
        - **Data**: ที่เก็บโน้ต Recently Deleted backup เวอร์ชัน โน้ตที่ล็อก
        - ทุกแท็บมี **Restore Defaults…**

        จบทัวร์แล้ว กลับไปเริ่ม: [[เริ่มต้นใช้งาน]]
        """,
    ] }

    // MARK: Templates

    static let meetingTemplate = """
    # Meeting · {{date}}
    **Who:**
    **About:** {{cursor}}

    ## Notes

    ## Next steps
    - [ ]
    """

    static let journalTemplate = """
    # บันทึกประจำวัน {{date:d MMMM yyyy}}
    ## วันนี้ทำอะไร
    - {{cursor}}

    ## ขอบคุณสำหรับ
    -
    """
}
