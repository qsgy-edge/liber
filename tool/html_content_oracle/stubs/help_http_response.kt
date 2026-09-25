// The frozen `io.legado.app.help.http.StrResponse`, for the compile classpath
// only.
//
// `StrResponse.kt` is an OkHttp-backed response wrapper (it owns the request,
// the body bytes, the charset decode and the cookie jar), so it cannot be
// compiled on a desktop JVM. `AnalyzeRule.ajax` reads its `body`
// (`AnalyzeRule.kt:804`) and nothing else; no corpus case reaches that call.
package io.legado.app.help.http

/** The frozen `StrResponse` (`StrResponse.kt`), reduced to the member the
 * `java.ajax` call site reads. */
class StrResponse(val body: String? = null)
