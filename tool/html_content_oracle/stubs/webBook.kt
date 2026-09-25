// The frozen `io.legado.app.model.webBook.WebBook`, for the compile classpath
// only.
//
// `WebBook.kt` is the whole fetch pipeline (AnalyzeUrl, Room, the WebView
// bridge), so it cannot be compiled on a desktop JVM. `AnalyzeRule.kt` names two
// of its members, both inside `reGetBook` (`:820-841`), which only a script that
// calls `java.reGetBook()` reaches; no corpus case does. Both stubs refuse by
// name rather than answering a fabricated book.
package io.legado.app.model.webBook

import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookSource

/** The frozen `WebBook` (`WebBook.kt`), reduced to the members `AnalyzeRule`
 * names. */
object WebBook {
    suspend fun getBookInfoAwait(
        bookSource: BookSource,
        book: Book,
        canReName: Boolean = true,
    ): Book = error("java.getBookInfo is not reachable from this corpus")

    suspend fun preciseSearchAwait(
        bookSource: BookSource,
        name: String,
        author: String,
    ): Result<Book> = Result.failure(
        UnsupportedOperationException("java.preciseSearch is not reachable from this corpus")
    )
}
