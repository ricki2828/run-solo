package app.runsolo.core

import kotlin.test.Test
import kotlin.test.assertEquals

class CoreVersionTest {
    @Test
    fun `version is set`() {
        assertEquals("0.1.0", CoreVersion.VERSION)
    }
}
