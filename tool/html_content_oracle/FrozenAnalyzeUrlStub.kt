// `AnalyzeUrl.paramPattern`, supplied for the compile classpath because
// `AnalyzeUrl.kt` cannot be compiled on a desktop JVM: it imports Glide,
// androidx.media3, hutool's codecs, Rhino's script engine, OkHttp, Room's
// `appDb` and the app's own help classes.
//
// `HtmlFormatter.formatKeepImg` needs exactly one member of that file — the
// `paramPattern` of its companion object (`AnalyzeUrl.kt:658`) — and only for an
// image whose `src` carries a `{...}` template. The expression is transcribed
// here and `HtmlContentOracle` fails the run unless `AnalyzeUrl.kt` still
// contains it.
package io.legado.app.model.analyzeRule

import java.util.regex.Pattern

object AnalyzeUrl {

    /** `AnalyzeUrl.kt:658`, transcribed. */
    val paramPattern: Pattern = Pattern.compile("\\s*,\\s*(?=\\{)")
}
