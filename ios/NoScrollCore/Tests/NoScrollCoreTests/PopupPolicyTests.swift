import XCTest
@testable import NoScrollCore

/// Regression tests for the X + Google white screen.
///
/// Symptom: Google sign-in completes, then the wrapper shows a blank page.
/// Cause: the GSI popup was loaded in the parent WebView, so `window.opener`
/// was gone and the completion page had nothing to talk to.
final class PopupPolicyTests: XCTestCase {

    private func url(_ string: String) -> URL {
        URL(string: string)!
    }

    func testGSIChooserOpensAsChildAndNeverNavigatesParent() {
        let chooser = url("https://accounts.google.com/gsi/select?client_id=abc&ux_mode=popup")
        XCTAssertEqual(
            PopupPolicy.newWindowAction(url: chooser, currentHost: "x.com"),
            .openChild,
            "GSI chooser must stay a child so x.com remains window.opener"
        )
        XCTAssertTrue(PopupPolicy.isGoogleGSIPopup(chooser))
    }

    func testOAuth2HopStaysAChild() {
        let oauth = url("https://accounts.google.com/o/oauth2/v2/auth?client_id=abc&display=popup")
        XCTAssertEqual(
            PopupPolicy.newWindowAction(url: oauth, currentHost: "x.com"),
            .openChild
        )
        XCTAssertTrue(PopupPolicy.isGoogleGSIPopup(oauth))
        // Navigating the parent onto this hop is the exact white-screen cause.
        XCTAssertNotEqual(
            PopupPolicy.newWindowAction(url: oauth, currentHost: "x.com"),
            .navigateInPlace
        )
    }

    func testBlankWindowOpenIsAChild() {
        // GSI often does window.open('', 'google_gsi') first.
        XCTAssertEqual(
            PopupPolicy.newWindowAction(url: url("about:blank"), currentHost: "x.com"),
            .openChild
        )
        XCTAssertEqual(
            PopupPolicy.newWindowAction(url: nil, currentHost: "x.com"),
            .openChild
        )
    }

    func testXAuthIntermediaryOnXComIsAChild() {
        let sso = url("https://x.com/i/flow/single_sign_on")
        XCTAssertEqual(
            PopupPolicy.newWindowAction(url: sso, currentHost: "x.com"),
            .openChild,
            "X's own SSO hop must not replace the login page"
        )
    }

    func testSameSitePermalinkStillNavigatesInPlace() {
        let post = url("https://www.instagram.com/p/Cabc123/")
        XCTAssertEqual(
            PopupPolicy.newWindowAction(url: post, currentHost: "www.instagram.com"),
            .navigateInPlace
        )
    }

    func testRedirectModeGoogleWithoutPopupMarkersIsStillSSOHost() {
        // LinkedIn-style redirect: no GSI popup markers, but the host is still
        // an auth surface. A window.open to it must not replace the opener.
        let redirect = url("https://accounts.google.com/o/oauth2/auth?redirect_uri=https://www.linkedin.com/")
        XCTAssertEqual(
            PopupPolicy.newWindowAction(url: redirect, currentHost: "www.linkedin.com"),
            .openChild
        )
    }

    func testOrdinaryXHostIsNotSSO() {
        XCTAssertFalse(PopupPolicy.isSSOPopupHost("x.com"))
        XCTAssertFalse(PopupPolicy.isSSOPopupHost("www.google.com"))
        XCTAssertTrue(PopupPolicy.isSSOPopupHost("accounts.google.com"))
        XCTAssertTrue(PopupPolicy.isSSOPopupHost("accounts.youtube.com"))
    }

    func testBlankXRootIsThePostLoginWhitePage() {
        XCTAssertTrue(PopupPolicy.isBlankXRoot(url("https://x.com/")))
        XCTAssertTrue(PopupPolicy.isBlankXRoot(url("https://twitter.com/")))
        XCTAssertFalse(PopupPolicy.isBlankXRoot(url("https://x.com/home")))
        XCTAssertFalse(PopupPolicy.isBlankXRoot(url("https://x.com/i/flow/login")))
    }

    func testRecoverHomeWhenParentWasLeftOnGoogleOrBlankRoot() {
        XCTAssertTrue(PopupPolicy.shouldLoadXHome(afterClosingPopup: nil))
        XCTAssertTrue(PopupPolicy.shouldLoadXHome(
            afterClosingPopup: url("https://accounts.google.com/gsi/transform")))
        XCTAssertTrue(PopupPolicy.shouldLoadXHome(afterClosingPopup: url("https://x.com/")))
        XCTAssertFalse(PopupPolicy.shouldLoadXHome(
            afterClosingPopup: url("https://x.com/i/flow/login")))
        XCTAssertFalse(PopupPolicy.shouldLoadXHome(
            afterClosingPopup: url("https://x.com/home")))
    }

    func testGoogleCompletionPagesAreRecognised() {
        XCTAssertTrue(PopupPolicy.isGoogleAuthCompletion(
            url("https://accounts.google.com/gsi/transform")))
        XCTAssertTrue(PopupPolicy.isGoogleAuthCompletion(
            url("https://accounts.google.com/o/oauth2/postmessagerelay")))
        XCTAssertTrue(PopupPolicy.isGoogleAuthCompletion(
            url("https://accounts.google.com/gsi/issue")))
        XCTAssertTrue(PopupPolicy.isGoogleAuthCompletion(
            url("https://accounts.google.com/gsi/transform?client_id=abc")))
        XCTAssertFalse(PopupPolicy.isGoogleAuthCompletion(
            url("https://accounts.google.com/gsi/select?client_id=abc")))
        XCTAssertFalse(PopupPolicy.isGoogleAuthCompletion(
            url("https://accounts.google.com/o/oauth2/v2/auth?client_id=abc")))
    }

    func testDismissPopupOnGoogleCompletionNotOnChooser() {
        // The child stays on /gsi/transform (blank). That is the white screen
        // the user still sees after Google says sign-in succeeded.
        XCTAssertTrue(PopupPolicy.shouldDismissPopup(
            url("https://accounts.google.com/gsi/transform")))
        XCTAssertTrue(PopupPolicy.shouldDismissPopup(
            url("https://accounts.google.com/gsi/issue")))
        XCTAssertTrue(PopupPolicy.shouldDismissPopup(
            url("https://accounts.google.com/o/oauth2/approval")))
        XCTAssertTrue(PopupPolicy.shouldDismissPopup(
            url("https://x.com/home")))
        XCTAssertFalse(PopupPolicy.shouldDismissPopup(
            url("https://accounts.google.com/gsi/select?client_id=abc")))
        XCTAssertFalse(PopupPolicy.shouldDismissPopup(
            url("https://accounts.google.com/o/oauth2/v2/auth?client_id=abc")))
        XCTAssertFalse(PopupPolicy.shouldDismissPopup(
            url("https://x.com/i/flow/login")))
        XCTAssertFalse(PopupPolicy.shouldDismissPopup(
            url("https://x.com/i/flow/single_sign_on")))
        XCTAssertFalse(PopupPolicy.shouldDismissPopup(url("about:blank")))
        XCTAssertFalse(PopupPolicy.shouldDismissPopup(nil))
    }

    func testLoadHomeAfterGoogleEvenIfParentStillOnLogin() {
        // After GSI, the parent is still /i/flow/login. iOS 17.5+ often
        // nulled window.opener, so X never left that page. Staying there
        // is the other white-screen path.
        XCTAssertTrue(PopupPolicy.shouldLoadXHome(
            afterClosingPopup: url("https://x.com/i/flow/login"),
            googleAuthJustFinished: true))
        XCTAssertTrue(PopupPolicy.shouldLoadXHome(
            afterClosingPopup: url("https://x.com/"),
            googleAuthJustFinished: true))
        XCTAssertTrue(PopupPolicy.shouldLoadXHome(
            afterClosingPopup: nil,
            googleAuthJustFinished: true))
        XCTAssertFalse(PopupPolicy.shouldLoadXHome(
            afterClosingPopup: url("https://x.com/home"),
            googleAuthJustFinished: true),
                       "do not reload Home if X already took the user there")
        XCTAssertFalse(PopupPolicy.shouldLoadXHome(
            afterClosingPopup: url("https://x.com/i/flow/login"),
            googleAuthJustFinished: false))
    }

    func testDoNotRestoreGoogleOrBlankXRoot() {
        XCTAssertFalse(PopupPolicy.shouldRestoreSavedURL(
            url("https://accounts.google.com/gsi/transform"), serviceID: "x"))
        XCTAssertFalse(PopupPolicy.shouldRestoreSavedURL(
            url("https://x.com/"), serviceID: "x"))
        XCTAssertFalse(PopupPolicy.shouldRestoreSavedURL(
            url("https://accounts.google.com/o/oauth2/approval"), serviceID: "x"))
        XCTAssertTrue(PopupPolicy.shouldRestoreSavedURL(
            url("https://x.com/home"), serviceID: "x"))
        XCTAssertTrue(PopupPolicy.shouldRestoreSavedURL(
            url("https://www.instagram.com/"), serviceID: "instagram"))
    }

    func testParseOpenerBridgeMessage() {
        let body: [String: Any] = [
            "type": "postMessage",
            "origin": "https://accounts.google.com",
            "data": ["credential": "abc.def", "select_by": "btn"],
        ]
        let parsed = PopupPolicy.parseOpenerBridgeMessage(body)
        XCTAssertEqual(parsed?.isClose, false)
        XCTAssertEqual(parsed?.origin, "https://accounts.google.com")
        XCTAssertEqual(parsed?.dataJSON, "{\"credential\":\"abc.def\",\"select_by\":\"btn\"}")

        let close = PopupPolicy.parseOpenerBridgeMessage(["type": "close", "origin": "https://accounts.google.com"])
        XCTAssertEqual(close?.isClose, true)

        XCTAssertNil(PopupPolicy.parseOpenerBridgeMessage("nope"))
    }

    func testParentMessageEventScriptUsesGoogleOrigin() {
        let script = PopupPolicy.parentMessageEventScript(
            dataJSON: "{\"credential\":\"tok\"}",
            origin: "https://accounts.google.com")
        XCTAssertTrue(script.contains("https://accounts.google.com"))
        XCTAssertTrue(script.contains("{\"credential\":\"tok\"}"))
        XCTAssertTrue(script.contains("MessageEvent"))
    }

    func testOpenerShimOnlyRunsOnGoogleOrBlank() {
        XCTAssertTrue(PopupPolicy.openerShimJavaScript.contains("noscrollOpener"))
        XCTAssertTrue(PopupPolicy.openerShimJavaScript.contains("accounts.google.com"))
        XCTAssertTrue(PopupPolicy.openerShimJavaScript.contains("about:blank"))
        XCTAssertTrue(PopupPolicy.openerShimJavaScript.contains("postMessage"))
    }

    func testXSafariSchemeRewritesToHTTPS() {
        let rewritten = PopupPolicy.httpsEquivalent(url("x-safari-https://x.com/home"))
        XCTAssertEqual(rewritten?.scheme, "https")
        XCTAssertEqual(rewritten?.host, "x.com")
        XCTAssertEqual(rewritten?.path, "/home")
    }

    func testTwitterAppSchemeStaysInTheWrapper() {
        XCTAssertEqual(PopupPolicy.httpsEquivalent(url("twitter://timeline")), PopupPolicy.xHomeURL)
        XCTAssertEqual(PopupPolicy.httpsEquivalent(url("x://home")), PopupPolicy.xHomeURL)
        XCTAssertNil(PopupPolicy.httpsEquivalent(url("https://x.com/home")))
    }

    func testInPageSchemesAreUnchanged() {
        XCTAssertTrue(PopupPolicy.isInPageScheme("https"))
        XCTAssertTrue(PopupPolicy.isInPageScheme("about"))
        XCTAssertFalse(PopupPolicy.isInPageScheme("twitter"))
        XCTAssertFalse(PopupPolicy.isInPageScheme("x-safari-https"))
    }

    func testAuthPathsIncludeXLoginButNotTheVideoFeed() {
        XCTAssertTrue(PopupPolicy.isAuthPath("/login"))
        XCTAssertTrue(PopupPolicy.isAuthPath("/i/flow/login"))
        XCTAssertTrue(PopupPolicy.isAuthPath("/i/jf/onboarding"))
        XCTAssertTrue(PopupPolicy.isAuthPath("/account/access"))
        XCTAssertFalse(PopupPolicy.isAuthPath("/home"))
        XCTAssertFalse(PopupPolicy.isAuthPath("/i/videos"),
                       "the video-feed block must not be treated as an SSO popup")
    }
}
