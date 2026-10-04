# Cortexy

แอปโน้ตข้างจอสำหรับ macOS 26+ — ดันเมาส์ชนขอบจอหรือกด **⌃⌥N** แล้ว panel จะเลื่อนออกมา (สูงเท่าที่มีเนื้อหา ห้อยจากขอบบนจอแบบ Dynamic Island — โน้ตสั้น panel ก็สั้น, พิมพ์ยาวขึ้น panel ก็ยืดตาม จนสุดความสูงจอ)

## Build & ติดตั้ง

ใช้แค่ Xcode Command Line Tools (`xcode-select --install`) ไม่ต้องมี Xcode, ไม่ต้องมี Apple Developer account

```bash
./build.sh install   # build → /Applications/Cortexy.app → เปิด
./build.sh           # build อย่างเดียว → build/Cortexy.app
./build.sh test      # รันเทสต์
```

แอปเซ็นแบบ ad-hoc (build บนเครื่องตัวเองจึงเปิดได้เลย)

แต่ละเวอร์ชันเพิ่ม/แก้อะไร: [CHANGELOG.md](CHANGELOG.md)

### Running it on another Mac (ส่งให้คนอื่นใช้)

```bash
./build.sh dist      # → build/Cortexy-<version>.zip ใช้ได้ทั้ง Apple silicon และ Intel
```

สิ่งที่เครื่องปลายทางต้องมี/ต้องทำ:
- **macOS 26 (Tahoe) ขึ้นไป** — ใช้ Liquid Glass ของ macOS 26; Intel Mac ใช้ได้ถ้าลง macOS 26 ได้ (macOS 26 เป็นรุ่นสุดท้ายของ Intel)
- ไม่ต้องลง Xcode หรืออะไรเพิ่ม: แตก zip แล้วลาก `Cortexy.app` ไปไว้ใน Applications
- **เปิดครั้งแรก**: แอปเซ็นแบบ ad-hoc (ไม่ใช่ Developer ID) macOS จะบอกว่าตรวจสอบผู้พัฒนาไม่ได้ —
  เปิดหนึ่งครั้ง แล้วไป System Settings → Privacy & Security → เลื่อนลงไปกด **Open Anyway**
  (หรือใน Terminal: `xattr -dr com.apple.quarantine /Applications/Cortexy.app`)
- ระบบจะขออนุญาตเองเมื่อใช้ฟีเจอร์นั้นครั้งแรก: **Notifications** (แจ้งเตือนงาน), **Screen Recording** (Insert Screenshot),
  Keychain (ถ้าเปิด Touch ID ปลดล็อกโน้ต) — ไม่ต้องใช้ Accessibility
- เปิดครั้งแรกจะมีโน้ตคู่มือทุกฟีเจอร์ให้ทั้งภาษาอังกฤษและไทย (`Sources/Cortexy/Welcome.swift`) ลบทิ้งได้
- ข้อมูลอยู่ที่ `~/Library/Application Support/Cortexy` (เปลี่ยนเป็นโฟลเดอร์ iCloud ได้ใน Settings → Data)

**ลองเองแบบคนใช้ครั้งแรก โดยไม่ทับ Cortexy ที่ใช้อยู่**
- เหมือนเครื่องใหม่ที่สุด: System Settings → Users & Groups → Add User แล้ว log in เข้า user นั้นไปลอง
  (วาง zip ไว้ที่ `/Users/Shared`) — โน้ต, settings, hotkey, รหัสล็อก แยกจากของคุณทั้งหมด
- เร็วกว่า: Quit Cortexy ตัวที่ใช้อยู่ก่อน (สองตัวพร้อมกันจะแย่ง hotkey) แล้วรันจาก Terminal
  `CORTEXY_DATA_DIR=~/Desktop/cortexy-demo ~/Downloads/Cortexy.app/Contents/MacOS/Cortexy`
  — โน้ตอยู่ในโฟลเดอร์ใหม่ (ได้คู่มือครบ) แต่ **settings ใช้ร่วมกับตัวจริง** อย่าแก้ theme/shortcut/Data ระหว่างลอง;
  เลิกลองด้วย Quit แล้วเปิด `/Applications/Cortexy.app` ตามเดิม ลบ `~/Desktop/cortexy-demo` ทิ้งได้

ถ้าจะแจกให้คนทั่วไปแบบไม่มีขั้นตอน Open Anyway ต้องสมัคร Apple Developer Program (ปีละ $99),
เซ็นด้วยใบรับรอง Developer ID แล้ว notarize (`xcrun notarytool` มีใน Command Line Tools อยู่แล้ว ไม่ต้องใช้ Xcode)

## ฟีเจอร์

**เปิด panel**: ดันเมาส์ชนขอบจอ (เว้นมุมจอให้ hot corner) · hotkey (ตั้งเองได้) · Open Bar แถบบางๆ ที่ขอบจอ ·
ไอคอน menu bar · เปิดแอปซ้ำจาก Finder/Spotlight — ใช้ได้กับแอปเต็มจอ, Stage Manager, หลายจอ ·
**⇧⌘P ปักหมุด panel** ให้ค้างไว้ตอนคลิกแอปอื่น · ปรับ**ความโปร่งใส** · **ซ่อนจากการแชร์จอ/อัดจอ** (Settings → General)

**จัดระเบียบ**: โฟลเดอร์ซ้อนกันได้ไม่จำกัดชั้น · สร้างโน้ตที่หน้าแรกได้เลย ไม่ต้องอยู่ในโฟลเดอร์ ·
เรียงโน้ตตามวันแก้ / วันสร้าง / ชื่อ / ลากเอง (ตั้งแยกแต่ละโฟลเดอร์ที่เมนู ⋯) ·
**Recently Deleted**: ลบแล้วกด Undo ได้ (หรือ ⌘Z), กู้คืนได้ภายใน 30 วัน · **Archive** เก็บโน้ตออกจากโฟลเดอร์และผลค้นหา ·
พับ/กางโฟลเดอร์ย่อยในหน้าเดิม (ลูกศรหน้าโฟลเดอร์) · กดชื่อหัวข้อเพื่อกระโดดไปโฟลเดอร์ชั้นบน ·
ลากโน้ต/โฟลเดอร์ไปวางบนโฟลเดอร์เพื่อย้าย (โฟลเดอร์: วางกลางแถว) หรือบน Recently Deleted เพื่อลบ ·
เลือกหลายอัน (⌘-click, ⇧-click, ⌘A) แล้วย้าย/ติดสี/ปักหมุด/archive/ลบทีเดียว · ไอคอนโฟลเดอร์ (เลือกจากตาราง SF Symbol/emoji) ·
หน้าแรกแยกหมวด Folders / Smart Folders / Library (Archive, Recently Deleted) / Tags / Notes ·
Duplicate โน้ต · Outline กระโดดไปหัวข้อในโน้ต · ติดสี (พื้นหลัง/แถบข้าง) · ปักหมุด · ลากเรียงลำดับโน้ตและโฟลเดอร์ (ลากเข้า/ออกกลุ่มปักหมุด = ปักหมุด/เลิกปักหมุด) ·
พับโน้ตยาว · ย้ายโฟลเดอร์ · ค้นหาทุกโฟลเดอร์ · จำหน้าที่เปิดล่าสุด

**ค้นหา & ลิงก์**: **⌘O** quick open (โน้ต/โฟลเดอร์/#tag แบบ fuzzy) · **⌘P** command palette (หรือพิมพ์ `>` ใน ⌘O) ·
`#tag` (คลิกเพื่อดูโน้ตที่มี tag นั้น, รายการ tag ที่หน้าแรก, พิมพ์ `#` แล้วมีตัวเลือกให้) ·
`[[ชื่อโน้ต]]` / `[[ชื่อโน้ต|ข้อความ]]` ลิงก์ไปโน้ตอื่น (ไม่มีโน้ตนั้นจะสร้างให้, พิมพ์ `[[` แล้วมีตัวเลือก,
แก้ชื่อโน้ตแล้วลิงก์ที่ชี้มาจะเปลี่ยนตาม) · `[[ชื่อโน้ต#หัวข้อ]]` ไปที่หัวข้อ (พิมพ์ `#` แล้วมีรายการหัวข้อ), `[[#หัวข้อ]]` ในโน้ตเดียวกัน,
`[[ชื่อโน้ต#^id]]` ไปบรรทัดที่ลงท้ายด้วย `^id` · **frontmatter** (`---` properties แบบ Obsidian) แสดงจางๆ ไม่ถูกใช้เป็นชื่อโน้ต,
`tags:` นับเป็น tag, `aliases:` เป็นชื่ออื่นของโน้ตสำหรับลิงก์ · "N linked here" ใต้โน้ต = backlinks ·
**⌘G Graph** หน้าต่างกราฟ: จุด = โน้ต, เส้น = `[[ลิงก์]]` (เลือกแสดง #tag เป็นจุดสีเขียวน้ำทะเล / ซ่อนโน้ตที่ไม่มีลิงก์ได้) —
ลากจุดเพื่อจัด, ลากพื้นหลังเพื่อเลื่อน, scroll/pinch เพื่อซูม, ชี้ที่จุดเพื่อไฮไลต์โน้ตที่ลิงก์กัน, คลิกเพื่อเปิดโน้ตใน panel;
"Around this note" = แสดงเฉพาะโน้ตที่ห่างไม่เกิน 2 ลิงก์ (คลิกขวาโน้ต → Show in Graph) ·
คลิกช่อง Search จะมีตัวช่วย: `#` แสดงแท็กทั้งหมด · `is:` ตัวกรอง (todo, done, pinned…) · `path:` โฟลเดอร์ · `"วลี"` · `-คำ` · `>` คำสั่ง — Tab เลือกอันแรก ·
**ล็อกโฟลเดอร์** (คลิกขวาโฟลเดอร์ → Lock Folder…): ทุกโน้ตในโฟลเดอร์ (และโฟลเดอร์ย่อย) ถูกเข้ารหัสด้วยรหัสเดียวกับโน้ตที่ล็อก, ไม่โผล่ในค้นหา/แท็ก/⌘O/graph/preview จนกว่าจะปลดล็อก, โน้ตที่เขียนเพิ่มตอนเปิดอยู่จะถูกเข้ารหัสเมื่อล็อกอีกครั้ง ·
ค้นหาขั้นสูง: `"วลี"` `-ไม่เอา` `#tag` `tag:x` `path:Work` `is:todo` `is:done` `is:task` `is:pinned` `is:archived` ·
ค้นเฉพาะโฟลเดอร์ที่เปิดอยู่ · ไฮไลต์คำที่เจอ · **Save as Smart Folder** เก็บการค้นหาเป็นโฟลเดอร์

**เขียน**: **ตาราง Markdown** (ปุ่ม ⊞ ในแถบล่าง, คอลัมน์เรียงตรงกันเอง, `:-:` จัดกลาง/`--:` ชิดขวา,
คลิกในตาราง = แก้ข้อความดิบ, Tab/⇧Tab ไปช่องถัดไป/ก่อนหน้า, Tab ช่องสุดท้ายหรือ ↩ ท้ายแถว = เพิ่มแถว) ·
**สีโค้ด** ตามภาษาหลัง ``` (swift, js/ts, python, go, rust, java/kotlin, c/c++, ruby, shell, sql, json/yaml) ·
`==ไฮไลต์==` · เชิงอรรถ `[^1]` (คลิกเพื่อไปที่ `[^1]: ข้อความ`) ·
**Templates**: โน้ตในโฟลเดอร์ "Templates" → ⋯ → New from Template (ตัวแปร `{{date}}` `{{time}}` `{{weekday}}`
`{{folder}}` `{{date:MMMM yyyy}}`, `{{cursor}}` = ตำแหน่งเริ่มพิมพ์) · **⌘D โน้ตประจำวัน** ในโฟลเดอร์ "Daily"
(ตั้งชื่อโฟลเดอร์, template, รูปแบบวันที่ และ hotkey ได้ใน Settings)

**Power**: **Version history** (คลิกขวา → Version History, พักเมาส์ดูเวอร์ชัน, Restore + Undo; เก็บใน `History/`) ·
**หน้าต่างลอย** (คลิกขวา → Open in Window: อยู่บนสุดเสมอ, จำตำแหน่ง, เปิดค้างไว้ข้ามการเปิดแอปใหม่) ·
**รูปจากเว็บ** `![](https://…)` (โหลดเบื้องหลัง เก็บ cache; ปิดได้) · **Due date** `- [ ] งาน 📅 2026-10-05 14:30`
(หรือ `@2026-10-05`, ปุ่มปฏิทินใต้ editor) แดง = เลยกำหนด, ส้ม = วันนี้, สีธีม = วันถัดไป · หน้า **Upcoming** + **แจ้งเตือน** ของ macOS
(คลิกแจ้งเตือน = เปิดโน้ต) · **Lock โน้ต** (คลิกขวา → Lock Note: รหัสเดียวทุกโน้ต, AES-GCM, ไฟล์/backup/history/export
ไม่มีข้อความจริง, ล็อกเองเมื่อปิด panel หรือจอ sleep, Touch ID ได้; **ลืมรหัส = เปิดไม่ได้อีก**)

**การ์ดโน้ต**: โชว์แค่ชื่อโน้ต (ผลค้นหาโชว์บรรทัดที่เจอด้วย; ปิดได้ใน Settings → Appearance เพื่อโชว์หลายบรรทัด
หน้าตาเหมือนตอนเปิดโน้ต) · **พักเมาส์บนการ์ด** = การ์ด preview ขนาดคงที่ข้าง panel
ระดับเดียวกับแถวที่ชี้ แสดงโน้ตเต็ม เลื่อนอ่านได้ เมาส์ออกแล้วหายเอง คลิกเพื่อแก้
· พักเมาส์บน**โฟลเดอร์** (หรือ Smart Folder, Archive, Upcoming, Recently Deleted) = preview รายการข้างใน, คลิกโฟลเดอร์ย่อย
เพื่อเข้าไปในการ์ดเดิม (แถบ path ด้านบนกดย้อนได้), พักบนโน้ตในรายการ = การ์ดอ่านโน้ตขนาดเท่ากันข้างๆ,
คลิกโน้ตหรือ ↗ = เปิดใน panel (Settings → General: เปิด/ปิด, เวลาก่อนแสดง, เวลาก่อนหาย, ความกว้าง)
· **รูปจากเว็บ** ในโน้ตรอกด Load ทีละโน้ต (การโหลดบอกเว็บต้นทางว่าคุณเปิดโน้ต) หรือเปิดให้โหลดทุกโน้ตใน Settings

**ปรับได้ใน Settings**: General — ขอบจอ, เวลาเปิด/ปิด panel ตอนเมาส์ชนขอบ/ออก, ความกว้าง, preview, Tags ที่หน้าแรก,
เวลาที่กด Undo ได้, Tab ใน code mode · Appearance — ธีมสี, ฟอนต์ (บอกชัดว่าฟอนต์ไหนไม่มีไทย/อังกฤษ), ขนาด, ระยะบรรทัด/ย่อหน้า, ขนาดหัวข้อ, ย่อหน้า list,
ฟอนต์โค้ด, ความหนาแน่น, ความโค้ง, จำนวนบรรทัดบนการ์ด, Light/Dark · Shortcuts — คีย์ลัด global และคีย์ลัดที่ตั้งเอง
(โน้ตใหม่จาก template ลงโฟลเดอร์ที่เลือก หรือเปิดโน้ต; ใช้ใน Cortexy หรือจากทุกแอป) · Data — โฟลเดอร์เก็บข้อมูล, เปลี่ยนรหัสโน้ตล็อก,
เก็บ Recently Deleted กี่วัน, เก็บ backup กี่ชุด

**เนื้อหา**: Markdown แบบซ่อนเครื่องหมาย (`# หัวข้อ`, `**หนา**`, `*เอียง*`, `~~ขีดฆ่า~~`, `` `code` ``, code block, quote,
`[ลิงก์](url)`) · checklist คลิกติ๊กได้ทั้งใน editor และบนการ์ด · Return ต่อลิสต์ให้, Tab/⇧Tab ย่อหน้า ·
รูปภาพ (วาง/ลาก/เลือกไฟล์/**ถ่าย screenshot**) · ไฟล์และโฟลเดอร์แนบ (ดับเบิลคลิกเปิด) · `#ff8800` แสดงเป็นสี ·
**⌥⌘↑/↓ ย้ายบรรทัด** · **⌘-click** คัดลอก code block/หัวข้อ/รายการ/quote (⌥⌘-click = คัดลอกลิงก์) · ปุ่ม ⧉ คัดลอกที่มุม code block ·
ดับเบิลคลิกไฟล์แนบ = **Quick Look** · **Snippet** (คลิกการ์ด = คัดลอก) · **Code mode** ต่อโน้ต · ลากข้อความ/ไฟล์/รูป/ลิงก์จากแอปอื่นมาวางเป็นโน้ตใหม่
(ลากไปชนขอบจอ panel จะเปิดรอรับ) · ปุ่ม hover บนการ์ด: คัดลอก / พับ

**ลื่น**: พิมพ์ในโน้ตยาวๆ ได้ไม่หน่วง (restyle เฉพาะย่อหน้าที่แก้) · บันทึกเบื้องหลัง · รูปถอดรหัสเท่าขนาดที่แสดง
(รูปกล้อง 12MP ไม่กินแรมเป็นสิบ MB) และโหลดเบื้องหลังบนการ์ด · animation จังหวะเดียวทั้งแอป ปิดหมดเมื่อเปิด Reduce Motion

**หน้าตา**: Liquid Glass · 42 ธีมสี + สร้าง/แก้ธีมเอง (สี panel, การ์ด, accent) ·
**ตัวอักษรเลือกแยกจากธีม**: ฟอนต์ไหนก็ได้ในเครื่อง (หรือใช้ฟอนต์ที่ธีมแนะนำ), ขนาด, ระยะบรรทัด/ย่อหน้า, ขนาดหัวข้อ, ฟอนต์โค้ด ·
**Layout**: ความหนาแน่น, ความโค้งมุม, จำนวนบรรทัดบนการ์ด, ซ่อนแถบจัดรูปแบบ/วันที่ · บังคับ Light/Dark/ตามระบบ · Reduce Motion · VoiceOver labels

**ข้อมูล**: บันทึกอัตโนมัติ · backup รายวันเก็บ 14 วัน · ไฟล์เสียจะถูกเก็บแยกไว้ ไม่ถูกเขียนทับ ·
เลือกโฟลเดอร์เก็บข้อมูลเองได้ → วางใน **iCloud Drive / OneDrive / Dropbox เพื่อ sync หลายเครื่อง**
(ถ้าแก้พร้อมกัน อีกฝั่งจะถูกเก็บเป็นไฟล์ conflict) · export ทุกโน้ตเป็นไฟล์ `.md` · export/copy โน้ตเป็นรูป ·
ไม่มี analytics / telemetry

## คีย์ลัด

| | |
|---|---|
| เปิด/ปิด panel | ⌃⌥N (เปลี่ยนได้ใน Settings → Shortcuts) · Esc / ⌘W ปิด |
| โน้ตใหม่ / โฟลเดอร์ใหม่ | ⌘N / ⇧⌘N — สร้างในโฟลเดอร์ที่เปิดอยู่ (ตั้ง hotkey "New note" แบบ global ได้) |
| โน้ตประจำวัน | ⌘D (ตั้ง hotkey "Today's note" แบบ global ได้) |
| ค้นหา / ย้อนกลับ | ⌘F (ในโน้ต = หาในโน้ตนี้, ⌘G ถัดไป · ⇧⌘F = ค้นทุกโน้ต) / ⌘[ หรือ ← (กลับไปหน้าที่มา รวมผลค้นหา) |
| Quick open / command palette | ⌘O / ⌘P |
| Graph ของลิงก์ | ⌘G |
| เลือก / เปิด / พับ / ลบ | ↑ ↓ / ↩ หรือ → / Space / ⌘⌫ |
| ย้ายโน้ตไปโฟลเดอร์อื่น | ⇧⌘M |
| เลือกหลายอัน | ⌘-click · ⇧-click · ⌘A · Esc ยกเลิก · ⌘⌫ ลบที่เลือก |
| จัดรูปแบบ | ⌘B · ⌘I · ⌘E code · ⌘K ลิงก์ · ⌘L checklist · ⇧⌘X ขีดฆ่า · ⇧⌘8 bullet · ⇧⌘7 ลิสต์ตัวเลข · ⇧⌘9 quote · ⇧⌘H ไฮไลต์ · ⇥ ย่อหน้า (ปุ่ม Aa ใน format bar มี code block / เส้นคั่นด้วย) |
| Settings | ⌘, |

คีย์ลัดใช้ได้แม้แป้นพิมพ์เป็นภาษาไทยอยู่

## ใช้กับแอปอื่น (Raycast, Alfred, Shortcuts, PopClip)

**URL scheme**

```bash
open "cortexy://new?text=Buy%20milk&folder=Home"
```

`cortexy://show` · `hide` · `toggle` · `new?text=…&folder=…` · `search?q=…` · `open?title=…` · `tag/ชื่อtag`

**AppleScript** (ใน Shortcuts ใช้ action "Run AppleScript")

```applescript
tell application "Cortexy" to add note "Buy milk" in folder "Home"
tell application "Cortexy" to search notes "milk"
tell application "Cortexy" to toggle panel
```

**Services**: เลือกข้อความในแอปไหนก็ได้ → คลิกขวา → Services → **New Cortexy Note**
(ตั้งคีย์ลัดได้ที่ System Settings → Keyboard → Keyboard Shortcuts → Services)

## ข้อมูลอยู่ที่ไหน

ค่าเริ่มต้น `~/Library/Application Support/Cortexy/` — `cortexy.json` (โน้ตทั้งหมด), `attachments/` (รูป),
`Backups/` — เปลี่ยนได้ที่ Settings → Data

## ข้อจำกัดเมื่อไม่มี Xcode / Apple Developer account

- **Shortcuts actions แบบ native** (App Intents) ต้องใช้ Xcode build → ใช้ AppleScript/URL scheme ผ่าน Shortcuts แทน
- **Share extension, widget** ต้องใช้ Xcode → ใช้ Services menu แทน
- **iCloud sync แบบ CloudKit** ต้องมี Developer Team → ใช้โฟลเดอร์ใน iCloud Drive แทน

## โครงสร้างโค้ด

| ไฟล์ | หน้าที่ |
|---|---|
| `CortexyApp.swift` | entry point, menu bar, URL scheme, Services |
| `Panel.swift` | panel ข้างจอ, hot edge, hotkey (Carbon), Open Bar, คีย์ลัด |
| `Nav.swift` | สถานะการนำทาง + action ร่วม (สร้าง/ลบ/ลากวาง/screenshot/export) |
| `Views.swift` | root, header, editor screen, toolbar, เมนู |
| `Lists.swift` | รายการโฟลเดอร์/โน้ต, การ์ด, drag & drop |
| `Preview.swift` | หน้าต่าง preview ตอนพักเมาส์บนการ์ด |
| `NoteWindow.swift` | โน้ตในหน้าต่างลอยของตัวเอง |
| `Reminders.swift` | แจ้งเตือนงานที่มี due date |
| `Lock.swift` | เข้ารหัสโน้ตที่ล็อก, Keychain, Touch ID |
| `Editor.swift` | NSTextView แสดง Markdown สด, checkbox, รูป/ไฟล์แนบ |
| `Markdown.swift` | logic Markdown ระดับบรรทัด (มีเทสต์) |
| `Store.swift` | โมเดล, บันทึก, backup, sync, ไฟล์แนบ, export (มีเทสต์) |
| `Theme.swift` | ธีม 42 แบบ + ธีมที่สร้างเอง |
| `Settings.swift` | หน้าต่าง Settings, ตัวอัด hotkey, ย้ายโฟลเดอร์ข้อมูล |
| `Scripting.swift` + `Resources/Cortexy.sdef` | AppleScript, Services |
| `Snapshot.swift` | debug เท่านั้น: ไล่ทุกหน้าจอเพื่อถ่าย screenshot เทสต์ |
| `tools/make-icon.swift` | สร้างไอคอนแอปจาก `Resources/AppIcon-art.png` → `Resources/AppIcon.icns` |
