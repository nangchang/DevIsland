import AppKit

extension TerminalFocuser {
    static func orcaCLIURL(for appURL: URL) -> URL {
        appURL.appendingPathComponent("Contents/Resources/bin/orca")
    }
}
