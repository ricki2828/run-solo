package app.runsolo.core.json

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull

class JsonTest {
    @Test
    fun `round trips nested values`() {
        val v = linkedMapOf(
            "a" to 1L, "b" to 2.5, "c" to "x\"y\n", "d" to null, "e" to true,
            "f" to listOf(1L, listOf(2L), mapOf("g" to null)),
        )
        val text = Json.write(v)
        assertEquals("""{"a":1,"b":2.5,"c":"x\"y\n","d":null,"e":true,"f":[1,[2],{"g":null}]}""", text)
        assertEquals(v, Json.parse(text))
    }

    @Test
    fun `integral doubles print without fraction and parse as long`() {
        assertEquals("[3,-0.5,1.0E20]", Json.write(listOf(3.0, -0.5, 1e20)))
        assertEquals(3L, (Json.parse("3")))
        assertEquals(3.0, Json.parse("3.0"))
        assertEquals(1e20, Json.parse("1e20"))
    }

    @Test
    fun `rejects garbage`() {
        assertFailsWith<Json.ParseException> { Json.parse("{\"a\":") }
        assertFailsWith<Json.ParseException> { Json.parse("[1,]") }
        assertFailsWith<Json.ParseException> { Json.parse("{} x") }
        assertFailsWith<Json.ParseException> { Json.parse("") }
        assertFailsWith<Json.ParseException> { Json.parseObject("[1]") }
    }

    @Test
    fun `unicode escapes and whitespace`() {
        val m = Json.parseObject(" { \"k\" : \"\\u0041\\t\" , \"n\" : -12 } ")
        assertEquals("A\t", m["k"])
        assertEquals(-12L, m.long("n"))
        assertNull(m.longOrNull("zz"))
    }

    @Test
    fun `non-finite doubles are refused`() {
        assertFailsWith<IllegalArgumentException> { Json.write(Double.NaN) }
    }
}
