package io.legado.app.ticket13

import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Base64
import android.webkit.WebView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.webkit.WebViewCompat
import io.legado.app.data.appDb
import io.legado.app.data.entities.BookSource
import io.legado.app.help.JsExtensions
import io.legado.app.help.config.AppConfig
import io.legado.app.help.http.BackstageWebView
import io.legado.app.help.http.CookieStore
import io.legado.app.model.analyzeRule.AnalyzeUrl
import io.legado.app.utils.NetworkUtils
import com.script.rhino.runScriptWithContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import java.io.BufferedReader
import java.io.ByteArrayInputStream
import java.io.Closeable
import java.io.InputStreamReader
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URI
import java.nio.charset.StandardCharsets
import java.security.KeyFactory
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.security.spec.PKCS8EncodedKeySpec
import java.time.Instant
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import kotlin.coroutines.EmptyCoroutineContext

@RunWith(AndroidJUnit4::class)
class Ticket13OracleTest {

    @Test
    fun wv01HiddenDirectGet() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val targetContext = instrumentation.targetContext
        val fixtureText = instrumentation.context.assets.open("ticket13/WV-01.json")
            .bufferedReader().use { it.readText() }
        val fixture = JSONObject(fixtureText)
        val outputDir = targetContext.getExternalFilesDir(null)!!.resolve("ticket13-oracle")
        outputDir.mkdirs()
        val output = outputDir.resolve("WV-01.json")
        val summary = JSONObject()
            .put("schemaVersion", 1)
            .put("fixtureId", fixture.getString("id"))
            .put("baselineCommit", BASELINE_COMMIT)
            .put("startedAtUtc", Instant.now().toString())
            .put("device", deviceProvenance())

        try {
            ReplayServer(fixture).use { replay ->
                val requestFixture = fixture.getJSONObject("request")
                val sourceHeader = requestFixture.getJSONObject("headers")
                    .getString("X-Wayfinder")
                val operation = BackstageWebView(
                    url = replay.url(fixture.getString("path")),
                    headerMap = mapOf("X-Wayfinder" to sourceHeader)
                )
                val started = SystemClock.elapsedRealtime()
                val response = runBlocking { operation.getStrResponse() }
                val durationMs = SystemClock.elapsedRealtime() - started
                val requests = replay.snapshotRequests()
                replay.failure?.let { throw it }

                val expectedPath = fixture.getString("path")
                val expectedBodyMarker = "<main id=\"oracle\">frozen-android</main>"
                val firstRequest = requests.firstOrNull()
                val checks = linkedMapOf(
                    "requestObserved" to (firstRequest != null),
                    "requestMethod" to (firstRequest?.method == requestFixture.getString("method")),
                    "requestPath" to (firstRequest?.target == expectedPath),
                    "sourceHeader" to (firstRequest?.headers?.get("x-wayfinder") == sourceHeader),
                    "defaultOuterHtml" to (response.body?.contains(expectedBodyMarker) == true),
                    "finalUrl" to (response.url == replay.url(expectedPath)),
                    "syntheticStatus" to (response.code() == 200),
                    "normalCleanup" to waitForWebViewFieldNull(operation)
                )

                summary
                    .put("completedAtUtc", Instant.now().toString())
                    .put("runtime", runtimeProvenance())
                    .put("operation", JSONObject()
                        .put("durationMs", durationMs)
                        .put("responseUrl", response.url)
                        .put("responseCode", response.code())
                        .put("responseBody", response.body)
                        .put("priorResponseCode", response.raw.priorResponse?.code ?: JSONObject.NULL))
                    .put("requests", JSONArray(requests.map { it.toJson() }))
                    .put("checks", JSONObject(checks))
                    .put("executionVerdict", if (checks.values.all { it }) "pass" else "fail")
            }
        } catch (error: Throwable) {
            summary
                .put("completedAtUtc", Instant.now().toString())
                .put("executionVerdict", "fail")
                .put("error", JSONObject()
                    .put("type", error.javaClass.name)
                    .put("message", error.message ?: ""))
            throw error
        } finally {
            output.writeText(summary.toString(2) + "\n")
        }

        assertEquals("pass", summary.getString("executionVerdict"))
    }

    @Test
    fun wv02HttpPostBootstrap() = recordFixture("WV-02") { fixture, replay ->
        val options = JSONObject()
            .put("method", "POST")
            .put("body", fixture.getString("postBody"))
            .put("webView", true)
            .put("webJs", fixture.getString("javaScript"))
            .put("webViewDelayTime", fixture.getLong("delayTime"))
        val operation = AnalyzeUrl(
            "${replay.url(fixture.getString("path"))},$options",
            headerMapF = fixtureHeaders(fixture)
        )
        val started = SystemClock.elapsedRealtime()
        val response = runBlocking { operation.getStrResponseAwait() }
        val durationMs = SystemClock.elapsedRealtime() - started
        val requests = replay.snapshotRequests()
        val first = requests.firstOrNull()
        val checks = linkedMapOf(
            "postObserved" to (first?.method == "POST"),
            "postBody" to (first?.body == fixture.getString("postBody")),
            "sourceHeader" to (first?.headers?.get("x-wayfinder") == "wv02"),
            "relativeResource" to requests.any { it.target == "/relative.js" },
            "customJavaScript" to (response.body?.contains("ASSET=true") == true),
            "baseUrl" to (response.body?.contains("BASE=${replay.url("/post")}") == true),
            "responseUrl" to (response.url == replay.url("/post"))
        )
        operationJson(response, durationMs, requests, checks)
    }

    @Test
    fun wv03InlineHtmlWithoutBaseUrl() = recordFixture("WV-03") { fixture, replay ->
        val operation = BackstageWebView(
            html = fixture.getString("html"),
            javaScript = fixture.getString("javaScript")
        )
        val started = SystemClock.elapsedRealtime()
        val response = runBlocking { operation.getStrResponse() }
        val durationMs = SystemClock.elapsedRealtime() - started
        val checks = linkedMapOf(
            "inlineMarker" to (response.body?.contains("inline-no-base") == true),
            "inlineJavaScript" to (response.body?.contains("INLINE=ok") == true),
            "legacyPlaceholderUrl" to (response.url == "http://localhost/")
        )
        operationJson(response, durationMs, replay.snapshotRequests(), checks)
    }

    @Test
    fun wv04RedirectAndSyntheticResponse() = recordFixture("WV-04") { fixture, replay ->
        val operation = BackstageWebView(url = replay.url(fixture.getString("path")))
        val started = SystemClock.elapsedRealtime()
        val response = runBlocking { operation.getStrResponse() }
        val durationMs = SystemClock.elapsedRealtime() - started
        val requests = replay.snapshotRequests()
        val paths = requests.map { it.target }.filter { it != "/favicon.ico" }
        val checks = linkedMapOf(
            "redirectChain" to (paths.take(3) == listOf("/redirect", "/final", "/late")),
            "lateBody" to (response.body?.contains("redirect-late") == true),
            "synthetic302" to (response.raw.priorResponse?.code == 302),
            "synthetic200" to (response.code() == 200),
            "finalUrl" to (response.url == replay.url("/late"))
        )
        operationJson(response, durationMs, requests, checks)
    }

    @Test
    fun wv05ResourceSnifferFirstMatch() = recordFixture("WV-05") { fixture, replay ->
        val operation = BackstageWebView(
            url = replay.url(fixture.getString("path")),
            sourceRegex = fixture.getString("sourceRegex")
        )
        val started = SystemClock.elapsedRealtime()
        val response = runBlocking { operation.getStrResponse() }
        val durationMs = SystemClock.elapsedRealtime() - started
        val requests = replay.snapshotRequests()
        val targetUrl = replay.url("/asset/target?token=abc")
        val checks = linkedMapOf(
            "matchCallbackVisible" to (response.body == targetUrl),
            "subresourceRequestAtMostOnce" to
                (requests.count { it.target == "/asset/target?token=abc" } <= 1),
            "firstMatchCleanup" to webViewFieldIsNull(operation),
            "sourceResponseOrigin" to (response.url == replay.url("/sniff"))
        )
        operationJson(response, durationMs, requests, checks)
    }

    @Test
    fun wv06OverrideSnifferBlocksNavigation() = recordFixture("WV-06") { fixture, replay ->
        val operation = BackstageWebView(
            url = replay.url(fixture.getString("path")),
            overrideUrlRegex = fixture.getString("overrideRegex")
        )
        val started = SystemClock.elapsedRealtime()
        val response = runBlocking { operation.getStrResponse() }
        val durationMs = SystemClock.elapsedRealtime() - started
        val requests = replay.snapshotRequests()
        val blockedUrl = replay.url("/blocked")
        val checks = linkedMapOf(
            "matchedUrl" to (response.body == blockedUrl),
            "blockedRequestAbsent" to requests.none { it.target == "/blocked" },
            "overrideCleanup" to webViewFieldIsNull(operation),
            "responseOrigin" to (response.url == replay.url("/override"))
        )
        operationJson(response, durationMs, requests, checks)
    }

    @Test
    fun wv07CookiesAcrossOperationAndStore() = recordFixture("WV-07") { fixture, replay ->
        val origin = replay.url(fixture.getString("path"))
        val first = BackstageWebView(
            url = origin,
            tag = origin,
            headerMap = fixtureHeaders(fixture)
        )
        val firstResponse = runBlocking { first.getStrResponse() }
        Thread.sleep(1_000)
        val stored = CookieStore.getCookie(origin)
        val second = BackstageWebView(url = replay.url("/echo"), tag = origin)
        val secondResponse = runBlocking { second.getStrResponse() }
        Thread.sleep(300)
        val requests = replay.snapshotRequests()
        val durableCookie = waitForDurableCookie(origin)
        val echoCookie = requests.firstOrNull { it.target == "/echo" }?.headers?.get("cookie") ?: ""
        val checks = linkedMapOf(
            "initialAppCookieAbsent" to requests.firstOrNull { it.target == "/cookie" }
                ?.headers?.get("cookie").isNullOrEmpty(),
            "firstResponse" to (firstResponse.body?.contains("cookie") == true),
            "storeHasPageCookie" to stored.contains("sid=from-page"),
            "storeHasJavaScriptCookie" to stored.contains("js=from-js"),
            "webViewOutboundPageCookie" to echoCookie.contains("sid=from-page"),
            "webViewOutboundJavaScriptCookie" to echoCookie.contains("js=from-js"),
            "durableStoreHasPageCookie" to durableCookie.contains("sid=from-page"),
            "durableStoreHasJavaScriptCookie" to durableCookie.contains("js=from-js"),
            "secondResponse" to (secondResponse.body?.contains("echo") == true)
        )
        JSONObject()
            .put("operation", JSONArray(listOf(responseJson(firstResponse), responseJson(secondResponse))))
            .put("cookieStore", stored)
            .put("durableCookieStore", durableCookie)
            .put("echoCookie", echoCookie)
            .put("requests", JSONArray(requests.map { it.toJson() }))
            .put("checks", JSONObject(checks))
            .put("executionVerdict", if (checks.values.all { it }) "pass" else "fail")
    }

    @Test
    fun wv08StorageAcrossWebViewInstances() = recordFixture("WV-08") { fixture, replay ->
        val base = replay.url(fixture.getString("path"))
        val first = BackstageWebView(
            url = base,
            html = fixture.getString("html"),
            javaScript = fixture.getString("firstJavaScript")
        )
        val firstResponse = runBlocking { first.getStrResponse() }
        val second = BackstageWebView(
            url = base,
            html = fixture.getString("html"),
            javaScript = fixture.getString("secondJavaScript")
        )
        val secondResponse = runBlocking { second.getStrResponse() }
        val checks = linkedMapOf(
            "firstLocalStorage" to (firstResponse.body?.contains("persisted") == true),
            "firstSessionStorage" to (firstResponse.body?.contains("instance") == true),
            "sameOrigin" to (secondResponse.body?.contains("persisted") == true),
            "newInstanceSessionStorageAbsent" to (secondResponse.body?.contains("\"session\":null") == true)
        )
        JSONObject()
            .put("operation", JSONArray(listOf(responseJson(firstResponse), responseJson(secondResponse))))
            .put("requests", JSONArray(replay.snapshotRequests().map { it.toJson() }))
            .put("checks", JSONObject(checks))
            .put("executionVerdict", if (checks.values.all { it }) "pass" else "fail")
    }


    @Test
    fun wv09NullResultRetryTimeout() = recordFixture("WV-09") { fixture, replay ->
        val operation = BackstageWebView(
            html = fixture.getString("html"),
            javaScript = fixture.getString("javaScript")
        )
        val started = SystemClock.elapsedRealtime()
        val error = runCatching {
            runBlocking { operation.getStrResponse() }
        }.exceptionOrNull()
        val durationMs = SystemClock.elapsedRealtime() - started
        val checks = linkedMapOf(
            "expectedErrorType" to (error?.javaClass?.name ==
                "io.legado.app.exception.NoStackTraceException"),
            "expectedErrorMessage" to (error?.message == fixture.getString("expectedError")),
            "retriedForAtLeast30Seconds" to (durationMs >= 30_000),
            "completedBeforeOuterTimeout" to (durationMs < 60_000),
            "errorCleanup" to waitForWebViewFieldNull(operation)
        )
        JSONObject()
            .put("operation", JSONObject()
                .put("durationMs", durationMs)
                .put("error", error?.let { errorJson(it) } ?: JSONObject.NULL))
            .put("requests", JSONArray(replay.snapshotRequests().map { it.toJson() }))
            .put("checks", JSONObject(checks))
            .put("executionVerdict", if (checks.values.all { it }) "pass" else "fail")
    }

    @Test
    fun wv10OuterTimeoutStopsPostTerminalActivity() = recordFixture("WV-10") { fixture, replay ->
        val operation = BackstageWebView(url = replay.url(fixture.getString("path")))
        val started = SystemClock.elapsedRealtime()
        val error = runCatching {
            runBlocking { operation.getStrResponse() }
        }.exceptionOrNull()
        val durationMs = SystemClock.elapsedRealtime() - started
        val cleaned = waitForWebViewFieldNull(operation)
        Thread.sleep(fixture.getLong("postTerminalObservationMs"))
        val requests = replay.snapshotRequests()
        val checks = linkedMapOf(
            "requestObserved" to requests.any { it.target == fixture.getString("path") },
            "outerTimeoutError" to (error?.javaClass?.name
                ?.endsWith("TimeoutCancellationException") == true),
            "timeoutAtSixtySeconds" to (durationMs in 59_000..65_000),
            "postTerminalRequestAbsent" to requests.none {
                it.target == fixture.getString("postTerminalPath")
            },
            "timeoutCleanup" to cleaned
        )
        JSONObject()
            .put("operation", JSONObject()
                .put("durationMs", durationMs)
                .put("error", error?.let { errorJson(it) } ?: JSONObject.NULL))
            .put("requests", JSONArray(requests.map { it.toJson() }))
            .put("checks", JSONObject(checks))
            .put("executionVerdict", if (checks.values.all { it }) "pass" else "fail")
    }

    @Test
    fun wv11ExplicitCancellationBeforeLoadAndInFlight() = recordFixture("WV-11") { fixture, replay ->
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val mainEntered = CountDownLatch(1)
        val mainRelease = CountDownLatch(1)
        Handler(Looper.getMainLooper()).post {
            mainEntered.countDown()
            mainRelease.await(5, TimeUnit.SECONDS)
        }
        check(mainEntered.await(2, TimeUnit.SECONDS)) { "Main looper gate did not start" }

        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val queuedOperation = BackstageWebView(url = replay.url(fixture.getString("queuedPath")))
        val queued = scope.async { queuedOperation.getStrResponse() }
        Thread.sleep(150)
        queued.cancel()
        mainRelease.countDown()
        runBlocking { queued.join() }
        instrumentation.waitForIdleSync()
        Thread.sleep(300)
        val queuedLoadAfterCancellation = replay.snapshotRequests().any {
            it.target == fixture.getString("queuedPath")
        }

        val flightOperation = BackstageWebView(url = replay.url(fixture.getString("flightPath")))
        val flight = scope.async { flightOperation.getStrResponse() }
        val flightRequestObserved = waitForRequest(
            replay,
            fixture.getString("flightPath"),
            5_000
        )
        flight.cancel()
        runBlocking { flight.join() }
        instrumentation.waitForIdleSync()
        Thread.sleep(fixture.getLong("postTerminalObservationMs"))
        val requests = replay.snapshotRequests()
        val checks = linkedMapOf(
            "queuedCancellationCompleted" to queued.isCancelled,
            "queuedCancellationCleanup" to waitForWebViewFieldNull(queuedOperation),
            "flightRequestObserved" to flightRequestObserved,
            "flightCancellationCompleted" to flight.isCancelled,
            "flightCancellationCleanup" to waitForWebViewFieldNull(flightOperation),
            "postCancellationRequestAbsent" to requests.none {
                it.target == fixture.getString("postTerminalPath")
            }
        )
        scope.cancel()
        JSONObject()
            .put("operation", JSONObject()
                .put("queuedLoadAfterCancellation", queuedLoadAfterCancellation)
                .put("queuedCancelled", queued.isCancelled)
                .put("flightCancelled", flight.isCancelled))
            .put("requests", JSONArray(requests.map { it.toJson() }))
            .put("checks", JSONObject(checks))
            .put("executionVerdict", if (checks.values.all { it }) "pass" else "fail")
    }

    @Test
    fun wv12OverlapLimiterSiblingCancellationAndOrdering() = recordFixture("WV-12") { fixture, replay ->
        val helperSource = BookSource(
            bookSourceUrl = fixture.getString("helperSourceKey"),
            bookSourceName = "WV-12 helper",
            enabledCookieJar = false
        )
        val helper = FixtureJsExtensions(helperSource)
        val executor = Executors.newFixedThreadPool(2)
        val startGate = CountDownLatch(1)
        val helperStarted = SystemClock.elapsedRealtime()
        val helperA = executor.submit(java.util.concurrent.Callable {
            startGate.await()
            runScriptWithContext(EmptyCoroutineContext) {
                helper.webView(
                    null,
                    replay.url(fixture.getString("helperAPath")),
                    fixture.getString("helperJavaScript")
                )
            }
        })
        val helperB = executor.submit(java.util.concurrent.Callable {
            startGate.await()
            runScriptWithContext(EmptyCoroutineContext) {
                helper.webView(
                    null,
                    replay.url(fixture.getString("helperBPath")),
                    fixture.getString("helperJavaScript")
                )
            }
        })
        startGate.countDown()
        val helperAResult = helperA.get(15, TimeUnit.SECONDS)
        val helperBResult = helperB.get(15, TimeUnit.SECONDS)
        val helperDurationMs = SystemClock.elapsedRealtime() - helperStarted
        executor.shutdownNow()

        val limitedSource = BookSource(
            bookSourceUrl = fixture.getString("limitedSourceKey"),
            bookSourceName = "WV-12 limiter",
            enabledCookieJar = false,
            concurrentRate = fixture.getString("concurrentRate")
        )
        val limited = FixtureJsExtensions(limitedSource)
        val orderedPaths = fixture.getJSONArray("orderedPaths")
        val orderedUrls = Array(orderedPaths.length()) { index ->
            replay.url(orderedPaths.getString(index))
        }
        val orderedStarted = SystemClock.elapsedRealtime()
        val ordered = runScriptWithContext(EmptyCoroutineContext) {
            limited.ajaxAll(orderedUrls)
        }
        val orderedDurationMs = SystemClock.elapsedRealtime() - orderedStarted

        val siblingSource = BookSource(
            bookSourceUrl = fixture.getString("siblingSourceKey"),
            bookSourceName = "WV-12 sibling",
            enabledCookieJar = false
        )
        val webViewOptions = JSONObject()
            .put("webView", true)
            .put("webJs", fixture.getString("helperJavaScript"))
        val slowAnalyze = AnalyzeUrl(
            "${replay.url(fixture.getString("siblingSlowPath"))},$webViewOptions",
            source = siblingSource
        )
        val fastAnalyze = AnalyzeUrl(
            "${replay.url(fixture.getString("siblingFastPath"))},$webViewOptions",
            source = siblingSource
        )
        val siblingScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val slowSibling = siblingScope.async { slowAnalyze.getStrResponseAwait() }
        val slowObserved = waitForRequest(replay, fixture.getString("siblingSlowPath"), 5_000)
        val fastSibling = siblingScope.async { fastAnalyze.getStrResponseAwait() }
        val fastObserved = waitForRequest(replay, fixture.getString("siblingFastPath"), 5_000)
        slowSibling.cancel()
        runBlocking { slowSibling.join() }
        val fastResponse = runBlocking { fastSibling.await() }
        siblingScope.cancel()

        val requests = replay.snapshotRequests()
        val helperRequests = requests.filter {
            it.target == fixture.getString("helperAPath") ||
                it.target == fixture.getString("helperBPath")
        }
        val orderedPathSet = (0 until orderedPaths.length())
            .map { orderedPaths.getString(it) }
            .toSet()
        val orderedRequests = requests.filter { it.target in orderedPathSet }
        val helperStartGapMs = requestStartGap(helperRequests)
        val limiterStartGapMs = requestStartGap(orderedRequests)
        val configuredIntervalMs = fixture.getString("concurrentRate")
            .substringAfter('/')
            .toLong()
        val minimumObservedGapMs = configuredIntervalMs - 50
        val expectedOrderedBodies = fixture.getJSONArray("orderedBodies")
        val checks = linkedMapOf(
            "directHelpersReturned" to (helperAResult == "helper-a" &&
                helperBResult == "helper-b"),
            "directHelpersOverlap" to (helperRequests.size == 2 && helperStartGapMs < 500),
            "sourceLimiterBaselineShape" to (
                orderedRequests.size == orderedPaths.length() &&
                    orderedRequests.take(2).let { requestStartGap(it) < 500 } &&
                    orderedRequests[2].startedAtElapsedMs -
                        orderedRequests[0].startedAtElapsedMs >= minimumObservedGapMs
                ),
            "orderedResults" to (ordered.map { it.body } ==
                (0 until expectedOrderedBodies.length()).map {
                    expectedOrderedBodies.getString(it)
                }),
            "slowSiblingRequestObserved" to slowObserved,
            "fastSiblingRequestObserved" to fastObserved,
            "slowSiblingCancelled" to slowSibling.isCancelled,
            "siblingCompletedAfterCancellation" to (fastResponse.body == "sibling-fast")
        )
        JSONObject()
            .put("operation", JSONObject()
                .put("helperDurationMs", helperDurationMs)
                .put("helperStartGapMs", helperStartGapMs)
                .put("orderedDurationMs", orderedDurationMs)
                .put("limiterStartGapMs", limiterStartGapMs)
                .put("configuredIntervalMs", configuredIntervalMs)
                .put("minimumObservedGapMs", minimumObservedGapMs)
                .put("orderedBodies", JSONArray(ordered.map { it.body })))
            .put("requests", JSONArray(requests.map { it.toJson() }))
            .put("checks", JSONObject(checks))
            .put("executionVerdict", if (checks.values.all { it }) "pass" else "fail")
    }

    @Test
    fun wv13HttpAndMainFrameErrors() = recordFixture("WV-13") { fixture, replay ->
        val http500 = runBlocking {
            AnalyzeUrl(
                replay.url(fixture.getString("http500Path")),
                callTimeout = 5_000
            ).getStrResponseAwait()
        }
        val abortError = runCatching {
            runBlocking {
                AnalyzeUrl(
                    replay.url(fixture.getString("abortPath")),
                    callTimeout = 5_000
                ).getStrResponseAwait()
            }
        }.exceptionOrNull()
        val webView500Operation = BackstageWebView(
            url = replay.url(fixture.getString("webView500Path")),
            javaScript = fixture.getString("javaScript")
        )
        val webView500 = runBlocking { webView500Operation.getStrResponse() }
        val requests = replay.snapshotRequests()
        val checks = linkedMapOf(
            "http500IsOrdinaryResponse" to (http500.code() == 500 &&
                http500.body == "http-500"),
            "abortedConnectionThrows" to (abortError != null),
            "mainFrame500BodyReturned" to (webView500.body == "webview-500"),
            "mainFrame500MetadataSynthetic200" to (webView500.code() == 200),
            "mainFrameErrorCleanup" to waitForWebViewFieldNull(webView500Operation)
        )
        JSONObject()
            .put("operation", JSONObject()
                .put("http500", responseJson(http500))
                .put("abortError", abortError?.let { errorJson(it) } ?: JSONObject.NULL)
                .put("webView500", responseJson(webView500)))
            .put("requests", JSONArray(requests.map { it.toJson() }))
            .put("checks", JSONObject(checks))
            .put("executionVerdict", if (checks.values.all { it }) "pass" else "fail")
    }

    @Test
    fun wv14InvalidTlsPolicyAndSetupCleanup() = recordFixture("WV-14") { fixture, replay ->
        val tlsOperation = BackstageWebView(
            url = replay.url(fixture.getString("tlsPath")),
            javaScript = fixture.getString("javaScript")
        )
        val tlsResponse = runBlocking { tlsOperation.getStrResponse() }

        val setupOperation = BackstageWebView()
        val setupError = runCatching {
            runBlocking { setupOperation.getStrResponse() }
        }.exceptionOrNull()
        val baselineSetupCleaned = webViewFieldIsNull(setupOperation)
        val harnessCleanup = forceDestroyWebView(setupOperation)
        val requests = replay.snapshotRequests()
        val checks = linkedMapOf(
            "invalidTlsReachedFixture" to requests.any {
                it.target == fixture.getString("tlsPath")
            },
            "baselineAcceptedInvalidTls" to (tlsResponse.body == "invalid-tls-accepted"),
            "tlsOperationCleanup" to waitForWebViewFieldNull(tlsOperation),
            "setupFailureObserved" to (setupError != null),
            "setupLeakObserved" to !baselineSetupCleaned,
            "harnessCleanupCompleted" to harnessCleanup
        )
        JSONObject()
            .put("operation", JSONObject()
                .put("tls", responseJson(tlsResponse))
                .put("setupError", setupError?.let { errorJson(it) } ?: JSONObject.NULL)
                .put("baselineSetupCleanup", baselineSetupCleaned))
            .put("requests", JSONArray(requests.map { it.toJson() }))
            .put("checks", JSONObject(checks))
            .put("policyReason", "frozen-baseline-accepts-invalid-tls")
            .put("executionVerdict", if (checks.values.all { it }) {
                "policy-rejected"
            } else {
                "fail"
            })
    }

    @Test
    fun wv07CookiesAfterProcessRestart() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val targetContext = instrumentation.targetContext
        val fixture = instrumentation.context.assets.open("ticket13/WV-07.json")
            .bufferedReader().use { JSONObject(it.readText()) }
        val output = targetContext.getExternalFilesDir(null)!!.resolve("ticket13-oracle/WV-07.json")
        val prior = JSONObject(output.readText())
        val priorUrl = prior.getJSONArray("operation")
            .getJSONObject(0)
            .getString("responseUrl")
        val priorPort = URI(priorUrl).port
        val storedBeforeWebView = CookieStore.getCookie(priorUrl)
        val restartReplay = ReplayServer(fixture, priorPort).use { replay ->
            val actualOrigin = replay.url(fixture.getString("path"))
            val response = runBlocking {
                BackstageWebView(url = replay.url("/echo"), tag = actualOrigin)
                    .getStrResponse()
            }
            Thread.sleep(1_000)
            val requests = replay.snapshotRequests()
            val storedAfterWebView = CookieStore.getCookie(actualOrigin)
            val echoCookie = requests.firstOrNull { it.target == "/echo" }
                ?.headers?.get("cookie") ?: ""
            JSONObject()
                .put("response", responseJson(response))
                .put("storeBeforeWebView", storedBeforeWebView)
                .put("storeAfterWebView", storedAfterWebView)
                .put("echoCookie", echoCookie)
                .put("requests", JSONArray(requests.map { it.toJson() }))
                .put("checks", JSONObject(linkedMapOf(
                    "response" to (response.body?.contains("echo") == true),
                    "durableStorePresentBeforeWebView" to (
                        storedBeforeWebView.contains("sid=from-page") &&
                            storedBeforeWebView.contains("js=from-js")
                        ),
                    "nativeSessionCookiesAbsentAfterRestart" to echoCookie.isEmpty(),
                    "webViewCompletionOverwritesStoreWithEmptyNativeCookie" to
                        storedAfterWebView.isEmpty()
                )))
        }
        val restartChecks = restartReplay.getJSONObject("checks")
        val allChecks = prior.getJSONObject("checks")
        val keys = restartChecks.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            allChecks.put("restart_$key", restartChecks.getBoolean(key))
        }
        prior.put("restart", restartReplay)
            .put("checks", allChecks)
            .put("completedAtUtc", Instant.now().toString())
            .put("executionVerdict", if (jsonChecksPass(allChecks)) {
                "pass"
            } else {
                "fail"
            })
        output.writeText(prior.toString(2) + "\n")
        assertEquals("pass", prior.getString("executionVerdict"))
    }

    @Test
    fun wv08StorageAfterProcessRestart() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val targetContext = instrumentation.targetContext
        val fixture = instrumentation.context.assets.open("ticket13/WV-08.json")
            .bufferedReader().use { JSONObject(it.readText()) }
        val output = targetContext.getExternalFilesDir(null)!!.resolve("ticket13-oracle/WV-08.json")
        val prior = JSONObject(output.readText())
        val priorUrl = prior.getJSONArray("operation")
            .getJSONObject(0)
            .getString("responseUrl")
        val priorPort = URI(priorUrl).port
        val restart = ReplayServer(fixture, priorPort).use { replay ->
            val base = replay.url(fixture.getString("path"))
            val response = runBlocking {
                BackstageWebView(
                    url = base,
                    html = fixture.getString("html"),
                    javaScript = fixture.getString("secondJavaScript")
                ).getStrResponse()
            }
            JSONObject()
                .put("response", responseJson(response))
                .put("checks", JSONObject(linkedMapOf(
                    "localStorageAfterRestart" to (response.body?.contains("persisted") == true),
                    "sessionStorageAfterRestartAbsent" to (
                        response.body?.contains("\"session\":null") == true
                        )
                )))
                .put("requests", JSONArray(replay.snapshotRequests().map { it.toJson() }))
        }
        val restartChecks = restart.getJSONObject("checks")
        val allChecks = prior.getJSONObject("checks")
        val keys = restartChecks.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            allChecks.put("restart_$key", restartChecks.getBoolean(key))
        }
        prior.put("restart", restart)
            .put("checks", allChecks)
            .put("completedAtUtc", Instant.now().toString())
            .put("executionVerdict", if (jsonChecksPass(allChecks)) {
                "pass"
            } else {
                "fail"
            })
        output.writeText(prior.toString(2) + "\n")
        assertEquals("pass", prior.getString("executionVerdict"))
    }


    private fun waitForDurableCookie(url: String, timeoutMs: Long = 3_000): String {
        val domain = NetworkUtils.getSubDomain(url)
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        var cookie = ""
        do {
            cookie = appDb.cookieDao.get(domain)?.cookie ?: ""
            if (cookie.isNotEmpty()) return cookie
            Thread.sleep(50)
        } while (SystemClock.elapsedRealtime() < deadline)
        return cookie
    }

    private fun jsonChecksPass(checks: JSONObject): Boolean {
        val keys = checks.keys()
        while (keys.hasNext()) {
            if (!checks.getBoolean(keys.next())) return false
        }
        return true
    }

    private fun recordFixture(
        id: String,
        operation: (JSONObject, ReplayServer) -> JSONObject
    ) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val fixture = instrumentation.context.assets.open("ticket13/$id.json")
            .bufferedReader().use { JSONObject(it.readText()) }
        val expectedVerdict = fixture.optString("expectedVerdict", "pass")
        val targetContext = instrumentation.targetContext
        val outputDir = targetContext.getExternalFilesDir(null)!!.resolve("ticket13-oracle")
        outputDir.mkdirs()
        val output = outputDir.resolve("$id.json")
        val summary = JSONObject()
            .put("schemaVersion", 1)
            .put("fixtureId", id)
            .put("baselineCommit", BASELINE_COMMIT)
            .put("startedAtUtc", Instant.now().toString())
            .put("device", deviceProvenance())
        try {
            ReplayServer(fixture).use { replay ->
                val result = operation(fixture, replay)
                val keys = result.keys()
                while (keys.hasNext()) {
                    val key = keys.next()
                    summary.put(key, result.get(key))
                }
                summary
                    .put("runtime", runtimeProvenance())
                    .put("completedAtUtc", Instant.now().toString())
            }
        } catch (error: Throwable) {
            summary
                .put("completedAtUtc", Instant.now().toString())
                .put("executionVerdict", "fail")
                .put("error", JSONObject()
                    .put("type", error.javaClass.name)
                    .put("message", error.message ?: ""))
        } finally {
            output.writeText(summary.toString(2) + "\n")
        }
        assertEquals(expectedVerdict, summary.optString("executionVerdict"))
    }

    private fun errorJson(error: Throwable) = JSONObject()
        .put("type", error.javaClass.name)
        .put("message", error.message ?: "")

    private fun waitForRequest(replay: ReplayServer, path: String, timeoutMs: Long): Boolean {
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        while (SystemClock.elapsedRealtime() < deadline) {
            if (replay.snapshotRequests().any { it.target == path }) return true
            Thread.sleep(25)
        }
        return false
    }

    private fun waitForWebViewFieldNull(
        operation: BackstageWebView,
        timeoutMs: Long = 2_000
    ): Boolean {
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        while (SystemClock.elapsedRealtime() < deadline) {
            if (webViewFieldIsNull(operation)) return true
            Thread.sleep(25)
        }
        return webViewFieldIsNull(operation)
    }

    private fun forceDestroyWebView(operation: BackstageWebView): Boolean {
        val field = BackstageWebView::class.java.getDeclaredField("mWebView")
        field.isAccessible = true
        val webView = field.get(operation) as? WebView ?: return true
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            webView.destroy()
            field.set(operation, null)
        }
        return field.get(operation) == null
    }

    private fun requestStartGap(requests: List<RequestObservation>): Long {
        if (requests.size < 2) return Long.MAX_VALUE
        val starts = requests.map { it.startedAtElapsedMs }
        return starts.maxOrNull()!! - starts.minOrNull()!!
    }

    private class FixtureJsExtensions(private val source: BookSource) : JsExtensions {
        override fun getSource() = source
    }

    private fun fixtureHeaders(fixture: JSONObject): Map<String, String> {
        val headers = linkedMapOf<String, String>()
        fixture.optJSONObject("requestHeaders")?.let { json ->
            val keys = json.keys()
            while (keys.hasNext()) {
                val key = keys.next()
                headers[key] = json.getString(key)
            }
        }
        return headers
    }

    private fun operationJson(
        response: io.legado.app.help.http.StrResponse,
        durationMs: Long,
        requests: List<RequestObservation>,
        checks: Map<String, Boolean>
    ) = JSONObject()
        .put("operation", responseJson(response).put("durationMs", durationMs))
        .put("requests", JSONArray(requests.map { it.toJson() }))
        .put("checks", JSONObject(checks))
        .put("executionVerdict", if (checks.values.all { it }) "pass" else "fail")

    private fun responseJson(response: io.legado.app.help.http.StrResponse) = JSONObject()
        .put("responseUrl", response.url)
        .put("responseCode", response.code())
        .put("responseBody", response.body)
        .put("priorResponseCode", response.raw.priorResponse?.code ?: JSONObject.NULL)

    private fun deviceProvenance() = JSONObject()
        .put("manufacturer", Build.MANUFACTURER)
        .put("model", Build.MODEL)
        .put("device", Build.DEVICE)
        .put("androidRelease", Build.VERSION.RELEASE)
        .put("sdk", Build.VERSION.SDK_INT)
        .put("fingerprint", Build.FINGERPRINT)
        .put("locale", Locale.getDefault().toLanguageTag())
        .put("timezone", TimeZone.getDefault().id)

    private fun runtimeProvenance(): JSONObject {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val targetContext = instrumentation.targetContext
        val webViewPackage = WebViewCompat.getCurrentWebViewPackage(targetContext)
        var defaultUserAgent = ""
        instrumentation.runOnMainSync {
            defaultUserAgent = WebView.getCurrentWebViewPackage()?.let {
                android.webkit.WebSettings.getDefaultUserAgent(targetContext)
            } ?: ""
        }
        return JSONObject()
            .put("webViewPackage", webViewPackage?.packageName ?: "")
            .put("webViewVersion", webViewPackage?.versionName ?: "")
            .put("defaultUserAgent", defaultUserAgent)
            .put("legadoUserAgent", AppConfig.userAgent)
    }

    private fun webViewFieldIsNull(operation: BackstageWebView): Boolean {
        val field = BackstageWebView::class.java.getDeclaredField("mWebView")
        field.isAccessible = true
        return field.get(operation) == null
    }

    private data class RequestObservation(
        val method: String,
        val target: String,
        val headers: Map<String, String>,
        val body: String,
        val startedAtElapsedMs: Long
    ) {
        fun toJson() = JSONObject()
            .put("method", method)
            .put("target", target)
            .put("headers", JSONObject(headers))
            .put("body", body)
            .put("startedAtElapsedMs", startedAtElapsedMs)
    }

    private class ReplayServer(
        private val fixture: JSONObject,
        private val requestedPort: Int = 0
    ) : Closeable {
        private val tls = fixture.optBoolean("tls", false)
        private val server = createServer(fixture)
        private val executor = Executors.newCachedThreadPool()
        private val requests = CopyOnWriteArrayList<RequestObservation>()

        @Volatile
        var failure: Throwable? = null
            private set

        init {
            executor.execute {
                while (!server.isClosed) {
                    try {
                        val socket = server.accept()
                        executor.execute {
                            try {
                                handle(socket)
                            } catch (error: Throwable) {
                                if (!server.isClosed) failure = error
                            }
                        }
                    } catch (error: Throwable) {
                        if (!server.isClosed) failure = error
                    }
                }
            }
        }

        fun url(path: String) =
            "${if (tls) "https" else "http"}://127.0.0.1:${server.localPort}$path"

        fun snapshotRequests(): List<RequestObservation> = requests.toList()

        private fun handle(socket: Socket) {
            socket.use { connection ->
                connection.soTimeout = 10_000
                val reader = BufferedReader(
                    InputStreamReader(connection.getInputStream(), StandardCharsets.ISO_8859_1)
                )
                val requestLine = reader.readLine() ?: return
                val parts = requestLine.split(' ', limit = 3)
                require(parts.size == 3) { "Invalid request line: $requestLine" }
                val headers = linkedMapOf<String, String>()
                while (true) {
                    val line = reader.readLine() ?: break
                    if (line.isEmpty()) break
                    val separator = line.indexOf(':')
                    require(separator > 0) { "Invalid header: $line" }
                    headers[line.substring(0, separator).lowercase()] =
                        line.substring(separator + 1).trim()
                }
                val bodyLength = headers["content-length"]?.toIntOrNull() ?: 0
                val bodyChars = CharArray(bodyLength)
                var bodyRead = 0
                while (bodyRead < bodyLength) {
                    val count = reader.read(bodyChars, bodyRead, bodyLength - bodyRead)
                    if (count < 0) break
                    bodyRead += count
                }
                val body = String(bodyChars, 0, bodyRead)
                requests += RequestObservation(
                    parts[0],
                    parts[1],
                    headers,
                    body,
                    SystemClock.elapsedRealtime()
                )

                val route = routeFor(parts[0], parts[1])
                if (route?.optBoolean("abort", false) == true) return
                val status = route?.optInt("status", 404) ?: 404
                val reason = route?.optString(
                    "reason",
                    if (status == 404) "Not Found" else "OK"
                ) ?: "Not Found"
                val responseBody = route?.optString("body", "") ?: "not found"
                val responseBytes = responseBody.toByteArray(StandardCharsets.UTF_8)
                route?.optLong("delayMs", 0L)?.takeIf { it > 0 }?.let { Thread.sleep(it) }
                val responseHeaders = linkedMapOf<String, String>()
                route?.optJSONObject("headers")?.let { configured ->
                    val keys = configured.keys()
                    while (keys.hasNext()) {
                        val key = keys.next()
                        responseHeaders[key] = configured.getString(key)
                    }
                }
                if (responseHeaders.keys.none { it.equals("Content-Type", true) }) {
                    responseHeaders["Content-Type"] = "text/plain; charset=utf-8"
                }
                responseHeaders["Content-Length"] = responseBytes.size.toString()
                responseHeaders["Connection"] = "close"
                val head = buildString {
                    append("HTTP/1.1 $status $reason\r\n")
                    responseHeaders.forEach { (name, value) -> append("$name: $value\r\n") }
                    append("\r\n")
                }.toByteArray(StandardCharsets.ISO_8859_1)
                val output = connection.getOutputStream()
                output.write(head)
                output.write(responseBytes)
                output.flush()
            }
        }

        private fun routeFor(method: String, target: String): JSONObject? {
            fixture.optJSONArray("routes")?.let { routes ->
                for (index in 0 until routes.length()) {
                    val route = routes.getJSONObject(index)
                    if (route.optString("method", "GET") == method &&
                        route.optString("path") == target
                    ) {
                        return route
                    }
                }
                return null
            }
            if (fixture.optString("path") == target && method == "GET") {
                return fixture.getJSONObject("response")
            }
            return null
        }

        private fun createServer(fixture: JSONObject): ServerSocket {
            val server = if (!fixture.optBoolean("tls", false)) {
                ServerSocket()
            } else {
                val certificate = CertificateFactory.getInstance("X.509").generateCertificate(
                    ByteArrayInputStream(
                        Base64.decode(fixture.getString("certificateDerBase64"), Base64.DEFAULT)
                    )
                )
                val privateKey = KeyFactory.getInstance("RSA").generatePrivate(
                    PKCS8EncodedKeySpec(
                        Base64.decode(fixture.getString("privateKeyPkcs8Base64"), Base64.DEFAULT)
                    )
                )
                val password = "ticket13".toCharArray()
                val keyStore = KeyStore.getInstance(KeyStore.getDefaultType()).apply {
                    load(null)
                    setKeyEntry("ticket13", privateKey, password, arrayOf(certificate))
                }
                val keyManagers = KeyManagerFactory
                    .getInstance(KeyManagerFactory.getDefaultAlgorithm())
                    .apply { init(keyStore, password) }
                SSLContext.getInstance("TLS").apply {
                    init(keyManagers.keyManagers, null, null)
                }.serverSocketFactory.createServerSocket()
            }
            server.reuseAddress = true
            server.bind(InetSocketAddress(InetAddress.getByName("127.0.0.1"), requestedPort))
            return server
        }

        override fun close() {
            server.close()
            executor.shutdownNow()
        }
    }

    companion object {
        private const val BASELINE_COMMIT = "14dd24945b2914ce2708b8abaa4ee67ceef892af"
    }
}
