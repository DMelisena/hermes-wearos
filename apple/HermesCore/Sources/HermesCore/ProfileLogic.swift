import Foundation

/// Agent switcher logic (port of `domain/ProfileLogic.kt`): the base URL is profile-scoped
/// (`http://host:8642/p/wear`) and switching agent swaps the `/p/<profile>` segment. Watch-made
/// sessions are `<profile>-watch-xxxx` (SPEC §3).
public enum ProfileLogic {
    public static let fallbackAgent = "wear"
    /// The multiplexed HOME profile — it IS the desktop/computer.
    public static let profileComputer = "default"
    public static let defaultAgents = ["wear", "default"]

    private static let profileRe = try! NSRegularExpression(pattern: "^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$")
    private static let watchRe = try! NSRegularExpression(pattern: "^[A-Za-z0-9][A-Za-z0-9._-]*-watch(-.*)?$")

    static func full(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    public static func isValidProfile(_ name: String) -> Bool { full(profileRe, name) }

    /// Byte offsets of the `/p/<seg>` segment after the authority, if any.
    private static func segment(_ b: String) -> (start: String.Index, end: String.Index)? {
        guard let scheme = b.range(of: "://") else { return nil }
        guard let from = b[scheme.upperBound...].firstIndex(of: "/") else { return nil }
        guard let p = b.range(of: "/p/", range: from..<b.endIndex) else { return nil }
        let segEnd = b[p.upperBound...].firstIndex(of: "/") ?? b.endIndex
        return (p.upperBound, segEnd)
    }

    static func trimBase(_ s: String) -> String {
        var b = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        return b
    }

    public static func currentProfile(_ baseUrl: String) -> String {
        let b = trimBase(baseUrl)
        guard let seg = segment(b) else { return "" }
        return String(b[seg.start..<seg.end])
    }

    /// Swap (or append) the profile segment; invalid profile or junk URL → nil.
    public static func swapProfile(_ baseUrl: String, _ profile: String) -> String? {
        guard isValidProfile(profile) else { return nil }
        let b = trimBase(baseUrl)
        guard !b.isEmpty, let scheme = b.range(of: "://") else { return nil }
        guard b[scheme.upperBound...].contains("/"), let seg = segment(b) else { return "\(b)/p/\(profile)" }
        return String(b[..<seg.start]) + profile + String(b[seg.end...])
    }

    public static func sessionPrefix(_ profile: String) -> String {
        let p = profile.trimmingCharacters(in: .whitespaces)
        return "\(p.isEmpty ? fallbackAgent : p)-watch-"
    }

    public static func newSessionId(_ profile: String, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> String {
        sessionPrefix(profile) + String(nowMs, radix: 36)
    }

    public static func isWatchSession(_ id: String) -> Bool { full(watchRe, id) }

    public static func shortLabel(_ profile: String) -> String { String(profile.prefix(8)) }

    public static func displayAgents(_ fetched: [String], current: String) -> [String] {
        var seen = Set<String>()
        var base = fetched.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && seen.insert($0).inserted }
        if base.isEmpty { base = defaultAgents }
        return current.isEmpty || base.contains(current) ? base : base + [current]
    }

    public static func chipLabel(_ profile: String) -> String {
        profile == profileComputer ? "💻 computer" : shortLabel(profile)
    }
}
