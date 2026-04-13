import Foundation

/// All supported analytics platforms.
public enum Platform: String, CaseIterable, Codable, Sendable, Identifiable {
    public var id: String { rawValue }
    case buttondown
    case goatCounter = "goat_counter"
    case vercel
    case calendly
    case amazon
    case mastodon
    case jetpack
    case bluesky
    case linkedin
    case oreilly
    case substack
    case googleSearchConsole = "google_search_console"
    case buffer
    case hackerNews = "hacker_news"

    public var displayName: String {
        switch self {
        case .buttondown:          "Buttondown"
        case .goatCounter:         "GoatCounter"
        case .vercel:              "Vercel"
        case .calendly:            "Calendly"
        case .amazon:              "Amazon KDP"
        case .mastodon:            "Mastodon"
        case .jetpack:             "Jetpack Stats"
        case .bluesky:             "Bluesky"
        case .linkedin:            "LinkedIn"
        case .oreilly:             "O'Reilly"
        case .substack:            "Substack"
        case .googleSearchConsole: "Google Search Console"
        case .buffer:              "Buffer"
        case .hackerNews:          "Hacker News"
        }
    }

    public var authType: AuthType {
        switch self {
        case .buttondown, .goatCounter, .vercel, .calendly, .buffer:
            return .apiKey
        case .mastodon, .jetpack, .bluesky, .googleSearchConsole:
            return .oauthToken
        case .amazon, .linkedin, .oreilly, .substack:
            return .fileExport
        case .hackerNews:
            return .noAuth
        }
    }
}

public enum AuthType: Sendable {
    /// Platform uses a static API key or token.
    case apiKey
    /// Platform uses OAuth or a bearer token; may require an instance URL (Mastodon).
    case oauthToken
    /// Data is imported from a manually-downloaded export file.
    case fileExport
    /// No authentication required (e.g. public search APIs).
    case noAuth
}
