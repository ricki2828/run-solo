package app.runsolo.garmin

import android.app.Activity
import android.content.Intent
import android.graphics.Typeface
import android.os.Bundle
import android.util.TypedValue
import android.view.ViewGroup
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

/** Minimal spike screen: status, Ping watch, Reconnect, Clear, Share log. Dogfood flavour only. */
class GarminSpikeActivity : Activity() {
    private lateinit var status: TextView
    private lateinit var logView: TextView
    private lateinit var scroll: ScrollView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            fitsSystemWindows = true
            setPadding(24, 24, 24, 24)
        }
        status = TextView(this).apply { setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f) }
        val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        fun button(label: String, onClick: () -> Unit) = Button(this).apply {
            text = label
            setOnClickListener { onClick() }
            row.addView(this, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        }
        button("Ping") { GarminSpike.pingWatch() }
        button("Reconnect") { GarminSpike.reconnect(this) }
        button("Clear") { GarminSpike.clear(); refresh() }
        button("Share") {
            val send = Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_SUBJECT, "Run Supreme Garmin spike log")
                putExtra(Intent.EXTRA_TEXT, GarminSpike.exportText())
            }
            startActivity(Intent.createChooser(send, "Share spike log"))
        }
        logView = TextView(this).apply {
            typeface = Typeface.MONOSPACE
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
            setTextIsSelectable(true)
        }
        scroll = ScrollView(this).apply { addView(logView) }
        root.addView(status)
        root.addView(row)
        root.addView(scroll, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        setContentView(root)
    }

    override fun onResume() {
        super.onResume()
        GarminSpike.foreground = true
        GarminSpike.onChange = { refresh() }
        GarminSpike.start(this)
        refresh()
    }

    override fun onPause() {
        // Keep the SDK registered: the spike measures delivery while this screen is in the background.
        GarminSpike.foreground = false
        GarminSpike.onChange = null
        super.onPause()
    }

    private fun refresh() {
        status.text = GarminSpike.status()
        logView.text = GarminSpike.text()
        scroll.post { scroll.fullScroll(ScrollView.FOCUS_DOWN) }
    }
}
