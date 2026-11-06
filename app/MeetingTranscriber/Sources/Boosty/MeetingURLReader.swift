import ApplicationServices
import Foundation

/// Read-only Accessibility scan. Does not open meeting menus or modify the
/// clipboard; ambiguity is returned to the user instead of guessing a bot.
enum MeetingURLReader {
    static func read(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let application = AXUIElementCreateApplication(pid)
        let pattern = #"https://(?:[A-Za-z0-9.-]+\.)?(?:zoom\.us/(?:j|s|w|my)/[A-Za-z0-9._?=&%-]+"#
            + #"|meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}"#
            + #"|teams\.(?:microsoft|live)\.com/[^\s\"<>]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        var visited = 0
        var urls: Set<String> = []
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth <= 8, visited < 500 else { return }
            visited += 1
            for attribute in [kAXURLAttribute, kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { continue }
                let text = (value as? String) ?? (value as? URL)?.absoluteString ?? ""
                guard text.count <= 4000 else { continue }
                for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    if let range = Range(match.range, in: text) { urls.insert(String(text[range])) }
                }
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let children = children as? [AXUIElement] {
                for child in children {
                    walk(child, depth: depth + 1)
                }
            }
        }
        walk(application, depth: 0)
        return urls.count == 1 ? urls.first : nil
    }
}
