// The frozen `io.legado.app.model.analyzeRule.AnalyzeUrl`, for the replace
// step's compile classpath.
//
// `AnalyzeUrl.kt` cannot be compiled on a desktop JVM: it imports Glide,
// androidx.media3, hutool's codecs, Rhino's script engine, OkHttp, Room's
// `appDb` and the app's own help classes. The replace step reaches two of its
// members:
//
// - `analyzeRule.ajax` builds one (`AnalyzeRule.kt:797-801`); that member is the
//   `java.ajax` bridge a script calls and no corpus case calls it, so the
//   constructor carries the frozen parameter names and `getStrResponse` refuses
//   by name;
// - `HtmlFormatter.formatKeepImg` reads its companion's `paramPattern`
//   (`AnalyzeUrl.kt:658`) for an image whose `src` carries a `{...}` template,
//   the transcription `FrozenAnalyzeUrlStub.kt` holds for #101's content step.
//
// The two steps cannot share one declaration: #101's file compiles an `object`
// that answers `paramPattern` alone, and `AnalyzeRule` needs the class form, so
// this file is the richer sibling the replace step compiles *instead of* it.
// `ContentReplaceOracle` fails the run unless `AnalyzeUrl.kt` still contains the
// transcribed expression, exactly as #101's harness does.
package io.legado.app.model.analyzeRule

import io.legado.app.data.entities.BaseSource
import io.legado.app.data.entities.BookChapter
import io.legado.app.help.http.StrResponse
import java.util.regex.Pattern
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.EmptyCoroutineContext

/** The frozen `AnalyzeUrl` (`AnalyzeUrl.kt:75-...`), reduced to the two members
 * the replace step names. */
class AnalyzeUrl(
    val mUrl: String,
    private val source: BaseSource? = null,
    private val ruleData: RuleDataInterface? = null,
    private val chapter: BookChapter? = null,
    private var coroutineContext: CoroutineContext = EmptyCoroutineContext,
) {
    /** `AnalyzeUrl.kt:465`, reached only by a script's `java.ajax` call. */
    fun getStrResponse(
        jsStr: String? = null,
        sourceRegex: String? = null,
        useWebView: Boolean = true,
    ): StrResponse = error("java.ajax is not reachable from this corpus")

    companion object {

        /** `AnalyzeUrl.kt:658`, transcribed. */
        val paramPattern: Pattern = Pattern.compile("\\s*,\\s*(?=\\{)")
    }
}
