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
    ///
    /// `/gsi/issue` is the token page. It is also blank, and `window.close()`
    /// often never reaches WKWebView on iOS, so the child overlay stays white.
    public static func isGoogleAuthCompletion(_ url: URL) -> Bool {
        guard isGoogleSSOHost(url.host) else { return false }
        let path = url.path.lowercased()
        return path.contains("/gsi/transform")
            || path.contains("/gsi/issue")
            || path.contains("/o/oauth2/approval")
            || path.contains("/o/oauth2/postmessagerelay")
    }

    /// The child overlay is a full-screen white page when GSI finishes.
    /// Close it. Do not close the account chooser or X's own login hop.
    public static func shouldDismissPopup(_ url: URL?) -> Bool {
        guard let url else { return false }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme.isEmpty || scheme == "about" { return false }
        if isGoogleAuthCompletion(url) { return true }
        if isXHost(url.host) {
            if isAuthPath(url.path) { return false }
            if isBlankXRoot(url) { return true }
            if scheme == "http" || scheme == "https" { return true }
        }
        return false
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
    ///
    /// When Google just finished, the parent is usually still
    /// `/i/flow/login`. iOS 17.5+ nulls `window.opener` on the cross-site
    /// hop, so X never leaves that page. Home is the recovery.
    public static func shouldLoadXHome(afterClosingPopup parentURL: URL?,
                                       googleAuthJustFinished: Bool = false) -> Bool {
        if googleAuthJustFinished {
            guard let url = parentURL else { return true }
            if isXHost(url.host), !isBlankXRoot(url), !isAuthPath(url.path) {
                return false
            }
            return true
        }
        guard let url = parentURL else { return true }
        if isSSOPopupHost(url.host ?? "") { return true }
        if isGoogleAuthCompletion(url) { return true }
        if isBlankXRoot(url) { return true }
        return false
    }

    /// Saved interaction state can reopen the white Google page or `x.com/`.
    public static func shouldRestoreSavedURL(_ url: URL, serviceID: String) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else { return false }
        if serviceID == "x" {
            if isGoogleAuthCompletion(url) { return false }
            if isSSOPopupHost(url.host ?? "") { return false }
            if isBlankXRoot(url) { return false }
        }
        return true
    }

    /// Native payload from the popup opener shim.
    public struct OpenerBridgeMessage: Equatable, Sendable {
        public var isClose: Bool
        public var origin: String
        public var dataJSON: String?
    }

    public static func parseOpenerBridgeMessage(_ body: Any) -> OpenerBridgeMessage? {
        guard let dict = body as? [String: Any] else { return nil }
        let type = (dict["type"] as? String ?? "").lowercased()
        let origin = dict["origin"] as? String ?? ""
        if type == "close" { return OpenerBridgeMessage(isClose: true, origin: origin, dataJSON: nil) }
        if type == "postmessage" || dict["data"] != nil {
            guard let dataJSON = jsonString(dict["data"] ?? NSNull()) else { return nil }
            return OpenerBridgeMessage(isClose: false, origin: origin, dataJSON: dataJSON)
        }
        return nil
    }

    /// Replay GSI's `postMessage` on the x.com page after iOS dropped opener.
    public static func parentMessageEventScript(dataJSON: String, origin: String) -> String {
        let originJSON = jsonString(origin) ?? "\"\""
        return """
        (function(){
          var data = \(dataJSON);
          var origin = \(originJSON);
          var event = new MessageEvent('message', { data: data, origin: origin });
          window.dispatchEvent(event);
        })();
        """
    }

    /// Runs at document start in the child window. Forwards `opener.postMessage`
    /// to native when iOS 17.5+ has nulled `window.opener`.
    public static let openerShimJavaScript = """
    (function() {
      if (window.__noscrollOpenerShim) return;
      var href = String(location.href || '');
      var host = String(location.hostname || '').toLowerCase();
      var isBlank = href === 'about:blank' || href === 'about:blank/' || href === '';
      var isGoogle = host === 'accounts.google.com' || host.indexOf('.accounts.google.com') !== -1
        || host === 'accounts.youtube.com' || host.indexOf('.accounts.youtube.com') !== -1;
      if (!isBlank && !isGoogle) return;
      window.__noscrollOpenerShim = true;
      function forward(data) {
        try {
          window.webkit.messageHandlers.noscrollOpener.postMessage({
            type: 'postMessage',
            origin: String(location.origin || ''),
            data: data
          });
        } catch (e) {}
      }
      function closeNative() {
        try {
          window.webkit.messageHandlers.noscrollOpener.postMessage({
            type: 'close',
            origin: String(location.origin || '')
          });
        } catch (e) {}
      }
      var fake = {
        closed: false,
        postMessage: function(data) { forward(data); },
        focus: function() {},
        blur: function() {},
        close: function() {}
      };
      var patched = false;
      try {
        if (window.opener && window.opener !== window && window.opener.postMessage) {
          var real = window.opener.postMessage.bind(window.opener);
          window.opener.postMessage = function(data, targetOrigin, transfer) {
            forward(data);
            try { return real(data, targetOrigin, transfer); } catch (e) {}
          };
          patched = true;
        }
      } catch (e) {}
      if (!patched) {
        try {
          Object.defineProperty(window, 'opener', {
            configurable: true,
            get: function() { return fake; },
            set: function() {}
          });
        } catch (e) {
          try { window.opener = fake; } catch (e2) {}
        }
      }
      try {
        var realClose = window.close.bind(window);
        window.close = function() {
          closeNative();
          try { return realClose(); } catch (e) {}
        };
      } catch (e) {}
    })();
    """

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

    private static func jsonString(_ value: Any) -> String? {
        if let text = value as? String {
            return jsonFragment(text)
        }
        if let flag = value as? Bool {
            return flag ? "true" : "false"
        }
        if value is NSNull { return "null" }
        if JSONSerialization.isValidJSONObject(value) {
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return text
        }
        if let data = try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys]),
           let array = String(data: data, encoding: .utf8),
           array.count >= 2 {
            return String(array.dropFirst().dropLast())
        }
        return nil
    }

    private static func jsonFragment(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}
