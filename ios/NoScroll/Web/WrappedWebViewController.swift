import AVFoundation
import Foundation
import UIKit
import WebKit

/// The wrapped browser.
///
/// Most of this file exists because of specific, documented failures in the app
/// we are cloning. Each one is annotated with the symptom it prevents — none of
/// this is defensive boilerplate.
final class WrappedWebViewController: UIViewController {

    private let session: WebSession
    private let startURL: URL
    private let engineSource: String
    private let bundleRaw: Data
    private let settings: [String: Bool]
    private let telemetry: Bool
    private let onBridge: (BridgeMessage) -> Void

    private var webView: WKWebView!
    private var restorationState: Data?
    /// Child windows for `window.open` (Google Identity Services on X).
    /// The parent WebView must stay on x.com — that is `window.opener`.
    private var popupWebViews: [WKWebView] = []
    private var popupChrome: [UIView] = []
    /// Popups that have navigated off `about:blank`. Returning to blank after
    /// that means GSI finished and called close() without a close event.
    private var popupLeftBlank: [ObjectIdentifier: Bool] = [:]
    /// One-shot: `/` → `/home` must not bounce if X then redirects back to `/`.
    private var didRecoverBlankXRoot = false
    /// Google finished in the child. Parent is often still `/i/flow/login`.
    private var googleAuthJustFinished = false
    /// Cancels a queued Home load if a later SSO event supersedes it.
    private var pendingHomeLoadGeneration = 0

    init(session: WebSession,
         startURL: URL,
         dataStore: WKWebsiteDataStore,
         engineSource: String,
         bundleRaw: Data,
         settings: [String: Bool],
         telemetry: Bool,
         onBridge: @escaping (BridgeMessage) -> Void) {
        self.session = session
        self.startURL = startURL
        self.engineSource = engineSource
        self.bundleRaw = bundleRaw
        self.settings = settings
        self.telemetry = telemetry
        self.onBridge = onBridge
        super.init(nibName: nil, bundle: nil)
        configure(dataStore: dataStore)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    // MARK: - Configuration

    private func configure(dataStore: WKWebsiteDataStore) {
        let controller = WKUserContentController()

        // The engine runs at documentStart so blocking CSS lands before first
        // paint. Injecting at documentEnd would let a Reel render and then
        // vanish, and that flicker is what makes a blocker feel broken.
        let config = engineConfigJSON()
        let bootstrap = """
        window.__NOSCROLL_CONFIG = \(config);
        \(engineSource)
        """
        controller.addUserScript(WKUserScript(source: bootstrap,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false))
        controller.add(BridgeHandler(onBridge), name: "noscroll")

        if session.service == "snapchat" {
            // Snapchat removes web sign-in entirely below its desktop breakpoint.
            // Apply only to Snapchat's web client, leaving account forms responsive.
            let desktopViewport = """
            if (["snapchat.com", "www.snapchat.com", "web.snapchat.com"].includes(location.hostname)) {
                const applyViewport = () => {
                    let viewport = document.querySelector('meta[name="viewport"]');
                    if (!viewport) {
                        viewport = document.createElement('meta');
                        viewport.name = 'viewport';
                        document.head.appendChild(viewport);
                    }
                    if (viewport.content !== 'width=1024') viewport.content = 'width=1024';
                };
                applyViewport();
                new MutationObserver(applyViewport).observe(document.head,
                    {childList: true, subtree: true, attributes: true, attributeFilter: ['content']});
            }
            """
            controller.addUserScript(WKUserScript(source: desktopViewport,
                                                  injectionTime: .atDocumentEnd,
                                                  forMainFrameOnly: true))
        }

        let cfg = WKWebViewConfiguration()
        cfg.userContentController = controller
        cfg.websiteDataStore = dataStore
        // X's Google sign-in is window.open(). If this is false the popup never
        // appears, GSI falls through to a full-page load, and the wrapper is
        // left on Google's blank completion page.
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = true

        // Without these, video plays fullscreen-only and is silent unless the
        // ringer is on — a specific, repeated complaint about SocialLite.
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []

        // Snapchat redirects mobile browsers to a desktop-only promotional
        // page. Request its desktop site inside the same persistent WebKit store.
        if session.service == "snapchat" {
            cfg.defaultWebpagePreferences.preferredContentMode = .desktop
        }
        webView = WKWebView(frame: .zero, configuration: cfg)
        if session.service == "snapchat" {
            let version = ProcessInfo.processInfo.operatingSystemVersion
            webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(version.majorVersion).\(version.minorVersion) Safari/605.1.15"
        }
        if session.service == "x" {
            // X sends the stock embedded UA to x-safari-https:// instead of a page.
            // Identify the same WebKit engine as mobile Safari to stay in NoScroll.
            let version = ProcessInfo.processInfo.operatingSystemVersion
            webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS \(version.majorVersion)_\(version.minorVersion) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(version.majorVersion).\(version.minorVersion) Mobile/15E148 Safari/604.1"
        }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
    }

    private func engineConfigJSON() -> String {
        let bundleJSON = String(data: bundleRaw, encoding: .utf8) ?? "{}"
        let settingsJSON = (try? JSONSerialization.data(withJSONObject: settings))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
        { "bundle": \(bundleJSON), "settings": \(settingsJSON), "telemetry": \(telemetry) }
        """
    }

    // MARK: - Lifecycle

    override func loadView() {
        // The view used to BE the WKWebView. Popup chrome cannot be a subview
        // of WKWebView — WebKit does not support that — so the web view sits
        // inside a plain container and Google's child window stacks on top.
        view = UIView()
        view.backgroundColor = .systemBackground
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installMainWebView()
        configureAudioSession()
        restoreOrLoad()

        NotificationCenter.default.addObserver(
            self, selector: #selector(saveState),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    private func installMainWebView() {
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// Video that plays silently unless the ringer is on is an audio-session
    /// problem, not a WebKit one.
    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    /// iOS reaps the WebView process under memory pressure. Without restoration,
    /// switching to an authenticator app during 2FA and coming back produces a
    /// white screen and forces a restart — which blocks login entirely. That is
    /// a real, reported SocialLite bug and it is the single worst one, because
    /// the user cannot get past it.
    private func restoreOrLoad() {
        // Old builds saved even an empty history (observed for X on-device).
        // Assigning that state succeeds but loads nothing, leaving a white page.
        if let state = restorationState ?? UserDefaults.standard.data(forKey: stateKey) {
            webView.interactionState = state
            if let item = webView.backForwardList.currentItem,
               PopupPolicy.shouldRestoreSavedURL(item.url, serviceID: session.service),
               // Discard Snapchat's old mobile "use your computer" landing page.
               !(session.service == "snapchat"
                 && ["www.snapchat.com", "snapchat.com"].contains(item.url.host ?? "")
                 && (item.url.path.hasPrefix("/web") || item.url.path == "/")) {
                webView.go(to: item)
                return
            }
        }
        webView.load(URLRequest(url: homeURL()))
    }

    private var stateKey: String { "noscroll.state.\(session.id.uuidString)" }

    @objc private func saveState() {
        guard let item = webView.backForwardList.currentItem,
              PopupPolicy.shouldRestoreSavedURL(item.url, serviceID: session.service) else { return }
        if let state = webView.interactionState as? Data {
            restorationState = state
            UserDefaults.standard.set(state, forKey: stateKey)
        }
    }

    /// Supplied by the caller from the service definition. It used to be a
    /// switch over two hardcoded cases with `default: instagram`, which sent
    /// all six other services to Instagram.
    private func homeURL() -> URL { startURL }
}

// MARK: - Navigation

extension WrappedWebViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {

        guard let url = navigationAction.request.url else {
            decisionHandler(.allow); return
        }

        // X sends a WebView to x-safari-https:// (or twitter://) instead of a
        // page. Cancelling that used to leave a white screen after Google SSO.
        if let https = PopupPolicy.httpsEquivalent(url) {
            decisionHandler(.cancel)
            if isPopup(webView) {
                dismissPopup(webView)
                self.webView.load(URLRequest(url: https))
            } else {
                webView.load(URLRequest(url: https))
            }
            return
        }

        // Cancel other app-scheme navigations. Instagram's web pages try hard
        // to hand off to the native app; since we have that app shielded,
        // following the link would eject the user into a shield screen
        // mid-flow and look like the wrapper crashed.
        if !PopupPolicy.isInPageScheme(url.scheme) {
            decisionHandler(.cancel); return
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if isPopup(webView) {
            // Second chance if the document-start script missed this hop.
            webView.evaluateJavaScript(PopupPolicy.openerShimJavaScript, completionHandler: nil)
            scheduleDismissIfGoogleFinished(webView)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === self.webView { saveState() }
        recoverIfParentStuckOnWhite(webView)
        dismissPopupIfReturnedToBlank(webView)
        dismissPopupIfLandedOnX(webView)
    }

    /// A crashed WebView must recover, not sit blank.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if isPopup(webView) {
            dismissPopup(webView)
            return
        }
        restoreOrLoad()
    }
}

// MARK: - UI delegate

/// WKUIDelegate is MANDATORY, not optional. Without these callbacks, `<input
/// type=file>` pickers and getUserMedia fail *silently* — which is exactly the
/// "can't upload a video to posts/story" complaint against SocialLite. The
/// feature looks broken rather than unsupported.
extension WrappedWebViewController: WKUIDelegate {

    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        // Prompt the user via the system permission sheet rather than silently
        // denying. Requires NSCameraUsageDescription / NSMicrophoneUsageDescription.
        decisionHandler(.prompt)
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }

        let currentHost = webView.url?.host ?? ""
        switch PopupPolicy.newWindowAction(url: navigationAction.request.url,
                                           currentHost: currentHost) {
        case .openChild:
            // MUST use the provided configuration and MUST return the child.
            // Returning nil and loading the URL in the parent is what destroyed
            // window.opener for X's Google sign-in and left a white screen.
            return presentPopup(configuration: configuration, from: webView)
        case .navigateInPlace:
            // Same-site target=_blank (a permalink, a photo) stays in place so
            // it does not vanish and does not become a modal.
            webView.load(navigationAction.request)
            return nil
        }
    }

    func webViewDidClose(_ webView: WKWebView) {
        dismissPopup(webView)
    }
}

// MARK: - OAuth popups

extension WrappedWebViewController {

    private func isPopup(_ webView: WKWebView) -> Bool {
        popupWebViews.contains { $0 === webView }
    }

    /// Present GSI / SSO as a real child window so `window.opener` stays the
    /// x.com page. The configuration argument is WebKit's — do not substitute
    /// our own or the opener link is dropped (iOS 17.5+ will still do that on
    /// a cross-site hop; the parent-must-not-move rule still holds).
    private func presentPopup(configuration: WKWebViewConfiguration,
                              from parent: WKWebView) -> WKWebView {
        installOpenerBridge(on: configuration)
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.navigationDelegate = self
        popup.uiDelegate = self
        popup.customUserAgent = parent.customUserAgent
        popup.allowsBackForwardNavigationGestures = true
        popup.translatesAutoresizingMaskIntoConstraints = false

        let chrome = UIView()
        chrome.backgroundColor = .systemBackground
        chrome.translatesAutoresizingMaskIntoConstraints = false

        let done = UIButton(type: .system)
        done.setTitle("Close", for: .normal)
        done.accessibilityLabel = "Close sign-in window"
        done.addTarget(self, action: #selector(closeTopPopup), for: .touchUpInside)
        done.translatesAutoresizingMaskIntoConstraints = false

        chrome.addSubview(done)
        chrome.addSubview(popup)
        view.addSubview(chrome)
        NSLayoutConstraint.activate([
            chrome.topAnchor.constraint(equalTo: view.topAnchor),
            chrome.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chrome.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            done.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            done.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 16),
            popup.topAnchor.constraint(equalTo: done.bottomAnchor, constant: 8),
            popup.leadingAnchor.constraint(equalTo: chrome.leadingAnchor),
            popup.trailingAnchor.constraint(equalTo: chrome.trailingAnchor),
            popup.bottomAnchor.constraint(equalTo: chrome.bottomAnchor),
        ])

        popupWebViews.append(popup)
        popupChrome.append(chrome)
        return popup
    }

    @objc private func closeTopPopup() {
        guard let popup = popupWebViews.last else { return }
        dismissPopup(popup)
    }

    private func dismissPopup(_ popup: WKWebView) {
        guard let idx = popupWebViews.firstIndex(where: { $0 === popup }) else { return }
        popup.stopLoading()
        popup.configuration.userContentController.removeScriptMessageHandler(forName: "noscrollOpener")
        popupChrome[idx].removeFromSuperview()
        popupWebViews.remove(at: idx)
        popupChrome.remove(at: idx)
        popupLeftBlank[ObjectIdentifier(popup)] = nil
        if popupWebViews.isEmpty {
            recoverXAfterSSOIfNeeded()
        }
    }

    /// If the parent was navigated onto Google (or X's blank `/`) the user is
    /// staring at white. Send them to Home; a live session lands on the feed
    /// and a failed one lands on X's own sign-in — never a blank page.
    private func recoverXAfterSSOIfNeeded() {
        guard session.service == "x" else { return }
        guard PopupPolicy.shouldLoadXHome(afterClosingPopup: webView.url,
                                          googleAuthJustFinished: googleAuthJustFinished) else { return }
        if googleAuthJustFinished {
            // Give X's message handler a beat to create the session before
            // we replace the login document.
            pendingHomeLoadGeneration += 1
            let generation = pendingHomeLoadGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self, self.pendingHomeLoadGeneration == generation else { return }
                guard PopupPolicy.shouldLoadXHome(afterClosingPopup: self.webView.url,
                                                  googleAuthJustFinished: true) else { return }
                self.googleAuthJustFinished = false
                self.webView.load(URLRequest(url: PopupPolicy.xHomeURL))
            }
            return
        }
        webView.load(URLRequest(url: PopupPolicy.xHomeURL))
    }

    private func recoverIfParentStuckOnWhite(_ webView: WKWebView) {
        guard session.service == "x", webView === self.webView, let url = webView.url else { return }
        if PopupPolicy.isGoogleAuthCompletion(url) {
            // A redirect-mode hop can finish approval and then go to x.com.
            // Wait before replacing the document so we do not cancel that.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, webView === self.webView,
                      let now = webView.url,
                      PopupPolicy.isGoogleAuthCompletion(now) else { return }
                webView.load(URLRequest(url: PopupPolicy.xHomeURL))
            }
            return
        }
        if PopupPolicy.isBlankXRoot(url) {
            // `/home` can bounce a signed-out visitor back to `/`. Recover once.
            guard !didRecoverBlankXRoot else { return }
            didRecoverBlankXRoot = true
            webView.load(URLRequest(url: PopupPolicy.xHomeURL))
            return
        }
        didRecoverBlankXRoot = false
    }

    private func installOpenerBridge(on configuration: WKWebViewConfiguration) {
        let ucc = configuration.userContentController
        ucc.add(OpenerBridgeHandler(owner: self), name: "noscrollOpener")
        ucc.addUserScript(WKUserScript(source: PopupPolicy.openerShimJavaScript,
                                      injectionTime: .atDocumentStart,
                                      forMainFrameOnly: false))
    }

    func handleOpenerBridge(_ message: WKScriptMessage) {
        guard let parsed = PopupPolicy.parseOpenerBridgeMessage(message.body) else { return }
        googleAuthJustFinished = true
        let popup = message.webView
        if !parsed.isClose, let dataJSON = parsed.dataJSON {
            let origin = parsed.origin.isEmpty ? "https://accounts.google.com" : parsed.origin
            let script = PopupPolicy.parentMessageEventScript(dataJSON: dataJSON, origin: origin)
            webView.evaluateJavaScript(script) { [weak self] _, _ in
                guard let self, let popup, self.isPopup(popup) else { return }
                self.dismissPopup(popup)
            }
            return
        }
        if let popup, isPopup(popup) {
            dismissPopup(popup)
        }
    }

    /// OAuth finished inside the child and landed on X. Cookies are already
    /// in the shared store. Do not do this for Google's blank completion
    /// page — that document still needs a moment to `postMessage`.
    private func dismissPopupIfLandedOnX(_ webView: WKWebView) {
        guard isPopup(webView), let url = webView.url else { return }
        guard PopupPolicy.isXHost(url.host), PopupPolicy.shouldDismissPopup(url) else { return }
        googleAuthJustFinished = true
        dismissPopup(webView)
    }

    /// GSI's blank completion page may never fire `window.close`. Give the
    /// shim a moment to forward the credential, then drop the white overlay.
    private func scheduleDismissIfGoogleFinished(_ webView: WKWebView) {
        guard isPopup(webView), PopupPolicy.shouldDismissPopup(webView.url) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak webView] in
            guard let self, let webView, self.isPopup(webView) else { return }
            self.googleAuthJustFinished = true
            self.dismissPopup(webView)
        }
    }

    private func dismissPopupIfReturnedToBlank(_ webView: WKWebView) {
        guard isPopup(webView) else { return }
        let id = ObjectIdentifier(webView)
        let path = webView.url?.absoluteString ?? ""
        let isBlank = path.isEmpty || path == "about:blank"
        if !isBlank {
            popupLeftBlank[id] = true
        } else if popupLeftBlank[id] == true {
            dismissPopup(webView)
        }
    }
}

// MARK: - Bridge

enum BridgeMessage {
    case probe(ruleId: String, expected: Int, actual: Int, bundleVersion: Int)
    case blocked(ruleId: String, count: Int)
    case route(path: String, blocked: Bool)
    case authSurface(active: Bool)
    case breakage(ruleId: String, detail: String)
    case ready(bundleVersion: Int, service: String)
}

private final class OpenerBridgeHandler: NSObject, WKScriptMessageHandler {
    weak var owner: WrappedWebViewController?
    init(owner: WrappedWebViewController) { self.owner = owner }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        owner?.handleOpenerBridge(message)
    }
}

private final class BridgeHandler: NSObject, WKScriptMessageHandler {
    private let onMessage: (BridgeMessage) -> Void
    init(_ onMessage: @escaping (BridgeMessage) -> Void) { self.onMessage = onMessage }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any],
              let type = dict["type"] as? String else { return }

        switch type {
        case "probe":
            onMessage(.probe(ruleId: dict["ruleId"] as? String ?? "",
                             expected: dict["expected"] as? Int ?? 0,
                             actual: dict["actual"] as? Int ?? 0,
                             bundleVersion: dict["bundleVersion"] as? Int ?? 0))
        case "blocked":
            onMessage(.blocked(ruleId: dict["ruleId"] as? String ?? "",
                               count: dict["count"] as? Int ?? 0))
        case "route":
            onMessage(.route(path: dict["path"] as? String ?? "",
                             blocked: dict["blocked"] as? Bool ?? false))
        case "auth-surface":
            onMessage(.authSurface(active: dict["active"] as? Bool ?? false))
        case "breakage":
            onMessage(.breakage(ruleId: dict["ruleId"] as? String ?? "",
                                detail: dict["detail"] as? String ?? ""))
        case "ready":
            onMessage(.ready(bundleVersion: dict["bundleVersion"] as? Int ?? 0,
                             service: dict["service"] as? String ?? ""))
        default:
            break
        }
    }
}
