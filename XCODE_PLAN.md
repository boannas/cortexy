# แผนย้ายมาใช้ Xcode

ตอนนี้ Cortexy build ด้วย Command Line Tools อย่างเดียว (`swift build` + `build.sh`) และเซ็นแบบ ad-hoc
บางอย่างทำแบบนี้ไม่ได้ ไฟล์นี้วางลำดับการย้าย และบอกว่าแต่ละขั้นได้อะไร ต้องจ่ายเท่าไหร่ ใช้เวลาประมาณเท่าไหร่

หน่วยเวลาใช้แบบเดียวกับแผนก่อนๆ คือวันทำงานของ dev: **S** ไม่เกิน 1 วัน · **M** 2–4 วัน · **L** 5 วันขึ้นไป

---

## สิ่งที่ปลดล็อก

| ต้องมี | ได้อะไร |
|---|---|
| **Xcode (ฟรี)** + Apple ID แบบ Personal Team | App Intents (Shortcuts, Siri, Spotlight actions), widget, Control Center controls, share extension — ใช้บนเครื่องตัวเองได้ |
| **Apple Developer Program ($99/ปี)** | Developer ID + notarize (คนอื่นเปิดได้โดยไม่ต้อง Open Anyway), Touch ID ผูก keychain จริง, CloudKit, แอป iPhone บนเครื่องจริงนานกว่า 7 วัน, TestFlight / App Store |

ข้อดีที่ได้ตั้งแต่ลง Xcode:
- เซ็นด้วย Personal Team แทน ad-hoc: สิทธิ์ต่างๆ (การแจ้งเตือน, Screen Recording, keychain) ไม่ต้องถามใหม่ทุกครั้งที่ build
- ใช้ Instruments วัดความลื่นได้ละเอียดกว่าเครื่องมือวัดใน scratchpad

---

## ลำดับ

### ขั้น 0: เตรียมโค้ด (ทำได้เลย ยังไม่ต้องมี Xcode) — M

1. **แยก package เป็น 2 target**
   - `CortexyCore` (library): `Store`, `Markdown`, `Calc`, `Clipboard`, `Library` (mirror/import), `Lock`, โมเดล
   - `Cortexy` (แอป): panel, SwiftUI views, editor
   - เทสต์ของ logic ย้ายไป test target ของ `CortexyCore` (ยังรันด้วย `swift test` ได้)
2. **ทำให้ Core ไม่แตะ AppKit/UI:**
   - ตัวอย่างที่ต้องย้ายออก: `Styler` regex ที่ `MD.plainInline` ใช้ และ `NSColor` ใน `Callouts`
   - ย้าย regex ที่ใช้ร่วมไปไว้ใน Core
3. **เหตุผล:** extension ทุกตัว (widget, share, App Intents) และแอป iPhone ในอนาคตต้องใช้ Store และ parser ชุดเดียวกัน

ตรวจ: `./build.sh test` ผ่านเหมือนเดิม แอปทำงานเหมือนเดิม

### ขั้น 1: โปรเจกต์ Xcode — S

1. **สร้าง `Cortexy.xcodeproj`** มี target แอปที่ใช้ local package `CortexyCore`
   - แนะนำเขียนเป็น `project.yml` ด้วย XcodeGen (ไฟล์เดียว อ่าน diff ได้ สร้าง .xcodeproj ใหม่ได้เสมอ)
   - หรือสร้างใน Xcode ครั้งเดียวแล้ว commit ไฟล์ .xcodeproj ก็ได้
2. **`build.sh` ใช้ `xcodebuild`** แต่คำสั่งเดิมยังเหมือนเดิม (`./build.sh`, `install`, `test`, `dist`)
3. **เซ็นด้วย Personal Team:** bundle ID เดิม `com.cortexy.app` และโฟลเดอร์ข้อมูลเดิม
4. **Touch ID:** ผูก keychain ใหม่ ผู้ใช้ต้องเปิด Touch ID อีกครั้งหนึ่งรอบ

ตรวจ: เปิดแอปแล้วโน้ตเดิมครบ · ไล่ TESTING.md ส่วนที่ใช้สิทธิ์ (แจ้งเตือน, screenshot, Touch ID)

### ขั้น 2: App Intents (Shortcuts, Siri, Spotlight) — M

รันในตัวแอปเอง ไม่ต้องมี extension จึงใช้ Store ได้เต็มที่

- **Intent:**
  - New Note (ข้อความ, โฟลเดอร์)
  - Append to Note (Inbox / วันนี้ / โน้ตที่เลือก)
  - Open Note
  - Open Today's Note
  - Search Notes (คืนรายการโน้ต)
  - Show/Hide Panel
  - Open Capture Box
- **`NoteEntity` + `EntityQuery`:** เลือกโน้ตจากชื่อใน Shortcuts ได้ (ไม่รวมโน้ตที่ล็อก)
- **ได้ฟรีจาก intent ชุดนี้:** Spotlight actions และ Siri ของ macOS 27 (สั่งสร้าง/ต่อท้ายโน้ตด้วยเสียง)
- **ไม่ทิ้งของเดิม:** URL scheme และ AppleScript ยังอยู่

ตรวจ: สร้าง Shortcut ทุก intent · ถาม Siri · หา action ใน Spotlight

### ขั้น 3: Widget และ Control Center — M–L

- **ต้องมี App Group** (`group.com.cortexy.app`): widget รันใน process แยกที่เป็น sandbox อ่านโฟลเดอร์ข้อมูลตรงๆ ไม่ได้
  - แอปเขียน snapshot เล็กๆ ลง group container: งานวันนี้, โน้ตที่ปักหมุด, โน้ตที่ผูกกับ widget
  - ⚠️ ต้องลองก่อนว่า App Group บน macOS ใช้กับ Personal Team ได้ (ถ้าไม่ได้ ขั้นนี้ต้องรอ Developer Program)
- **Widget:**
  - งานวันนี้ / Upcoming: ติ๊กงานได้ผ่าน App Intent
  - โน้ตที่ปักหมุด
  - โน้ตที่เลือก
- **Control Center / menu bar controls:** New Note, Capture Box, Show Panel
- **ความปลอดภัย:** snapshot ต้องไม่มีโน้ตที่ล็อก (กติกาเดียวกับ Spotlight/MCP)

ตรวจ: เพิ่ม widget บน desktop · ติ๊กงานจาก widget แล้วโน้ตเปลี่ยน · ปุ่มใน Control Center

### ขั้น 4: Share extension — S–M

- "Add to Cortexy" ใน share sheet ของทุกแอป (Safari, Finder, Photos): ข้อความ, ลิงก์ + ชื่อหน้า, รูป, ไฟล์
- ส่งเข้าแอปผ่าน URL scheme (`cortexy://new`/`append`) หรือคิวใน App Group ถ้าแอปปิดอยู่
- ทดแทน bookmarklet ได้ แต่ bookmarklet ยังเก็บไว้

### ขั้น 5: ต้องจ่าย Developer Program — แยกตัดสินใจทีละข้อ

| งาน | ขนาด | หมายเหตุ |
|---|---|---|
| Developer ID + notarize ใน `./build.sh dist` | S | ส่ง zip ให้คนอื่นแล้วเปิดได้เลย (`xcrun notarytool`) |
| Touch ID ผูก keychain แบบ biometry ACL | S | ปิดช่องที่ QA รอบแรกข้ามไป |
| อัปเดตอัตโนมัติ (Sparkle หรือเช็ค GitHub Releases) | M | Sparkle เป็น dependency ภายนอก, เช็ค release เองเขียนน้อยกว่า |
| CloudKit sync แทน iCloud Drive | L | sync ทีละโน้ต ไม่มีไฟล์ conflict แต่ต้องเขียน sync ใหม่ทั้งชุด และต้องคิดเรื่องโน้ตที่ล็อก (ciphertext เท่านั้นขึ้น cloud) |
| แอป iPhone/iPad | L+ | ใช้ `CortexyCore` ร่วม แต่ editor ต้องเขียนใหม่ (UITextView), sync ต้องเป็น CloudKit หรือ iCloud Drive + file coordination |

---

## ลำดับที่แนะนำ

1. **ขั้น 0** ทำได้ทันที ไม่ต้องรออะไร และทำให้ทุกขั้นที่เหลือง่ายขึ้น
2. **ลง Xcode** แล้วทำ **ขั้น 1 → 2**: ได้ Shortcuts, Siri และ Spotlight actions โดยไม่ต้องจ่าย
3. ลอง App Group กับ Personal Team ก่อนเริ่ม **ขั้น 3** (ถ้าไม่ได้ ข้ามไปทำขั้น 4 ก่อน)
4. **Developer Program:** สมัครเมื่อจะส่งให้คนอื่นใช้จริง หรือเมื่อจะทำแอป iPhone

## สิ่งที่ต้องระวังตลอดทาง

- **โฟลเดอร์ข้อมูลและ bundle ID ต้องเหมือนเดิม:** ไม่อย่างนั้นแอปจะมองไม่เห็นโน้ตเดิม
- **กติกาโน้ตที่ล็อก:** ทุกช่องทางใหม่ (widget snapshot, intent, share) ต้องไม่อ่านหรือเขียนโน้ตที่ล็อก เหมือน Spotlight/MCP/mirror
- **ทุกขั้นต้องผ่าน `./build.sh test`** และเพิ่มหัวข้อใน TESTING.md
- **ห้ามมี sandbox ในแอปหลัก:** ถ้าเผลอเปิด entitlement App Sandbox ให้แอปหลัก จะอ่านโฟลเดอร์ข้อมูลที่ผู้ใช้เลือกเองไม่ได้ (sandbox ใช้เฉพาะ extension)
