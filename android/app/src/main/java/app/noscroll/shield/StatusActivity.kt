package app.noscroll.shield

import android.app.Activity
import android.content.Intent
import android.graphics.Typeface
import android.os.Bundle
import android.provider.Settings
import android.view.Gravity
import android.view.ViewGroup
import android.widget.Button
import android.widget.CompoundButton
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Switch
import android.widget.TextView
import app.noscroll.R
import app.noscroll.web.RuleHealth

/**
 * The diagnostic screen this app did not have.
 *
 * "Blocking doesn't work" reports had no way to tell a user *why*: whether the
 * accessibility permission was never granted, or — the bug this screen was
 * built alongside — whether nothing was ever marked as shielded in the first
 * place (see the comment on [ShieldSettings.ensureDefaultsInitialized]).
 * Either way the previous behaviour was silence: the shield simply never
 * appeared, with no signal anywhere in the app that anything was wrong.
 *
 * This screen states the one fact that actually determines whether blocking
 * can run — is the accessibility service on — loudly, with a direct button
 * into the system settings screen that turns it on, plus the current shield
 * list so "nothing is blocked" and "I never actually turned anything on" are
 * distinguishable at a glance.
 */
class StatusActivity : Activity() {

    private lateinit var settings: ShieldSettings
    private lateinit var bannerText: TextView
    private lateinit var bannerDetail: TextView
    private lateinit var openSettingsButton: Button
    private lateinit var ruleWarning: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        settings = ShieldSettings(this)

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(48, 64, 48, 64)
        }

        root.addView(TextView(this).apply {
            text = getString(R.string.status_title)
            textSize = 22f
            setTypeface(typeface, Typeface.BOLD)
        })

        bannerText = TextView(this).apply {
            textSize = 17f
            setPadding(0, 32, 0, 8)
        }
        root.addView(bannerText)

        bannerDetail = TextView(this).apply {
            textSize = 14f
            setPadding(0, 0, 0, 24)
        }
        root.addView(bannerDetail)

        openSettingsButton = Button(this).apply {
            text = getString(R.string.status_open_settings)
            setOnClickListener {
                startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
            }
        }
        root.addView(openSettingsButton)

        root.addView(TextView(this).apply {
            text = getString(R.string.status_shielded_apps)
            textSize = 18f
            setTypeface(typeface, Typeface.BOLD)
            setPadding(0, 48, 0, 16)
        })

        root.addView(serviceRow("com.instagram.android", getString(R.string.status_service_instagram)))
        root.addView(serviceRow("com.google.android.youtube", getString(R.string.status_service_youtube)))

        ruleWarning = TextView(this).apply {
            textSize = 13f
            setPadding(0, 32, 0, 0)
            visibility = android.view.View.GONE
        }
        root.addView(ruleWarning)

        setContentView(ScrollView(this).apply { addView(root) })
    }

    override fun onResume() {
        super.onResume()
        // Accessibility permission is granted in a separate system screen, so
        // it must be re-checked every time this screen becomes visible again
        // rather than once in onCreate.
        refresh()
    }

    private fun refresh() {
        val enabled = AccessibilityStatus.isForegroundMonitorEnabled(this)
        if (enabled) {
            bannerText.text = getString(R.string.status_enabled)
            bannerText.setTextColor(0xFF1B8A3F.toInt())
            bannerDetail.text = ""
            openSettingsButton.visibility = android.view.View.GONE
        } else {
            bannerText.text = getString(R.string.status_disabled)
            bannerText.setTextColor(0xFFB3261E.toInt())
            bannerDetail.text = getString(R.string.status_disabled_detail)
            openSettingsButton.visibility = android.view.View.VISIBLE
        }

        val stale = RuleHealth.staleRules()
        if (stale.isEmpty()) {
            ruleWarning.visibility = android.view.View.GONE
        } else {
            ruleWarning.visibility = android.view.View.VISIBLE
            ruleWarning.text = getString(R.string.status_rule_warning, stale.joinToString(", "))
        }
    }

    private fun serviceRow(pkg: String, label: String): LinearLayout {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, 12, 0, 12)
        }
        row.addView(
            TextView(this).apply { text = label; textSize = 16f },
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f),
        )
        row.addView(Switch(this).apply {
            isChecked = settings.isShielded(pkg)
            setOnCheckedChangeListener { _: CompoundButton, checked: Boolean ->
                val current = settings.shieldedPackages().toMutableSet()
                if (checked) current += pkg else current -= pkg
                settings.setShielded(current)
            }
        })
        return row
    }
}
