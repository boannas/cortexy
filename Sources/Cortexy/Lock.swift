import AppKit
import CommonCrypto
import CryptoKit
import LocalAuthentication
import Security

/// Locked notes. The text is sealed with AES-GCM under a key made from the password (PBKDF2-SHA256, its own
/// salt per note), so only ciphertext is ever written: notes file, history, exports, backups. One password
/// opens all locked notes, and there is no way back without it.
enum NoteLock {
    static let rounds: UInt32 = 200_000

    static func key(_ password: String, salt: Data) -> SymmetricKey {
        var out = [UInt8](repeating: 0, count: 32)
        let length = password.utf8.count
        salt.withUnsafeBytes { s in
            _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, length, s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &out, out.count)
        }
        return SymmetricKey(data: out)
    }

    static func newSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    /// "v1:<salt>:<sealed box>", both base64.
    static func seal(_ text: String, key: SymmetricKey, salt: Data) -> String? {
        guard let box = try? AES.GCM.seal(Data(text.utf8), using: key).combined else { return nil }
        return "v1:" + salt.base64EncodedString() + ":" + box.base64EncodedString()
    }

    static func salt(_ box: String) -> Data? {
        let p = box.split(separator: ":")
        return p.count == 3 && p[0] == "v1" ? Data(base64Encoded: String(p[1])) : nil
    }

    /// The text, or nil for a wrong password (the box won't authenticate).
    static func open(_ box: String, key: SymmetricKey) -> String? {
        let p = box.split(separator: ":")
        guard p.count == 3, let data = Data(base64Encoded: String(p[2])), let sealed = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(sealed, using: key) else { return nil }
        return String(decoding: plain, as: UTF8.self)
    }
}

extension NoteLock {
    /// The `attachments/…` files a note's text points at.
    static func attachments(_ text: String) -> [String] {
        let ns = text as NSString
        return attachmentRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }
    private static let attachmentRegex = try! NSRegularExpression(pattern: #"\(attachments/([^)\s]+)\)"#)

    /// Seals a locked note's attachments next to where they were (`x.png` → `x.png.locked`). While the note is
    /// unlocked the plain copy waits in a temporary folder, gone when it locks again.
    // ponytail: an attachment shared by a locked and an unlocked note (Duplicate) gets sealed too; copy on duplicate if that bites.
    static func seal(attachmentsOf text: String, in dir: URL, key: SymmetricKey) {
        let fm = FileManager.default
        try? fm.createDirectory(at: Store.unlockedAttachments, withIntermediateDirectories: true)
        for name in attachments(text) {
            let plain = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: plain), let box = try? AES.GCM.seal(data, using: key).combined,
                  (try? box.write(to: dir.appendingPathComponent(name + ".locked"), options: .atomic)) != nil else { continue }
            try? fm.removeItem(at: Store.unlockedAttachments.appendingPathComponent(name))
            try? fm.moveItem(at: plain, to: Store.unlockedAttachments.appendingPathComponent(name))
        }
    }

    /// Opens a locked note's sealed attachments: into the temporary folder, or back in place (`toDir`, removing the lock).
    static func open(attachmentsOf text: String, in dir: URL, key: SymmetricKey, toDir: URL = Store.unlockedAttachments) {
        let fm = FileManager.default
        try? fm.createDirectory(at: toDir, withIntermediateDirectories: true)
        for name in attachments(text) {
            let sealed = dir.appendingPathComponent(name + ".locked")
            guard let data = try? Data(contentsOf: sealed), let box = try? AES.GCM.SealedBox(combined: data),
                  let plain = try? AES.GCM.open(box, using: key), (try? plain.write(to: toDir.appendingPathComponent(name), options: .atomic)) != nil else { continue }
            if toDir != Store.unlockedAttachments { try? fm.removeItem(at: sealed) }
        }
    }
}

/// The password in the login keychain, for Touch ID (Settings → Data).
enum Keychain {
    private static let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: "com.cortexy.app.locked-notes",
                                                 kSecAttrAccount: "password"]

    static func save(_ password: String) {
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData] = Data(password.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

    static func load() -> String? {
        var q = query
        q[kSecReturnData] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete() { SecItemDelete(query as CFDictionary) }
}

extension Nav {
    /// Set only by tests: what the password prompt "returns" (nil = Cancel), instead of showing it.
    nonisolated(unsafe) static var passwordAnswer: String??

    // MARK: Locked notes

    var anyLocked: Bool { store.folders.contains { $0.notes.contains { $0.lock != nil } } }

    /// Locks a note with the password (chosen now if no note is locked yet). It stays open until it locks again.
    func lockNote(_ fid: UUID, _ nid: UUID) {
        guard let n = store.note(fid, nid), n.lock == nil else { return }
        withPassword(creating: !anyLocked) { [self] password in
            guard let password, let current = store.note(fid, nid) else { return }
            let salt = NoteLock.newSalt(), key = NoteLock.key(password, salt: salt)
            guard let box = NoteLock.seal(current.text, key: key, salt: salt) else { return }
            unlocked[nid] = current.text
            keys[nid] = key
            salts[nid] = salt
            NoteLock.seal(attachmentsOf: current.text, in: store.attachmentsDirectory, key: key)
            store.updateNote(fid, nid) { $0.lock = box; $0.lockedTitle = current.title; $0.text = "" }
            store.removeHistory(nid)
            if let locked = store.note(fid, nid) { store.scrubCopies(of: locked) }
            flash("Locked")
        }
    }

    // MARK: Locked folders

    /// Locks a folder: every note in it (and in its folders) is sealed, and it shows nothing until unlocked.
    func lockFolder(_ fid: UUID) {
        withPassword(creating: !anyLocked) { [self] password in
            guard let password else { return }
            if route != .folder(fid), store.chain(currentFolder).contains(where: { $0.id == fid }) { route = .folder(fid) } // out of its notes
            store.updateFolder(fid) { $0.locked = true }
            seal(folder: fid, password)
            store.openFolders.remove(fid)
            flash("Folder locked")
        }
    }

    func unlockFolder(_ fid: UUID, then done: @escaping () -> Void = {}) {
        guard store.lockedAway(fid) else { return done() }
        let sample = store.subtree(fid).lazy.flatMap(\.notes).first { $0.lock != nil }?.lock
        withPassword(creating: false, checking: sample) { [self] password in
            guard let password else { return }
            if let sample, let salt = NoteLock.salt(sample), NoteLock.open(sample, key: NoteLock.key(password, salt: salt)) == nil {
                self.password = nil
                return wrongPassword()
            }
            seal(folder: fid, password) // anything that got in unsealed (moved in while locked)
            store.openFolders.insert(fid)
            done()
        }
    }

    /// Takes the lock off a folder and off the notes in it.
    func removeFolderLock(_ fid: UUID) {
        unlockFolder(fid) { [self] in
            for f in store.subtree(fid) { for n in f.notes where n.lock != nil { removeLock(f.id, n.id) } }
            store.updateFolder(fid) { $0.locked = false }
            store.openFolders.remove(fid)
            flash("Folder lock removed")
        }
    }

    /// Seals the notes in a locked folder that aren't yet (written while it was unlocked, moved in).
    // ponytail: one PBKDF2 key per note (~0.1 s each); fine for the few written per session, slow for locking hundreds at once.
    func seal(folder fid: UUID, _ password: String) {
        for f in store.subtree(fid) { for n in f.notes where n.lock == nil && !n.isBlank { seal(f.id, n.id, password) } }
    }

    private func seal(_ fid: UUID, _ nid: UUID, _ password: String) {
        guard let current = store.note(fid, nid), current.lock == nil else { return }
        let salt = NoteLock.newSalt(), key = NoteLock.key(password, salt: salt)
        guard let box = NoteLock.seal(current.text, key: key, salt: salt) else { return }
        NoteLock.seal(attachmentsOf: current.text, in: store.attachmentsDirectory, key: key)
        store.updateNote(fid, nid) { $0.lock = box; $0.lockedTitle = current.title; $0.text = "" }
        store.removeHistory(nid)
        if let locked = store.note(fid, nid) { store.scrubCopies(of: locked) }
    }

    /// In a locked folder (unlocked or not).
    func inLockedFolder(_ fid: UUID) -> Bool { store.chain(fid).contains(where: \.locked) }

    /// Opens a locked note's text for this session: Touch ID or the password.
    func unlock(_ nid: UUID, then done: @escaping () -> Void = {}) {
        guard unlocked[nid] == nil else { return done() }
        guard let f = store.folderOf(nid), let box = store.note(f.id, nid)?.lock, let salt = NoteLock.salt(box) else { return }
        withPassword(creating: false, checking: box) { [self] password in
            guard let password else { return }
            let key = NoteLock.key(password, salt: salt)
            // Wrong for this note (a stale Touch ID one, another Mac's): forget it, so the next try asks again.
            guard let text = NoteLock.open(box, key: key) else { self.password = nil; return wrongPassword() }
            NoteLock.open(attachmentsOf: text, in: store.attachmentsDirectory, key: key)
            unlocked[nid] = text
            keys[nid] = key
            salts[nid] = salt
            done()
        }
    }

    /// An edit to an unlocked locked note: sealed again straight away, so plaintext never reaches the store.
    func updateLocked(_ nid: UUID, _ text: String) {
        // Sealed with the key's own salt: if another Mac re-locked the note meanwhile, the stored salt no longer fits the key.
        guard let f = store.folderOf(nid), store.note(f.id, nid)?.lock != nil, let key = keys[nid], let salt = salts[nid],
              let sealed = NoteLock.seal(text, key: key, salt: salt) else { return }
        unlocked[nid] = text
        NoteLock.seal(attachmentsOf: text, in: store.attachmentsDirectory, key: key) // an image just added is sealed at once
        store.updateNote(f.id, nid) { $0.lock = sealed; $0.lockedTitle = MD.title(text); $0.modified = Date() }
    }

    func removeLock(_ fid: UUID, _ nid: UUID) {
        unlock(nid) { [self] in
            guard let text = unlocked[nid], let key = keys[nid] else { return }
            NoteLock.open(attachmentsOf: text, in: store.attachmentsDirectory, key: key, toDir: store.attachmentsDirectory)
            store.updateNote(fid, nid) { $0.text = text; $0.lock = nil; $0.lockedTitle = nil }
            unlocked[nid] = nil
            keys[nid] = nil
            salts[nid] = nil
            flash("Lock removed")
        }
    }

    /// Forgets every unlocked text, key and the password (the panel closing, the screen sleeping, Lock All Now).
    func lockAll() {
        if let password { for f in store.folders where f.locked { seal(folder: f.id, password) } } // notes written in them meanwhile
        if !store.openFolders.isEmpty {
            if store.lockedAway(currentFolder) { route = .folder(store.chain(currentFolder).first(where: \.locked)?.id ?? Folder.rootID) }
            store.openFolders = []
        }
        password = nil
        keys = [:]
        salts = [:]
        if !unlocked.isEmpty { unlocked = [:] }
        try? FileManager.default.removeItem(at: Store.unlockedAttachments) // the opened attachments go too
    }

    /// The password: remembered this session, from Touch ID, or asked for (and checked against a locked note).
    private func withPassword(creating: Bool, checking target: String? = nil, _ done: @escaping (String?) -> Void) {
        if let password { return done(password) }
        let finish: (String?) -> Void = { [self] p in
            if let p {
                password = p
                if UserDefaults.standard.bool(forKey: Prefs.touchID) { Keychain.save(p) }
            }
            done(p)
        }
        if !creating, UserDefaults.standard.bool(forKey: Prefs.touchID), Keychain.load() != nil {
            let context = LAContext()
            if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) {
                PanelController.shared?.holdOpen += 1 // the Touch ID sheet takes focus; don't slide away
                context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "open your locked notes") { ok, _ in
                    DispatchQueue.main.async { [self] in
                        PanelController.shared?.holdOpen -= 1
                        finish(ok ? Keychain.load() : askPassword(creating: false, checking: target))
                    }
                }
                return
            }
        }
        finish(askPassword(creating: creating, checking: target))
    }

    /// Asks for the password; one typed for existing notes is checked against `target` (the note being opened),
    /// else against any locked note.
    private func askPassword(creating: Bool, checking target: String? = nil) -> String? {
        if let answer = Self.passwordAnswer { return answer } // tests answer for the person: no real prompt
        let sample = target ?? store.folders.lazy.flatMap(\.notes).first { $0.lock != nil }?.lock
        let entered: String?? = PanelController.shared?.modal {
            let alert = NSAlert()
            alert.messageText = creating ? "Choose a Password for Locked Notes" : "Enter the Locked Notes Password"
            alert.informativeText = creating
                ? "One password locks and opens all your locked notes. If you forget it, they can't be opened — there's no way to recover it. A locked note's first line stays visible as its title."
                : ""
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
            let again = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            field.placeholderString = "Password"
            again.placeholderString = "Again"
            let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: creating ? 54 : 24))
            if creating { box.addSubview(field); box.addSubview(again) } else { field.frame.origin.y = 0; box.addSubview(field) }
            alert.accessoryView = box
            alert.addButton(withTitle: creating ? "Lock" : "Unlock")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return nil }
            if creating, field.stringValue != again.stringValue {
                let oops = NSAlert()
                oops.messageText = "The passwords didn't match."
                oops.runModal()
                return nil
            }
            return field.stringValue
        }
        guard let password = entered ?? nil else { return nil }
        // Typed for existing locked notes: it has to open one of them.
        if !creating, let sample, let salt = NoteLock.salt(sample), NoteLock.open(sample, key: NoteLock.key(password, salt: salt)) == nil {
            wrongPassword()
            return nil
        }
        return password
    }

    private func wrongPassword() {
        guard Self.passwordAnswer == nil else { return } // tests: no real alert
        _ = PanelController.shared?.modal {
            let alert = NSAlert()
            alert.messageText = "That's not the password for your locked notes."
            alert.runModal()
        }
    }
}
