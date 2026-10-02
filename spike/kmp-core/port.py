#!/usr/bin/env python3
"""K0 spike: copy android/core-jvm into KMP source sets with mechanical rewrites.

core-jvm on main is never edited by the spike. Every rewrite below is one item K1 would make
by hand in the real module, so the rule list plus the per-rule hit counts in
build/ported/port-report.txt are the K1 change list.

Output (gitignored):
  build/ported/commonMain  core-jvm main minus JVM-only files
  build/ported/jvmMain     JvmFileSystem (java.nio stays JVM-only)
  build/ported/commonTest  core-jvm tests minus JVM-only ones
"""
import pathlib
import re
import shutil
import sys

HERE = pathlib.Path(__file__).resolve().parent
CORE = HERE.parent.parent / "android" / "core-jvm" / "src"
OUT = HERE / "build" / "ported"

# Files that stay on the JVM side (java.nio file system; the fixture writer only runs on the host).
JVM_MAIN = {"app/runsolo/core/fs/JvmFileSystem.kt"}
SKIP_TEST = {"app/runsolo/core/contract/RegenerateFixtures.kt"}

P = "app.runsolo.core.platform"
# Helpers the rewrites call unqualified; port.py adds the import where used (a qualified
# `app.runsolo...` breaks inside classes with a property named `app`, e.g. RunFile).
HELPERS = ["toRadians", "formatDouble", "fixed2", "isoInstant", "parseIsoInstant", "gzip", "gunzip",
           "IOException", "FileNotFoundException", "currentTimeMillis"]

# (name, file glob or None for all, pattern, replacement). Literal unless the pattern starts with "re:".
RULES = [
    # java.lang.Math is not in common Kotlin. toRadians keeps JDK 17's constant multiply.
    ("Math.toRadians", None, "Math.toRadians(", f"toRadians("),
    ("Math.rint/abs (Json)", "Json.kt", "Math.rint(d) && Math.abs(d)", "kotlin.math.round(d) && kotlin.math.abs(d)"),
    # StringBuilder.append(Double) is Double.toString: platform-defined on Native.
    ("Json double append", "Json.kt", "            out.append(d)\n", "            out.append(formatDouble(d))\n"),
    ("String.format \\u%04x", "Json.kt", 'String.format("\\\\u%04x", c.code)', '"\\\\u" + c.code.toString(16).padStart(4, \'0\')'),
    ("String.format %d:%02d", "CueWords.kt",
     'String.format(Locale.US, "%d:%02d:%02d", h, m, sec) else String.format(Locale.US, "%d:%02d", m, sec)',
     '"$h:${m.toString().padStart(2, \'0\')}:${sec.toString().padStart(2, \'0\')}" else "$m:${sec.toString().padStart(2, \'0\')}"'),
    ("String.format %.2f", None, "re:String\\.format\\((?:java\\.util\\.)?Locale\\.US, \"%\\.2f\", ", f"fixed2("),
    ("import java.util.Locale", None, "import java.util.Locale\n", ""),
    ("@Volatile", None, "@Volatile", "@kotlin.concurrent.Volatile"),
    # Charsets / String(bytes) are JVM-only; UTF-8 is the only charset used.
    (".toByteArray(Charsets.UTF_8)", None, ".toByteArray(Charsets.UTF_8)", ".encodeToByteArray()"),
    (".toString(Charsets.UTF_8)", None, ".toString(Charsets.UTF_8)", ".decodeToString()"),
    ("String.toByteArray()", None, "re:(?<![A-Za-z])(\\)|\"|text|cut|newer|unknownMode|v1|v2|bytes)\\.toByteArray\\(\\)", "\\1.encodeToByteArray()"),
    ("String(bytes)", None, "StringBuilder(String(journal()))", "StringBuilder(journal().decodeToString())"),
    ("Map.putIfAbsent", None, "re:(?m)\\.putIfAbsent\\((\\w+), (.*)\\)$", ".getOrPut(\\1) { \\2 }"),
    ("System.currentTimeMillis", None, "System::currentTimeMillis", "::currentTimeMillis"),
    # RunFile: java.time.Instant + java.util.zip.
    ("Instant.toString", None, "re:(?:java\\.time\\.)?Instant\\.ofEpochMilli\\(([^()]*(?:\\([^()]*\\))?[^()]*)\\)\\.toString\\(\\)", f"isoInstant(\\1)"),
    ("Instant.parse", None, "re:java\\.time\\.Instant\\.parse\\((.*)\\)\\.toEpochMilli\\(\\)", f"parseIsoInstant(\\1)"),
    ("GZIPOutputStream", "RunFile.kt",
     "        val out = ByteArrayOutputStream()\n        GZIPOutputStream(out).use { it.write(Json.write(toJson()).encodeToByteArray()) }\n        return out.toByteArray()\n",
     f"        return gzip(Json.write(toJson()).encodeToByteArray())\n"),
    ("GZIPInputStream", "RunFile.kt", "GZIPInputStream(gz.inputStream()).readBytes().decodeToString()", f"gunzip(gz).decodeToString()"),
    ("java.io/time/zip imports", "RunFile.kt", "re:import java\\.(io\\.ByteArrayOutputStream|time\\.Instant|util\\.zip\\.GZIP(In|Out)putStream)\n", ""),
    # Tests: fixture files through a small common File (expect/actual) instead of java.io.File.
    ("import java.io.File", None, "import java.io.File\n", "import app.runsolo.core.testio.File\n"),
    ("java.io.File(", None, "java.io.File(", "app.runsolo.core.testio.File("),
    ("java.io exceptions", None, "re:java\\.io\\.(IOException|FileNotFoundException)", f"\\1"),
]


def apply(rel: str, text: str, counts: dict) -> str:
    name = rel.rsplit("/", 1)[-1]
    hit = False
    for rule, only, pat, rep in RULES:
        if only and only != name:
            continue
        if pat.startswith("re:"):
            text, n = re.subn(pat[3:], rep, text)
        else:
            n = text.count(pat)
            text = text.replace(pat, rep)
        if n:
            counts.setdefault(rule, []).append(f"{rel} x{n}")
            hit = True
    if hit:
        used = [h for h in HELPERS if re.search(rf"(?<![.\w]){h}\b", text)]
        if used:
            imports = "".join(f"import {P}.{h}\n" for h in used)
            text = re.sub(r"(?m)^(package [\w.]+\n)", lambda m: m.group(1) + "\n" + imports, text, count=1)
    return text


def main() -> int:
    if OUT.exists():
        shutil.rmtree(OUT)
    counts: dict = {}
    leftovers = []
    for src_set, dest in (("main", "commonMain"), ("test", "commonTest")):
        root = CORE / src_set / "kotlin"
        for f in sorted(root.rglob("*.kt")):
            rel = f.relative_to(root).as_posix()
            if src_set == "test" and rel in SKIP_TEST:
                continue
            target = "jvmMain" if rel in JVM_MAIN else dest
            text = f.read_text()
            if target != "jvmMain":
                text = apply(rel, text, counts)
                for m in re.finditer(r"\bjava\.\w+|String\.format|Charsets\.|\bMath\.", text):
                    line = text[: m.start()].count("\n") + 1
                    raw = text.splitlines()[line - 1]
                    if not raw.lstrip().startswith(("*", "//", "/*")):
                        leftovers.append(f"{src_set}/{rel}:{line}: {raw.strip()}")
            out = OUT / target / "kotlin" / rel
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_text(text)
    paths = OUT / "commonTest" / "kotlin" / "app" / "runsolo" / "core" / "testio" / "CoreJvmDir.kt"
    paths.parent.mkdir(parents=True, exist_ok=True)
    paths.write_text(f'package app.runsolo.core.testio\n\nconst val CORE_JVM_DIR = "{CORE.parent.as_posix()}"\n')
    report = ["# port.py rewrites (rule: files)"]
    for rule, _, _, _ in RULES:
        hits = counts.get(rule, [])
        report.append(f"{rule}: {sum(int(h.rsplit('x', 1)[1]) for h in hits)} hit(s) in {len(hits)} file(s)")
        report += [f"    {h}" for h in hits]
    report.append(f"# JVM-only leftovers in common code: {len(leftovers)}")
    report += leftovers
    (OUT / "port-report.txt").write_text("\n".join(report) + "\n")
    print("\n".join(report))
    return 1 if leftovers else 0


if __name__ == "__main__":
    sys.exit(main())
