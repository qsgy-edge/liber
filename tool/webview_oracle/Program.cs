using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

internal static class Program
{
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    [STAThread]
    private static void Main()
    {
        Application.SetHighDpiMode(HighDpiMode.SystemAware);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new ProbeHost());
    }

    private sealed class ProbeHost : Form
    {
        public ProbeHost()
        {
            Text = "Wayfinder ticket 13 probe";
            ShowInTaskbar = false;
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.Manual;
            Location = new Point(-32000, -32000);
            ClientSize = new Size(2, 2);
            Opacity = 0;
        }

        protected override async void OnShown(EventArgs e)
        {
            base.OnShown(e);
            var exitCode = 1;
            try
            {
                exitCode = await RunProbeAsync(this);
            }
            catch (Exception error)
            {
                await WriteFailureAsync(error);
            }
            finally
            {
                Environment.ExitCode = exitCode;
                Close();
            }
        }
    }

    private static async Task<int> RunProbeAsync(Form host)
    {
        var project = Directory.GetCurrentDirectory();
        var fixturePath = Path.Combine(project, "fixture.json");
        var evidenceDirectory = Path.Combine(project, "evidence", "windows");
        var userDataDirectory = Path.Combine(project, "user-data");
        Directory.CreateDirectory(evidenceDirectory);
        DeleteDirectory(userDataDirectory);

        await using var replay = new ReplayServer();
        await replay.StartAsync();

        var environment = await CoreWebView2Environment.CreateAsync(
            userDataFolder: userDataDirectory
        );
        var normal = await RunNormalAsync(host, environment, replay);
        var concurrency = await RunConcurrencyAsync(host, environment, replay);
        var timeout = await RunScriptTimeoutAsync(host, environment, replay);
        var cancellation = await RunCancellationAsync(host, environment, replay);
        var recovery = await RunRecoveryAsync(host, environment, replay);

        var checks = new Dictionary<string, bool>
        {
            ["hiddenLoad"] = normal.Hidden,
            ["redirect"] = normal.Redirected,
            ["delayedJavaScript"] = normal.ReadyText.StartsWith("delayed-dom", StringComparison.Ordinal),
            ["finalDom"] = normal.Html.Contains("<div id=\"ready\">delayed-dom", StringComparison.Ordinal),
            ["finalUrl"] = normal.FinalUrl == replay.Url("final"),
            ["sourceUrlExtraction"] = normal.ResourceLoaded
                && normal.ResourceUrls.Contains(replay.Url("resource.js"), StringComparer.Ordinal),
            ["httpCookieToWebView"] = normal.Cookies.GetValueOrDefault("httpSeed") == "from-http"
                && normal.ReadyText.Contains("httpSeed=from-http", StringComparison.Ordinal)
                && replay.Requests.Any(request =>
                    Equals(request.GetValueOrDefault("target"), "/start")
                    && request.GetValueOrDefault("cookie") is string cookie
                    && cookie.Contains("httpSeed=from-http", StringComparison.Ordinal)
                ),
            ["webViewResponseCookie"] = normal.Cookies.GetValueOrDefault("serverCookie") == "from-response",
            ["webViewJavaScriptCookie"] = normal.Cookies.GetValueOrDefault("jsCookie") == "from-js",
            ["webViewCookieToHttp"] = normal.HttpEchoCookie
                == "httpSeed=from-http; jsCookie=from-js; serverCookie=from-response",
            ["localStorage"] = normal.Storage.GetValueOrDefault("local") == "persisted",
            ["sessionStorage"] = normal.Storage.GetValueOrDefault("session") == "alive",
            ["concurrency"] = concurrency.Passed,
            ["timeoutDisposedScript"] = timeout.Passed,
            ["explicitCancellation"] = cancellation.Passed,
            ["postDisposalRecovery"] = recovery,
            ["noUnmatchedRequests"] = replay.UnmatchedRequests == 0,
        };
        var windowsPass = checks.Values.All(value => value);

        var summary = new
        {
            fixtureId = "ticket-13-webview-contract-v1",
            platform = "windows-x64",
            adapter = "native WebView2 engine (no Flutter plugin)",
            runtimeVersion = CoreWebView2Environment.GetAvailableBrowserVersionString(),
            sdkVersion = "1.0.3179.45",
            candidateSelfCheckVerdict = windowsPass ? "pass" : "fail",
            contractVerdict = "not-run",
            aggregateFivePlatformVerdict = "not-run",
            provenance = new
            {
                baselineSha = "14dd24945b2914ce2708b8abaa4ee67ceef892af",
                executedAtUtc = DateTimeOffset.UtcNow,
                probeSourceSha256 = Sha256(Path.Combine(project, "Program.cs")),
                projectSha256 = Sha256(Path.Combine(project, "WebViewProbe.csproj")),
                fixtureSha256 = Sha256(fixturePath),
                webView2LoaderSha256 = Sha256(Path.Combine(AppContext.BaseDirectory, "WebView2Loader.dll")),
            },
            checks,
            coverageGaps = new[]
            {
                "POST bootstrap and inline HTML load modes",
                "sourceRegex and overrideUrlRegex early-completion semantics",
                "cookie/storage state across instances, origins, and restart",
                "null-result retry timeout and 60-second outer timeout",
                "early cancellation race and source-visible post-terminal side effects",
                "HTTP, renderer, setup, and invalid-certificate error branches",
                "Flutter adapter and Android/iOS/macOS/Linux executions",
            },
            observations = new { normal, concurrency, timeout, cancellation, recovery },
            requestTrace = replay.Requests,
            platformResults = new object[]
            {
                new
                {
                    platform = "windows",
                    adapter = "WebView2 native engine",
                    verdict = "not-run",
                    reason = windowsPass
                        ? "bounded candidate self-check passed; complete frozen contract matrix was not run"
                        : "bounded candidate self-check failed",
                },
                new { platform = "windows", adapter = "flutter_inappwebview", verdict = "not-run", reason = "package absent from local pub cache" },
                new { platform = "android", adapter = "Android WebView", verdict = "not-run" },
                new { platform = "ios", adapter = "WKWebView", verdict = "not-run" },
                new { platform = "macos", adapter = "WKWebView", verdict = "not-run" },
                new { platform = "linux", adapter = "WebKitGTK", verdict = "not-run", reason = "no Linux execution host" },
            },
            capabilityRows = checks.Select(pair => new
            {
                capability = pair.Key,
                platform = "windows",
                adapter = "WebView2 native engine",
                verdict = pair.Value ? "pass" : "fail",
            }),
        };

        var summaryPath = Path.Combine(evidenceDirectory, "summary.json");
        await File.WriteAllTextAsync(summaryPath, JsonSerializer.Serialize(summary, JsonOptions).ReplaceLineEndings("\n") + "\n");
        Console.WriteLine(summaryPath);
        return windowsPass ? 0 : 1;
    }

    private static async Task<NormalObservation> RunNormalAsync(
        Form host,
        CoreWebView2Environment environment,
        ReplayServer replay
    )
    {
        using var http = new HttpClient(new HttpClientHandler { UseCookies = false });
        using var seedResponse = await http.GetAsync(replay.Url("http-seed"));
        var setCookie = seedResponse.Headers.GetValues("Set-Cookie").Single();
        var seedPair = setCookie.Split(';', 2)[0].Split('=', 2);

        await using var session = await WebViewSession.CreateAsync(host, environment);
        var seed = session.Core.CookieManager.CreateCookie(seedPair[0], seedPair[1], "127.0.0.1", "/");
        session.Core.CookieManager.AddOrUpdateCookie(seed);
        var navigation = await session.NavigateAsync(replay.Url("start"), TimeSpan.FromSeconds(10));
        await Task.Delay(400);

        var finalUrl = session.Core.Source;
        var readyText = await session.ScriptStringAsync("document.getElementById('ready')?.textContent ?? ''");
        var resourceLoaded = await session.ScriptBooleanAsync("window.resourceLoaded === true");
        var html = await session.ScriptStringAsync("document.documentElement.outerHTML");
        var storage = await session.ScriptObjectAsync(
            "({local: localStorage.getItem('local'), session: sessionStorage.getItem('session')})"
        );
        var cookies = await session.GetCookieMapAsync(replay.BaseUrl);
        var cookieHeader = string.Join("; ", cookies.OrderBy(pair => pair.Key).Select(pair => $"{pair.Key}={pair.Value}"));
        using var echoRequest = new HttpRequestMessage(HttpMethod.Get, replay.Url("echo"));
        echoRequest.Headers.TryAddWithoutValidation("Cookie", cookieHeader);
        using var echoResponse = await http.SendAsync(echoRequest);
        var echo = JsonSerializer.Deserialize<Dictionary<string, string>>(
            await echoResponse.Content.ReadAsStringAsync()
        )!;

        return new NormalObservation(
            Hidden: !host.ShowInTaskbar && host.Opacity == 0 && host.Right < 0,
            Redirected: navigation.StartedUrls.SequenceEqual(new[] { replay.Url("start"), replay.Url("final") }),
            FinalUrl: finalUrl,
            ReadyText: readyText,
            ResourceLoaded: resourceLoaded,
            ResourceUrls: session.ResourceUrls,
            Html: html,
            Storage: storage,
            Cookies: cookies,
            HttpEchoCookie: echo.GetValueOrDefault("cookie", ""),
            Navigation: navigation
        );
    }

    private static async Task<ConcurrencyObservation> RunConcurrencyAsync(
        Form host,
        CoreWebView2Environment environment,
        ReplayServer replay
    )
    {
        await using var first = await WebViewSession.CreateAsync(host, environment);
        await using var second = await WebViewSession.CreateAsync(host, environment);
        var firstTask = first.NavigateAsync(replay.Url("parallel/a"), TimeSpan.FromSeconds(10));
        var secondTask = second.NavigateAsync(replay.Url("parallel/b"), TimeSpan.FromSeconds(10));
        var results = await Task.WhenAll(firstTask, secondTask);
        var firstHtml = await first.ScriptStringAsync("document.documentElement.outerHTML");
        var secondHtml = await second.ScriptStringAsync("document.documentElement.outerHTML");
        return new ConcurrencyObservation(
            Passed: results.All(result => result.Success)
                && firstHtml.Contains("parallel-a", StringComparison.Ordinal)
                && secondHtml.Contains("parallel-b", StringComparison.Ordinal)
                && replay.MaxParallelRequests >= 2,
            MaxParallelRequests: replay.MaxParallelRequests,
            FirstHtml: firstHtml,
            SecondHtml: secondHtml
        );
    }

    private static async Task<AbortObservation> RunScriptTimeoutAsync(
        Form host,
        CoreWebView2Environment environment,
        ReplayServer replay
    )
    {
        var session = await WebViewSession.CreateAsync(host, environment);
        var navigation = session.NavigateAsync(replay.Url("spin"), TimeSpan.FromSeconds(30));
        var completedBeforeTimeout = await Task.WhenAny(navigation, Task.Delay(500)) == navigation;
        var processId = session.Core.BrowserProcessId;
        await session.DisposeAsync();
        var endedAfterDispose = await CompletesWithinAsync(navigation, TimeSpan.FromSeconds(5));
        return new AbortObservation(
            Passed: !completedBeforeTimeout && endedAfterDispose,
            CompletedBeforeAbort: completedBeforeTimeout,
            OperationEndedAfterDispose: endedAfterDispose,
            RequestDisconnected: null,
            BrowserProcessId: processId
        );
    }

    private static async Task<AbortObservation> RunCancellationAsync(
        Form host,
        CoreWebView2Environment environment,
        ReplayServer replay
    )
    {
        var session = await WebViewSession.CreateAsync(host, environment);
        var navigation = session.NavigateAsync(replay.Url("hang"), TimeSpan.FromSeconds(30));
        await replay.HangStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var completedBeforeAbort = navigation.IsCompleted;
        var processId = session.Core.BrowserProcessId;
        session.Core.Stop();
        await session.DisposeAsync();
        var endedAfterDispose = await CompletesWithinAsync(navigation, TimeSpan.FromSeconds(5));
        var requestDisconnected = await CompletesWithinAsync(replay.HangDisconnected.Task, TimeSpan.FromSeconds(5));
        return new AbortObservation(
            Passed: !completedBeforeAbort && endedAfterDispose && requestDisconnected,
            CompletedBeforeAbort: completedBeforeAbort,
            OperationEndedAfterDispose: endedAfterDispose,
            RequestDisconnected: requestDisconnected,
            BrowserProcessId: processId
        );
    }

    private static async Task<bool> RunRecoveryAsync(
        Form host,
        CoreWebView2Environment environment,
        ReplayServer replay
    )
    {
        await using var session = await WebViewSession.CreateAsync(host, environment);
        var result = await session.NavigateAsync(replay.Url("recovery"), TimeSpan.FromSeconds(10));
        var html = await session.ScriptStringAsync("document.documentElement.outerHTML");
        return result.Success && html.Contains("recovered", StringComparison.Ordinal);
    }

    private static async Task<bool> CompletesWithinAsync(Task task, TimeSpan timeout)
    {
        if (await Task.WhenAny(task, Task.Delay(timeout)) != task) return false;
        try
        {
            await task;
        }
        catch (OperationCanceledException)
        {
        }
        catch (ObjectDisposedException)
        {
        }
        return true;
    }

    private static async Task WriteFailureAsync(Exception error)
    {
        var path = Path.Combine(Directory.GetCurrentDirectory(), "evidence", "windows", "summary.json");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var result = new
        {
            platform = "windows-x64",
            adapter = "native WebView2 engine (no Flutter plugin)",
            contractVerdict = "not-run",
            candidateSelfCheckVerdict = "not-run",
            aggregateFivePlatformVerdict = "not-run",
            errorType = error.GetType().FullName,
            error = error.ToString(),
        };
        await File.WriteAllTextAsync(path, JsonSerializer.Serialize(result, JsonOptions));
        Console.Error.WriteLine(error);
    }

    private static string Sha256(string path)
    {
        using var stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
    }

    private static void DeleteDirectory(string path)
    {
        if (!Directory.Exists(path)) return;
        Directory.Delete(path, recursive: true);
    }

    private sealed record NormalObservation(
        bool Hidden,
        bool Redirected,
        string FinalUrl,
        string ReadyText,
        bool ResourceLoaded,
        IReadOnlyList<string> ResourceUrls,
        string Html,
        IReadOnlyDictionary<string, string?> Storage,
        IReadOnlyDictionary<string, string> Cookies,
        string HttpEchoCookie,
        NavigationObservation Navigation
    );

    private sealed record ConcurrencyObservation(
        bool Passed,
        int MaxParallelRequests,
        string FirstHtml,
        string SecondHtml
    );

    private sealed record AbortObservation(
        bool Passed,
        bool CompletedBeforeAbort,
        bool OperationEndedAfterDispose,
        bool? RequestDisconnected,
        uint BrowserProcessId
    );
}

internal sealed class WebViewSession : IAsyncDisposable
{
    private readonly Form _host;
    private readonly WebView2 _control;
    private readonly ConcurrentQueue<string> _resourceUrls = new();
    private readonly EventHandler<CoreWebView2WebResourceRequestedEventArgs> _resourceHandler;
    private readonly CancellationTokenSource _disposedSignal = new();
    private bool _disposed;

    private WebViewSession(Form host, WebView2 control)
    {
        _host = host;
        _control = control;
        _resourceHandler = (_, args) => _resourceUrls.Enqueue(args.Request.Uri);
        Core.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.All);
        Core.WebResourceRequested += _resourceHandler;
    }

    public WebView2 Control => _control;
    public CoreWebView2 Core => _control.CoreWebView2;
    public IReadOnlyList<string> ResourceUrls => _resourceUrls.ToArray();

    public static async Task<WebViewSession> CreateAsync(Form host, CoreWebView2Environment environment)
    {
        var control = new WebView2 { Size = new Size(2, 2), Visible = true };
        host.Controls.Add(control);
        await control.EnsureCoreWebView2Async(environment);
        control.CoreWebView2.Settings.IsScriptEnabled = true;
        control.CoreWebView2.Settings.AreDefaultScriptDialogsEnabled = false;
        return new WebViewSession(host, control);
    }

    public async Task<NavigationObservation> NavigateAsync(string url, TimeSpan timeout)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        var startedUrls = new List<string>();
        var completion = new TaskCompletionSource<CoreWebView2NavigationCompletedEventArgs>(
            TaskCreationOptions.RunContinuationsAsynchronously
        );
        void Started(object? sender, CoreWebView2NavigationStartingEventArgs args) => startedUrls.Add(args.Uri);
        void Completed(object? sender, CoreWebView2NavigationCompletedEventArgs args) => completion.TrySetResult(args);
        Core.NavigationStarting += Started;
        Core.NavigationCompleted += Completed;
        try
        {
            Core.Navigate(url);
            var result = await completion.Task.WaitAsync(timeout, _disposedSignal.Token);
            return new NavigationObservation(
                result.IsSuccess,
                result.HttpStatusCode,
                result.WebErrorStatus.ToString(),
                startedUrls
            );
        }
        finally
        {
            if (!_disposed)
            {
                Core.NavigationStarting -= Started;
                Core.NavigationCompleted -= Completed;
            }
        }
    }

    public async Task<string> ScriptStringAsync(string source)
    {
        var json = await Core.ExecuteScriptAsync(source);
        return JsonSerializer.Deserialize<string>(json) ?? "";
    }

    public async Task<IReadOnlyDictionary<string, string?>> ScriptObjectAsync(string source)
    {
        var json = await Core.ExecuteScriptAsync(source);
        return JsonSerializer.Deserialize<Dictionary<string, string?>>(json)!;
    }

    public async Task<bool> ScriptBooleanAsync(string source)
    {
        var json = await Core.ExecuteScriptAsync(source);
        return JsonSerializer.Deserialize<bool>(json);
    }

    public async Task<IReadOnlyDictionary<string, string>> GetCookieMapAsync(string url)
    {
        var cookies = await Core.CookieManager.GetCookiesAsync(url);
        return cookies
            .OrderBy(cookie => cookie.Name, StringComparer.Ordinal)
            .ToDictionary(cookie => cookie.Name, cookie => cookie.Value, StringComparer.Ordinal);
    }

    public ValueTask DisposeAsync()
    {
        if (_disposed) return ValueTask.CompletedTask;
        _disposed = true;
        _disposedSignal.Cancel();
        Core.WebResourceRequested -= _resourceHandler;
        _host.Controls.Remove(_control);
        _control.Dispose();
        _disposedSignal.Dispose();
        return ValueTask.CompletedTask;
    }
}

internal sealed record NavigationObservation(
    bool Success,
    int HttpStatusCode,
    string ErrorStatus,
    IReadOnlyList<string> StartedUrls
);

internal sealed class ReplayServer : IAsyncDisposable
{
    private readonly CancellationTokenSource _shutdown = new();
    private readonly ConcurrentBag<Task> _connections = new();
    private readonly List<Dictionary<string, object?>> _requests = new();
    private readonly object _requestLock = new();
    private TcpListener? _listener;
    private Task? _acceptLoop;
    private int _activeParallel;
    private int _maxParallel;
    private int _sequence;
    private int _unmatched;

    public string BaseUrl { get; private set; } = "";
    public int MaxParallelRequests => _maxParallel;
    public int UnmatchedRequests => _unmatched;
    public IReadOnlyList<Dictionary<string, object?>> Requests
    {
        get { lock (_requestLock) return _requests.ToArray(); }
    }

    public TaskCompletionSource HangStarted { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public TaskCompletionSource HangDisconnected { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

    public string Url(string path) => $"{BaseUrl}{path.TrimStart('/')}";

    public Task StartAsync()
    {
        _listener = new TcpListener(IPAddress.Loopback, 0);
        _listener.Start();
        var port = ((IPEndPoint)_listener.LocalEndpoint).Port;
        BaseUrl = $"http://127.0.0.1:{port}/";
        _acceptLoop = AcceptLoopAsync(_shutdown.Token);
        return Task.CompletedTask;
    }

    private async Task AcceptLoopAsync(CancellationToken token)
    {
        try
        {
            while (!token.IsCancellationRequested)
            {
                var client = await _listener!.AcceptTcpClientAsync(token);
                _connections.Add(HandleAsync(client, token));
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
        }
        catch (ObjectDisposedException) when (token.IsCancellationRequested)
        {
        }
    }

    private async Task HandleAsync(TcpClient client, CancellationToken token)
    {
        try
        {
            using (client)
            using (var stream = client.GetStream())
            using (var reader = new StreamReader(stream, Encoding.ASCII, false, 1024, leaveOpen: true))
            {
                var requestLine = await reader.ReadLineAsync(token);
                if (string.IsNullOrWhiteSpace(requestLine)) return;
                var parts = requestLine.Split(' ', 3);
                var method = parts[0];
                var target = parts[1];
                var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                while (true)
                {
                    var line = await reader.ReadLineAsync(token);
                    if (string.IsNullOrEmpty(line)) break;
                    var separator = line.IndexOf(':');
                    if (separator > 0) headers[line[..separator].Trim()] = line[(separator + 1)..].Trim();
                }

                var uri = new Uri(BaseUrl.TrimEnd('/') + target);
                var path = uri.AbsolutePath;
                AddRequest(method, target, headers.GetValueOrDefault("Cookie", ""));
                switch (path)
                {
                    case "/http-seed":
                        await SendAsync(stream, 200, "OK", "seeded", "Set-Cookie: httpSeed=from-http; Path=/\r\n", token);
                        break;
                    case "/start":
                        await SendAsync(stream, 302, "Found", "", "Location: /final\r\n", token);
                        break;
                    case "/final":
                        await SendAsync(
                            stream,
                            200,
                            "OK",
                            "<!doctype html><html><body><div id=\"loading\">loading</div><script src=\"/resource.js\"></script><script>setTimeout(function(){document.cookie='jsCookie=from-js; Path=/';localStorage.setItem('local','persisted');sessionStorage.setItem('session','alive');document.body.innerHTML='<div id=\"ready\">delayed-dom '+document.cookie+'</div>';},150);</script></body></html>",
                            "Content-Type: text/html; charset=utf-8\r\nSet-Cookie: serverCookie=from-response; Path=/\r\n",
                            token
                        );
                        break;
                    case "/resource.js":
                        await SendAsync(stream, 200, "OK", "window.resourceLoaded=true;", "Content-Type: text/javascript\r\n", token);
                        break;
                    case "/echo":
                        var body = JsonSerializer.Serialize(new { cookie = headers.GetValueOrDefault("Cookie", "") });
                        await SendAsync(stream, 200, "OK", body, "Content-Type: application/json\r\n", token);
                        break;
                    case "/parallel/a":
                    case "/parallel/b":
                        var active = Interlocked.Increment(ref _activeParallel);
                        UpdateMaxParallel(active);
                        await Task.Delay(300, token);
                        Interlocked.Decrement(ref _activeParallel);
                        var marker = path.EndsWith('a') ? "parallel-a" : "parallel-b";
                        await SendAsync(stream, 200, "OK", $"<html><body>{marker}</body></html>", "Content-Type: text/html\r\n", token);
                        break;
                    case "/favicon.ico":
                        await SendAsync(stream, 204, "No Content", "", "Content-Type: image/x-icon\r\n", token);
                        break;
                    case "/spin":
                        await SendAsync(stream, 200, "OK", "<html><body><script>while(true){}</script></body></html>", "Content-Type: text/html\r\n", token);
                        break;
                    case "/hang":
                        HangStarted.TrySetResult();
                        while (!token.IsCancellationRequested)
                        {
                            if (client.Client.Poll(1000, SelectMode.SelectRead) && client.Available == 0)
                            {
                                HangDisconnected.TrySetResult();
                                return;
                            }
                            await Task.Delay(20, token);
                        }
                        break;
                    case "/recovery":
                        await SendAsync(stream, 200, "OK", "<html><body>recovered</body></html>", "Content-Type: text/html\r\n", token);
                        break;
                    default:
                        Interlocked.Increment(ref _unmatched);
                        await SendAsync(stream, 404, "Not Found", "unmatched", "", token);
                        break;
                }
            }
        }
        catch (IOException)
        {
            // Expected when timeout/cancellation disposes a WebView mid-response.
        }
        catch (SocketException)
        {
            // Expected when timeout/cancellation closes the loopback socket.
        }
    }

    private void AddRequest(string method, string target, string cookie)
    {
        var entry = new Dictionary<string, object?>
        {
            ["sequence"] = Interlocked.Increment(ref _sequence),
            ["method"] = method,
            ["target"] = target,
            ["cookie"] = cookie,
        };
        lock (_requestLock) _requests.Add(entry);
    }

    private void UpdateMaxParallel(int current)
    {
        while (true)
        {
            var observed = _maxParallel;
            if (current <= observed) return;
            if (Interlocked.CompareExchange(ref _maxParallel, current, observed) == observed) return;
        }
    }

    private static async Task SendAsync(
        NetworkStream stream,
        int status,
        string reason,
        string body,
        string extraHeaders,
        CancellationToken token
    )
    {
        var bytes = Encoding.UTF8.GetBytes(body);
        var headers = Encoding.ASCII.GetBytes(
            $"HTTP/1.1 {status} {reason}\r\nContent-Length: {bytes.Length}\r\nConnection: close\r\nCache-Control: no-store\r\n{extraHeaders}\r\n"
        );
        await stream.WriteAsync(headers, token);
        await stream.WriteAsync(bytes, token);
        await stream.FlushAsync(token);
    }

    public async ValueTask DisposeAsync()
    {
        _shutdown.Cancel();
        _listener?.Stop();
        if (_acceptLoop != null) await _acceptLoop;
        try
        {
            await Task.WhenAll(_connections.ToArray()).WaitAsync(TimeSpan.FromSeconds(5));
        }
        catch (OperationCanceledException)
        {
        }
        catch (TimeoutException)
        {
        }
        _shutdown.Dispose();
    }
}
