import AppKit

// AppleScript commands declared in Resources/Cortexy.sdef, e.g.
//   tell application "Cortexy" to add note "Buy milk" in folder "Home"
// Shortcuts can call these through its "Run AppleScript" action.

@objc(CXAddNoteCommand) final class CXAddNoteCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let c = PanelController.shared else { return nil }
        let text = directParameter as? String ?? ""
        let folder = evaluatedArguments?["folder"] as? String
        let open = evaluatedArguments?["show"] as? Bool ?? false
        let id = c.nav.newNote(text: text, folderName: folder, open: open)
        if open { c.show(byHover: false) }
        return id?.uuidString
    }
}

/// `append text "milk" in note "Groceries"` (or "today", or nothing: the Inbox note).
@objc(CXAppendCommand) final class CXAppendCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let c = PanelController.shared else { return false }
        return c.nav.append(directParameter as? String ?? "", to: evaluatedArguments?["target"] as? String)
    }
}

@objc(CXShowCommand) final class CXShowCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? { PanelController.shared?.show(byHover: false); return nil }
}

@objc(CXHideCommand) final class CXHideCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? { PanelController.shared?.hide(); return nil }
}

@objc(CXToggleCommand) final class CXToggleCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? { PanelController.shared?.toggle(); return nil }
}

/// Returns the text of every note containing the search string.
@objc(CXSearchCommand) final class CXSearchCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let store = PanelController.shared?.store, let q = directParameter as? String else { return [String]() }
        return store.liveFolders.flatMap(\.notes).filter { MD.finds(q, in: $0.text) }.map(\.text)
    }
}

/// Services menu: select text in any app → Services → New Cortexy Note.
final class ServiceProvider: NSObject {
    @objc func newNote(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pboard.string(forType: .string), let c = PanelController.shared else {
            error.pointee = "No text to add." as NSString
            return
        }
        c.nav.newNote(text: text)
        c.show(byHover: false)
    }
}
