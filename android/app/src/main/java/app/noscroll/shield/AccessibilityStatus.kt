package app.noscroll.shield

import android.content.ComponentName
import android.content.Context
import android.provider.Settings
import android.text.TextUtils

/**
 * Whether [ForegroundAppMonitor] is actually turned on in Android's own
 * Accessibility settings.
 *
 * There is no callback for this — Android does not notify an app when the
 * user grants or revokes an accessibility service, and `onServiceConnected`
 * only fires once the service *is* running, which tells you nothing about
 * the far more common case of it never being enabled at all. Polling
 * `Settings.Secure` on demand (screen resume, or when the user opens the
 * status screen) is the only reliable way to answer "is blocking actually
 * live right now" instead of assuming it from pairing having happened once.
 */
object AccessibilityStatus {

    fun isForegroundMonitorEnabled(context: Context): Boolean {
        val globalOn = Settings.Secure.getInt(
            context.contentResolver,
            Settings.Secure.ACCESSIBILITY_ENABLED,
            0,
        ) == 1
        if (!globalOn) return false

        val expected = ComponentName(context, ForegroundAppMonitor::class.java)
        val raw = Settings.Secure.getString(
            context.contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
        ) ?: return false

        val splitter = TextUtils.SimpleStringSplitter(':').apply { setString(raw) }
        for (entry in splitter) {
            if (ComponentName.unflattenFromString(entry) == expected) return true
        }
        return false
    }
}
