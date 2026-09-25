package app.runsolo.record

import android.content.Context
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/**
 * Android 14 (PR #9): volume keys never reach an app's remote session, so no session is
 * registered there and "unavailable" is reported once; every other API registers the session.
 */
@RunWith(RobolectricTestRunner::class)
class LapInputTest {
    private val context: Context = RuntimeEnvironment.getApplication()
    private var laps = 0
    private var unavailable = 0

    private fun input() = LapInput(context, onLap = { laps++ }, onUnavailable = { unavailable++ })

    @Test
    @Config(sdk = [34])
    fun `API 34 - no session, unavailable reported once per run`() {
        val li = input()
        li.enable()
        assertFalse(li.registered)
        assertEquals(1, unavailable)
        li.disable()
        li.enable() // sensors re-attached within the same run
        assertEquals(1, unavailable)
        assertEquals(0, laps)
    }

    @Test
    @Config(sdk = [29])
    fun `API 29 - session registered, nothing reported`() {
        val li = input()
        li.enable()
        assertTrue(li.registered)
        assertEquals(0, unavailable)
        li.disable()
        assertFalse(li.registered)
    }

    @Test
    @Config(sdk = [35]) // highest SDK Robolectric 4.14 ships; the gate is `!= 34`, so 35 behaves like 36
    fun `API 35 - session registered, nothing reported`() {
        val li = input()
        li.enable()
        assertTrue(li.registered)
        assertEquals(0, unavailable)
        li.disable()
    }
}
