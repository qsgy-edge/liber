// The frozen `io.legado.app.help.http.CookieStore`, for the compile classpath
// only.
//
// `CookieStore.kt` stores through Room (`appDb.cookieDao`) and OkHttp's cookie
// jar, so it cannot be compiled on a desktop JVM. `AnalyzeRule.kt` names it once,
// as a script binding (`AnalyzeRule.kt:738` `bindings["cookie"] = CookieStore`),
// and no corpus case calls a member of it.
package io.legado.app.help.http

/** The frozen `CookieStore` (`CookieStore.kt`), a script binding only. */
object CookieStore
