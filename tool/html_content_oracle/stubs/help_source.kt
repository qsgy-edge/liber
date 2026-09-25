// The frozen `io.legado.app.help.source.getShareScope`, for the compile
// classpath only.
//
// `BaseSourceExtensions.kt` reaches `SharedJsScope`, which is an Android object
// (splitties' `appCtx`, OkHttp, Room-backed cache) and cannot be compiled on a
// desktop JVM. `AnalyzeRule.evalJS` (`AnalyzeRule.kt:748`) asks the source for
// its shared top scope; the frozen `SharedJsScope.getScope` (`:36-38`) answers
// null for a source whose `jsLib` is null or blank, and every case in this
// corpus declares none, so this stub transcribes that guard and nothing else.
package io.legado.app.help.source

import io.legado.app.data.entities.BaseSource
import org.mozilla.javascript.Scriptable
import kotlin.coroutines.CoroutineContext

/** `SharedJsScope.kt:36-38`, transcribed: a source with no `jsLib` has no
 * shared scope. A source that declares one is refused by name rather than
 * answered by an unfinished stub. */
fun BaseSource.getShareScope(coroutineContext: CoroutineContext? = null): Scriptable? {
    if (jsLib.isNullOrBlank()) {
        return null
    }
    error("this corpus declares no jsLib; the shared scope is not compiled here")
}
