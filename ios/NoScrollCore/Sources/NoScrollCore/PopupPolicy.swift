import Foundation

/// How the wrapper should handle `window.open` / `target=_blank`.
///
/// X's "Sign in with Google" is Google Identity Services in *popup* mode: the
/// chooser `postMessage`s the credential back to `window.opener` (the x.com
/// page) and then calls `window.close()`. Loading that popup in the parent
/// WebView destroys the opener. Sign-in "succeeds" on Google's side and the
/// wrapper is left on Google's blank completion page — a white screen.
public enum NewWindowAction: Equatable, Sendable {
    /// Create a child WKWebView from WebKit's provided configuration and return
    /// it. That is what keeps `window.opener` set.
    case openChild
    /// Load the request in the existing WebView. Used for same-site
    /// `target=_blank` links (a photo, a permalink) that are not an auth flow.
    case navigateInPlace
}

/// URL policy for OAuth popups and X's post-login white-screen recoveries.
///
/// Pure functions so the cases that brick login can be tested on the host
/// without a simulator or a Google account.
public enum PopupPolicy {

    public static let xHomeURL = URL(string: "https://x.com/home")!

    /// Hosts that are entire auth surfaces. Mirrors `CORE_AUTH_HOSTS` in
    /// `engine/src/authguard.ts` plus the Google SSO host GSI actually uses.
    private static let ssoHostSuffixes = [
        "accounts.google.com",
        "accounts.youtube.com",
        "appleid.apple.com",
        "login.microsoftonline.com",
    ]

    /// Path prefixes that are login / SSO intermediaries. A `window.open` to
    /// one of these on x.com is the first hop of Google sign-in, not a content
    /// link — it must stay a child or the opener dies on the next hop.
    private static let authPathPrefixes = [
        "/accounts/", "/challenge/", "/oauth/", "/two_factor",
        "/emailsignup", "/recover/", "/signin", "/signup",
        "/login", "/register", "/logout", "/2fa", "/verify",
        "/servicelogin", "/i/flow/", "/i/jf/", "/account/",
    ]

    public static func newWindowAction(url: URL?, currentHost: String) -> NewWindowAction {
        guard let url else { return .openChild }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme.isEmpty || scheme == "about" { return .openChild }
        if isSSOPopupHost(url.host ?? "") { return .openChild }
        if isGoogleGSIPopup(url) { return .openChild }
        if isAuthPath(url.path) { return .openChild }
        // Same-site content: keep the existing in-place behaviour so a
        // permalink opened with target=_blank does not become a modal.
        if hostsMatch(url.host, currentHost) { return .navigateInPlace }
        return .openChild
    }

    public static func isSSOPopupHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h.isEmpty { return false }
        return ssoHostSuffixes.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    /// Google Identity Services popup: the account chooser *and* the `/o/oauth2`
    /// hop. Markers taken from the GSI SDK (`ux_mode=popup`, `gsiwebsdk`,
    /// `redirect_uri=gis_transform`) plus a `/gsi` path segment.
    public static func isGoogleGSIPopup(_ url: URL) -> Bool {
        guard isGoogleSSOHost(url.host) else { return false }
        let path = url.path.lowercased()
        if path.contains("gsi") { return true }
        if path.contains("/o/oauth2") { return true }
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return false
        }
        for item in items {
            let name = item.name.lowercased()
            let value = (item.value ?? "").lowercased()
            if (name == "ux_mode" || name == "display") && value == "popup" { return true }
            if name == "gsiwebsdk" { return true }
            if name == "redirect_uri" && value.contains("gis_transform") { return true }
        }
        return false
    }

    /// After a popup-style GSI completion the document is blank and JS calls
    /// `window.close()`. If that page landed in the *parent* (the old in-place
    /// load), bounce to X Home instead of sitting on white.
    public static func isGoogleAuthCompletion(_ url: URL) -> Bool {
        guard isGoogleSSOHost(url.host) else { return false }
        let path = url.path.lowercased()
        return path.contains("/gsi/transform")
            || path.contains("/o/oauth2/approval")
            || path.contains("/o/oauth2/postmessagerelay")
    }

    public static func isAuthPath(_ path: String) -> Bool {
        let p = path.lowercased()
        return authPathPrefixes.contains { prefix in
            if p.hasPrefix(prefix) { return true }
            // "/i/flow/" must also match the directory without the trailing slash.
            if prefix.hasSuffix("/") && p == String(prefix.dropLast()) { return true }
            return false
        }
    }

    public static func isXHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "x.com" || host.hasSuffix(".x.com")
            || host == "twitter.com" || host.hasSuffix(".twitter.com")
    }

    /// `https://x.com/` with no path is a known blank page on X's mobile web
    /// once a session exists. The wrapper's home is `/home`.
    public static func isBlankXRoot(_ url: URL) -> Bool {
        guard isXHost(url.host) else { return false }
        return url.path.isEmpty || url.path == "/"
    }

    /// Parent was left on Google / a blank X root after the popup closed.
    /// Reload Home so the user is not stranded on white.
    public static func shouldLoadXHome(afterClosingPopup parentURL: URL?) -> Bool {
        guard let url = parentURL else { return true }
        if isSSOPopupHost(url.host ?? "") { return true }
        if isGoogleAuthCompletion(url) { return true }
        if isBlankXRoot(url) { return true }
        return false
    }

    /// X hands a WebView a custom scheme instead of a page. Rewrite to https
    /// so the session stays in NoScroll instead of cancelling into white.
    public static func httpsEquivalent(_ url: URL) -> URL? {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "x-safari-https" || scheme == "twitter-https" {
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            comps?.scheme = "https"
            return comps?.url
        }
        if scheme == "twitter" || scheme == "x" {
            return xHomeURL
        }
        return nil
    }

    public static func isInPageScheme(_ scheme: String?) -> Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        return ["http", "https", "about", "data", "blob"].contains(scheme)
    }

    // MARK: - Private

    private static func isGoogleSSOHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "accounts.google.com" || host.hasSuffix(".accounts.google.com")
            || host == "accounts.youtube.com" || host.hasSuffix(".accounts.youtube.com")
    }

    private static func hostsMatch(_ a: String?, _ b: String) -> Bool {
        let left = (a ?? "").lowercased()
        let right = b.lowercased()
        if left.isEmpty || right.isEmpty { return false }
        return left == right
    }
}
