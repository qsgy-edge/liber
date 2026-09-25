// The frozen `io.legado.app.help` members `AnalyzeRule.kt` names, for the
// compile classpath only.
//
// `JsExtensions.kt` imports Android's `WebSettings`, hutool, the app's WebView
// and cookie helpers and the association UI, so it cannot be compiled on a
// desktop JVM. `AnalyzeRule.kt` implements exactly two of its members — the
// `getSource()`/`ajax(url)` pair (`AnalyzeRule.kt:784,791`) — and calls no
// other, so the interface is declared here with those two and nothing else.
//
// `CacheManager` is named once, as a script binding (`AnalyzeRule.kt:739`
// `bindings["cache"] = CacheManager`); the frozen object stores through Room, so
// this stub is an empty object. It is never reached by a corpus case.
//
// `getSource()` is abstract here although the frozen declares it abstract too
// (`JsExtensions.kt:83`); `AnalyzeRule` overrides it. `ajax` keeps the frozen
// default shape but refuses by name, because fetching is not part of this
// corpus.
package io.legado.app.help

import io.legado.app.data.entities.BaseSource

/** The frozen `JsExtensions` (`JsExtensions.kt`), reduced to the three members
 * `AnalyzeRule` implements or names: `getSource()`, `ajax(url)` and `log(msg)`
 * (`:943-950`). */
interface JsExtensions {
    fun getSource(): BaseSource?

    /** The frozen `ajax` (`JsExtensions.kt:91-110`) fetches through `AnalyzeUrl`;
     * the stub refuses by name, because no corpus case calls it. */
    fun ajax(url: Any): String? = error("java.ajax is not reachable from this corpus")

    /** The frozen `log` (`JsExtensions.kt:943-950`) answers its own argument; the
     * rest of its body writes the debug log, which is an Android surface. It is
     * reached once, from `setRedirectUrl`'s catch for a malformed address. */
    fun log(msg: Any?): Any? = msg
}

/** The frozen `CacheManager` (`CacheManager.kt`), a script binding only. */
object CacheManager
