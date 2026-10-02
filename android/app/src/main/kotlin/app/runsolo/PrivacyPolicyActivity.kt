package app.runsolo

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle

/**
 * Health Connect asks every app for a privacy-policy screen: it opens this from its permission
 * screen. We have no screen of our own for it, so it opens the policy page and closes.
 */
class PrivacyPolicyActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        try {
            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(PRIVACY_URL)))
        } catch (_: Exception) {
        }
        finish()
    }

    companion object {
        const val PRIVACY_URL = "https://runsolo.app/privacy"
    }
}
