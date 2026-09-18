// The frozen reSegment harness: compiles against the frozen Legado revision's
// `ContentHelp.kt` and runs it over `fixtures.json`, writing `golden.json`.
//
// `ContentHelp.reSegment` is pure JVM code (no Android types), so this harness
// runs on a desktop JVM without a device. It is NOT the four-stage device
// oracle (that entry is #38's); it is the source-executed differential for this
// one transform. See README.md for the exact compile/run command and the
// provenance of the committed golden.
//
// Every case with `reSegment = true` is run twice and the harness refuses the
// output if the two runs differ, so a committed golden never contains
// `forceSplit`'s `Math.random()` result.
package tool.resegment

import com.google.gson.GsonBuilder
import io.legado.app.help.book.ContentHelp
import java.io.File

data class Case(
    val name: String,
    val chapterTitle: String,
    val content: String,
    val reSegment: Boolean,
    val note: String = "",
)

data class Fixtures(
    val baseline: String = "",
    val frozenSource: String = "",
    val frozenSourceSha1: String = "",
    val note: String = "",
    val cases: List<Case> = emptyList(),
)

fun main(args: Array<String>) {
    require(args.size == 2) { "usage: ReSegmentOracleKt <fixtures.json> <golden.json>" }
    val gson = GsonBuilder().setPrettyPrinting().disableHtmlEscaping().create()
    val fixtures = gson.fromJson(File(args[0]).readText(Charsets.UTF_8), Fixtures::class.java)
    val golden = LinkedHashMap<String, String>()
    for (case in fixtures.cases) {
        if (!case.reSegment) {
            // The frozen reader's stage output with the per-book flag off: the
            // body it was handed, because ContentHelp.reSegment is never called.
            golden[case.name] = case.content
            continue
        }
        val first = ContentHelp.reSegment(case.content, case.chapterTitle)
        val second = ContentHelp.reSegment(case.content, case.chapterTitle)
        check(first == second) { "case ${case.name} depends on Math.random(); remove it from the corpus" }
        golden[case.name] = first
    }
    File(args[1]).writeText(gson.toJson(golden), Charsets.UTF_8)
    println("wrote ${golden.size} rows from ${fixtures.baseline} (${fixtures.frozenSourceSha1})")
}
