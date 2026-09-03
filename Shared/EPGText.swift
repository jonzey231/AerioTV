import Foundation

enum EPGText {
    /// True when the XMLTV sub-title would only repeat what the title or the
    /// description already says: equal to either, or the description begins
    /// with the sub-title in square brackets ("[Der Tote im Heizungsraum] ..."),
    /// which is how Schedules Direct's German lineups ship their synopses.
    /// Dispatcharr passes episodeTitle150 and description1000 through verbatim,
    /// and XC clients never see the sub-title field, so only Direct Connect
    /// showed both lines.
    static func subtitleIsRedundant(_ sub: String?, title: String?, description: String?) -> Bool {
        let s = (sub ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return true }
        if s == (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines) { return true }
        let d = (description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if d.isEmpty { return false }
        return d == s || d.hasPrefix("[\(s)]")
    }
}
