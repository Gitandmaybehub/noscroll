package app.noscroll.web

import android.content.Context
import android.util.Log
import android.webkit.JavascriptInterface
import android.webkit.WebView
import android.webkit.WebViewClient
import app.noscroll.BuildConfig
import org.json.JSONObject

/**
 * Loads the shared JS engine and the rule bundle, and injects them at document
 * start.
 *
 * The engine bundle is byte-identical to the one iOS injects — that is the whole
 * point of the architecture. Everything platform-specific stays out here.
 *
 * Android has no `WKUserScript(injectionTime: .atDocumentStart)` equivalent, so
 * `onPageStarted` is the earliest reliable hook. It fires before the page's own
 * scripts run, which is what keeps the blocking CSS ahead of first paint.
 */
object EngineInjector {

    private const val ENGINE_ASSET = "noscroll.js"

    /**
     * [wrapped] is taken explicitly rather than read back off
     * `webView.webViewClient` — this is called again on every service switch
     * (see MainActivity.switchService), and reading it back would capture the
     * anonymous client this function itself installed on the previous call,
     * not the real [WrappedWebViewClient]. That would have silently turned
     * off network-layer media blocking and auth-path exclusion after the
     * first switch, since `existing as? WrappedWebViewClient` would then
     * always be null.
     */
    fun install(context: Context, webView: WebView, wrapped: WrappedWebViewClient, service: String) {
        val engine = context.assets.open(ENGINE_ASSET).bufferedReader().use { it.readText() }
        val bundle = loadBundle(context, service)

        val config = JSONObject().apply {
            put("bundle", JSONObject(bundle))
            put("settings", JSONObject())
            put("telemetry", BuildConfig.DEBUG)  // local logging only; there is no network sink
        }

        val bootstrap = """
            window.__NOSCROLL_CONFIG = $config;
            $engine
        """.trimIndent()

        webView.webViewClient = object : WebViewClient() {
            override fun onPageStarted(view: WebView?, url: String?, favicon: android.graphics.Bitmap?) {
                super.onPageStarted(view, url, favicon)
                view?.evaluateJavascript(bootstrap, null)
            }

            override fun shouldInterceptRequest(
                view: WebView?,
                request: android.webkit.WebResourceRequest?,
            ) = wrapped.shouldInterceptRequest(view, request)

            override fun shouldOverrideUrlLoading(
                view: WebView?,
                request: android.webkit.WebResourceRequest?,
            ) = wrapped.shouldOverrideUrlLoading(view, request)
        }
    }

    /**
     * Three-tier fallback, same as iOS: remote → cached → baked into assets, so
     * a cold first launch with no network still blocks Reels.
     */
    private fun loadBundle(context: Context, service: String): String {
        val cached = context.cacheDir.resolve("noscroll-rules/$service.json")
        if (cached.exists()) return cached.readText()
        return context.assets.open("rules/$service.json").bufferedReader().use { it.readText() }
    }

    /**
     * Receives engine messages. Carries rule ids and counts only — never a URL,
     * never page content. See docs/PRIVACY.md.
     */
    class Bridge {
        @JavascriptInterface
        fun postMessage(json: String) {
            runCatching {
                val msg = JSONObject(json)
                // Parity with the iOS shell's console logging: shows the engine
                // really is running inside this WebView, and what it removed.
                // Debug builds only — see docs/PRIVACY.md on what the bridge
                // is permitted to carry.
                if (BuildConfig.DEBUG) Log.d("NoScroll", json)
                when (msg.optString("type")) {
                    "probe" -> RuleHealth.report(
                        msg.optString("ruleId"),
                        msg.optInt("expected"),
                        msg.optInt("actual"),
                    )
                    else -> Unit
                }
            }
        }
    }
}

/** Local-only record of which rules stopped matching. */
object RuleHealth {
    private val stale = mutableSetOf<String>()

    fun report(ruleId: String, expected: Int, actual: Int) {
        if (expected > 0 && actual == 0) stale += ruleId
    }

    fun staleRules(): Set<String> = stale.toSet()
}
