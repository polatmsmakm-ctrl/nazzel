import Foundation
import UIKit
import WebKit

/// A site the user can sign in to, so private or age-restricted posts can be downloaded.
struct LoginSite: Identifiable, Hashable {
    let id: String
    let name: String
    let symbol: String
    let loginURL: URL
    let domains: [String]
    /// Cookies that only exist after a successful sign-in.
    let sessionCookies: [String]

    static let all: [LoginSite] = [
        LoginSite(id: "instagram", name: "إنستقرام", symbol: "camera",
                  loginURL: URL(string: "https://www.instagram.com/accounts/login/")!,
                  domains: ["instagram.com"], sessionCookies: ["sessionid"]),
        LoginSite(id: "x", name: "إكس (تويتر)", symbol: "at",
                  loginURL: URL(string: "https://x.com/i/flow/login")!,
                  domains: ["x.com", "twitter.com"], sessionCookies: ["auth_token"]),
        LoginSite(id: "tiktok", name: "تيك توك", symbol: "music.note",
                  loginURL: URL(string: "https://www.tiktok.com/login")!,
                  domains: ["tiktok.com"], sessionCookies: ["sessionid", "sessionid_ss"]),
        LoginSite(id: "facebook", name: "فيسبوك", symbol: "person.2",
                  loginURL: URL(string: "https://m.facebook.com/login/")!,
                  domains: ["facebook.com"], sessionCookies: ["c_user"]),
        LoginSite(id: "youtube", name: "يوتيوب", symbol: "play.rectangle",
                  loginURL: URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fm.youtube.com%2F")!,
                  domains: ["youtube.com", "google.com"], sessionCookies: ["SAPISID", "__Secure-3PSID", "LOGIN_INFO"]),
        LoginSite(id: "snapchat", name: "سناب شات", symbol: "bolt",
                  loginURL: URL(string: "https://accounts.snapchat.com/accounts/v2/login")!,
                  domains: ["snapchat.com"], sessionCookies: ["__Host-sc-a-auth-session", "sc-a-nonce"]),
    ]

    func owns(_ cookie: HTTPCookie) -> Bool {
        let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        return domains.contains { domain == $0 || domain.hasSuffix("." + $0) }
    }
}

/// Bridges the in-app browser's cookies to yt-dlp (Netscape cookies.txt).
@MainActor
enum CookieStore {
    private static var store: WKHTTPCookieStore { WKWebsiteDataStore.default().httpCookieStore }

    static func allCookies() async -> [HTTPCookie] {
        await store.allCookies()
    }

    static func isSignedIn(_ site: LoginSite) async -> Bool {
        let cookies = await allCookies()
        return cookies.contains { site.owns($0) && site.sessionCookies.contains($0.name) }
    }

    static func signOut(_ site: LoginSite) async {
        for cookie in await allCookies() where site.owns(cookie) {
            await store.deleteCookie(cookie)
        }
        await exportForEngine()
    }

    /// Writes every cookie from the in-app browser to cookies.txt for yt-dlp.
    static func exportForEngine() async {
        let cookies = await allCookies()
        var lines = ["# Netscape HTTP Cookie File", "# Written by Nazzel", ""]
        for cookie in cookies {
            if cookie.value.contains(where: { $0 == "\t" || $0 == "\n" }) { continue }
            let domain = cookie.domain
            let includeSubdomains = domain.hasPrefix(".") ? "TRUE" : "FALSE"
            let expiry = cookie.expiresDate.map { String(Int($0.timeIntervalSince1970)) } ?? "0"
            lines.append([
                domain, includeSubdomains, cookie.path.isEmpty ? "/" : cookie.path,
                cookie.isSecure ? "TRUE" : "FALSE", expiry, cookie.name, cookie.value,
            ].joined(separator: "\t"))
        }
        Paths.ensure()
        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(to: Paths.cookies, atomically: true, encoding: .utf8)
    }

    /// Mobile Safari user agent so sign-in pages treat the web view like the real browser.
    static var safariUserAgent: String {
        let version = UIDevice.current.systemVersion.replacingOccurrences(of: ".", with: "_")
        let major = UIDevice.current.systemVersion.split(separator: ".").first.map(String.init) ?? "18"
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(version) like Mac OS X) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/\(major).0 Mobile/15E148 Safari/604.1"
    }
}
