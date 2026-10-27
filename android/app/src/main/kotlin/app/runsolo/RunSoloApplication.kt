package app.runsolo

import android.app.Application

/**
 * Installs the native crash handler as early as the process exists, so a crash in a
 * service-only process (notification action after process death) is logged too.
 */
class RunSoloApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        DiagnosticsFiles.installCrashHandler(this, BuildConfig.VERSION_NAME)
    }
}
