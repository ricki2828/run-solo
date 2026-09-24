package app.runsolo.core.json

/**
 * Minimal JSON codec so core-jvm has no third-party dependencies (nothing to audit for
 * `INTERNET`, nothing to keep 16 KB-aligned). Values map to: `Map<String, Any?>`, `List<Any?>`,
 * `String`, `Long`, `Double`, `Boolean`, `null`. Integers that fit a Long parse as Long; anything
 * with a fraction or exponent parses as Double. Writers accept Int/Float too.
 */
object Json {
    class ParseException(message: String, val offset: Int) : RuntimeException("$message at offset $offset")

    fun parse(text: String): Any? {
        val p = Parser(text)
        val v = p.value()
        p.skipWs()
        if (!p.atEnd()) throw ParseException("Trailing characters", p.pos)
        return v
    }

    @Suppress("UNCHECKED_CAST")
    fun parseObject(text: String): Map<String, Any?> =
        parse(text) as? Map<String, Any?> ?: throw ParseException("Expected object", 0)

    fun write(value: Any?): String = StringBuilder().also { write(value, it) }.toString()

    fun write(value: Any?, out: StringBuilder) {
        when (value) {
            null -> out.append("null")
            is String -> writeString(value, out)
            is Boolean -> out.append(value)
            is Int, is Long, is Short, is Byte -> out.append(value)
            is Double -> writeDouble(value, out)
            is Float -> writeDouble(value.toDouble(), out)
            is Map<*, *> -> {
                out.append('{')
                var first = true
                for ((k, v) in value) {
                    if (!first) out.append(',')
                    first = false
                    writeString(k.toString(), out)
                    out.append(':')
                    write(v, out)
                }
                out.append('}')
            }
            is Iterable<*> -> {
                out.append('[')
                var first = true
                for (v in value) {
                    if (!first) out.append(',')
                    first = false
                    write(v, out)
                }
                out.append(']')
            }
            is Array<*> -> write(value.asList(), out)
            is DoubleArray -> write(value.asList(), out)
            is LongArray -> write(value.asList(), out)
            is IntArray -> write(value.asList(), out)
            is Enum<*> -> writeString(value.name, out)
            else -> throw IllegalArgumentException("Cannot encode ${value::class}")
        }
    }

    private fun writeDouble(d: Double, out: StringBuilder) {
        // NaN/Infinity are not JSON; a run file must never carry them.
        require(d.isFinite()) { "Non-finite double in JSON" }
        if (d == Math.rint(d) && Math.abs(d) < 1e15) {
            out.append(d.toLong())
        } else {
            out.append(d)
        }
    }

    private fun writeString(s: String, out: StringBuilder) {
        out.append('"')
        for (c in s) {
            when (c) {
                '"' -> out.append("\\\"")
                '\\' -> out.append("\\\\")
                '\n' -> out.append("\\n")
                '\r' -> out.append("\\r")
                '\t' -> out.append("\\t")
                '\b' -> out.append("\\b")
                '\u000C' -> out.append("\\f")
                else -> if (c < ' ') out.append(String.format("\\u%04x", c.code)) else out.append(c)
            }
        }
        out.append('"')
    }

    private class Parser(val s: String) {
        var pos = 0

        fun atEnd() = pos >= s.length

        fun skipWs() {
            while (pos < s.length && s[pos].isWhitespace()) pos++
        }

        fun value(): Any? {
            skipWs()
            if (atEnd()) throw ParseException("Unexpected end", pos)
            return when (val c = s[pos]) {
                '{' -> obj()
                '[' -> arr()
                '"' -> str()
                't' -> literal("true", true)
                'f' -> literal("false", false)
                'n' -> literal("null", null)
                else -> if (c == '-' || c.isDigit()) number() else throw ParseException("Unexpected '$c'", pos)
            }
        }

        private fun literal(word: String, v: Any?): Any? {
            if (!s.startsWith(word, pos)) throw ParseException("Bad literal", pos)
            pos += word.length
            return v
        }

        private fun obj(): Map<String, Any?> {
            val m = LinkedHashMap<String, Any?>()
            pos++
            skipWs()
            if (peek() == '}') { pos++; return m }
            while (true) {
                skipWs()
                if (peek() != '"') throw ParseException("Expected key", pos)
                val k = str()
                skipWs()
                if (peek() != ':') throw ParseException("Expected ':'", pos)
                pos++
                m[k] = value()
                skipWs()
                when (peek()) {
                    ',' -> pos++
                    '}' -> { pos++; return m }
                    else -> throw ParseException("Expected ',' or '}'", pos)
                }
            }
        }

        private fun arr(): List<Any?> {
            val l = ArrayList<Any?>()
            pos++
            skipWs()
            if (peek() == ']') { pos++; return l }
            while (true) {
                l.add(value())
                skipWs()
                when (peek()) {
                    ',' -> pos++
                    ']' -> { pos++; return l }
                    else -> throw ParseException("Expected ',' or ']'", pos)
                }
            }
        }

        private fun peek(): Char = if (atEnd()) throw ParseException("Unexpected end", pos) else s[pos]

        private fun str(): String {
            pos++ // opening quote
            val sb = StringBuilder()
            while (true) {
                if (atEnd()) throw ParseException("Unterminated string", pos)
                val c = s[pos++]
                when (c) {
                    '"' -> return sb.toString()
                    '\\' -> {
                        if (atEnd()) throw ParseException("Unterminated escape", pos)
                        when (val e = s[pos++]) {
                            '"' -> sb.append('"')
                            '\\' -> sb.append('\\')
                            '/' -> sb.append('/')
                            'n' -> sb.append('\n')
                            'r' -> sb.append('\r')
                            't' -> sb.append('\t')
                            'b' -> sb.append('\b')
                            'f' -> sb.append('\u000C')
                            'u' -> {
                                if (pos + 4 > s.length) throw ParseException("Bad \\u escape", pos)
                                sb.append(s.substring(pos, pos + 4).toInt(16).toChar())
                                pos += 4
                            }
                            else -> throw ParseException("Bad escape '\\$e'", pos)
                        }
                    }
                    else -> sb.append(c)
                }
            }
        }

        private fun number(): Any {
            val start = pos
            if (s[pos] == '-') pos++
            var isDouble = false
            while (pos < s.length) {
                val c = s[pos]
                if (c.isDigit()) pos++
                else if (c == '.' || c == 'e' || c == 'E' || c == '+' || c == '-') { isDouble = true; pos++ }
                else break
            }
            val text = s.substring(start, pos)
            return try {
                if (isDouble) text.toDouble() else text.toLong()
            } catch (e: NumberFormatException) {
                throw ParseException("Bad number '$text'", start)
            }
        }
    }
}

// Typed accessors for decoded JSON. They throw on the wrong type so a corrupt line is
// rejected as a whole rather than half-read.
fun Map<String, Any?>.long(key: String): Long = num(key).toLong()
fun Map<String, Any?>.longOrNull(key: String): Long? = numOrNull(key)?.toLong()
fun Map<String, Any?>.int(key: String): Int = num(key).toInt()
fun Map<String, Any?>.double(key: String): Double = num(key).toDouble()
fun Map<String, Any?>.doubleOrNull(key: String): Double? = numOrNull(key)?.toDouble()
fun Map<String, Any?>.string(key: String): String = this[key] as? String ?: throw Json.ParseException("Missing string '$key'", 0)
fun Map<String, Any?>.stringOrNull(key: String): String? = this[key] as? String
@Suppress("UNCHECKED_CAST")
fun Map<String, Any?>.obj(key: String): Map<String, Any?>? = this[key] as? Map<String, Any?>
fun Map<String, Any?>.list(key: String): List<Any?> = this[key] as? List<Any?> ?: emptyList()
private fun Map<String, Any?>.num(key: String): Number = this[key] as? Number ?: throw Json.ParseException("Missing number '$key'", 0)
private fun Map<String, Any?>.numOrNull(key: String): Number? = this[key] as? Number
