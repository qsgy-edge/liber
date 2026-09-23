/// The frozen page walk the TOC and content stages share
/// (`BookChapterList.kt:48-121`, `BookContent.kt:54-135`), in one place for
/// both rule adapters.
///
/// The frozen stages fetch a page, parse it, and then read that page's own
/// `nextTocUrl`/`nextContentUrl` rule as a *list* (`AnalyzeRule.getStringList`,
/// `AnalyzeRule.kt:159-235`). The list's length selects the walk: nothing
/// declared ends the stage; exactly one URL keeps the sequential walk, which
/// fetches that URL and then reads each following page's own list and follows
/// only its *first* URL (`BookChapterList.kt:84-86`); more than one is fetched
/// whole, in declared order, and no page of it has its own list read
/// (`getNextUrl = false`, `BookChapterList.kt:104-121`). The content stage stops
/// before a page equal to the next chapter's URL, and the frozen reads that
/// guard only in the sequential walk (`BookContent.kt:85-88`).
///
/// Two frozen details are reproduced deliberately and named where they are
/// implemented: the *declared* walk is bounded (one rule evaluation's worth of
/// URLs, fetched once, with no recursion into the pages it fetches and no
/// guard, exactly as `mapAsync`'s branch has none), and the sequential walk
/// refuses a repeated URL by name where the frozen stops silently.
///
/// The product fetches the pages one at a time. The frozen's declared walk is
/// `mapAsync(AppConfig.threadCount)`, whose default is 16, an app preference
/// this product has no setting for; one page in flight is that walk at
/// concurrency 1, with the declared order kept and every request still going
/// through the source's own rate limit. Real concurrency would need a pipeline
/// per page (the stage request, the trace and the script runtime are per
/// analysis state), which is outside this slice.
library;

import 'source_url_rules.dart';

/// One page a stage is about to fetch: the request target, the URL options its
/// address text carried, that address text, and the URL it resolved against.
typedef SourcePageRequest = ({
  Uri url,
  SourceUrlOptions options,
  String address,
  Uri base,
});

/// One page a stage fetched: the response's own URL and the raw address texts
/// the page's next-page rule declared.
typedef SourcePageVisit = ({Uri pageUrl, List<String> items});

/// Which of the frozen's three page walks one page's declared list selects.
enum SourcePageWalk {
  /// Nothing declared: the stage ends here.
  none,

  /// Exactly one URL, or any non-empty list read by a page the walk already
  /// reached: follow that URL, then read the next page's own list and follow
  /// its first URL.
  sequential,

  /// More than one URL declared by the page the walk started from: fetch the
  /// whole list, in declared order, and read no further page's list.
  declared,
}

/// The `@js:`/`<js>` value a next-page rule answered, as the frozen
/// `AnalyzeRule.getStringList` finishes with it (`AnalyzeRule.kt:221-225`): a
/// script's array is its items and a script's string is split on newlines, so
/// either can name several pages. A null result names none.
List<String> sourceScriptTexts(Object? value) {
  if (value == null) return const <String>[];
  if (value is List) return [for (final item in value) '$item'];
  return '$value'.split('\n');
}

/// Whether the frozen `NetworkUtils.getAbsoluteURL` answers nothing for
/// [address] (`NetworkUtils.kt:174-189`): the list read drops an item that
/// trims to empty or that starts with `javascript`, and never fetches it.
bool _declaresNothing(String address) {
  final text = address.trim();
  return text.isEmpty || text.startsWith('javascript');
}

/// Fetches [first] and then every page the frozen walk reaches from it, and
/// answers how many pages were fetched.
///
/// [visit] is one page: fetch it, append the stage's own results, and answer
/// the raw address texts its next-page rule produced (an empty list when the
/// page's list must not be read, which is what [readNext] says). [resolve] is
/// one declared address text: the request target and URL options it carries,
/// resolved against the page it was read from.
///
/// [dropSelf] is the TOC stage's own filter (`BookChapterList.kt:96-100`),
/// which removes an item equal to the page it was read from; the content stage
/// keeps such an item and stops on it through [maxPages]' cycle refusal.
/// [nextChapterUrl] is the content stage's guard (`BookContent.kt:85-88`),
/// null in the TOC stage; the frozen reads it only in the sequential walk.
///
/// [maxPages] bounds the sequential walk alone; a repeated URL or a walk past
/// the bound fails with [cycleError]. The declared walk fetches each URL it was
/// given once, so it neither repeats nor recurses.
Future<int> walkSourcePages({
  required SourcePageRequest first,
  required Future<({Uri url, SourceUrlOptions options})> Function(
    String address,
    Uri pageUrl,
  )
  resolve,
  required Future<SourcePageVisit> Function(
    SourcePageRequest page, {
    required bool readNext,
  })
  visit,
  required int maxPages,
  required String cycleError,
  bool dropSelf = false,
  Uri? nextChapterUrl,
}) async {
  var visits = 0;

  /// The pages [request] declares, with the walk they select.
  Future<({List<SourcePageRequest> pages, SourcePageWalk walk})> declared(
    SourcePageRequest request,
    SourcePageVisit result, {
    required bool firstPage,
  }) async {
    final pages = <SourcePageRequest>[];
    for (final item in result.items) {
      if (_declaresNothing(item)) continue;
      final target = await resolve(item, result.pageUrl);
      // The frozen's list read keeps the first occurrence of an address and
      // drops every later one (`AnalyzeRule.kt:226-235`, in declared order).
      if (dropSelf && target.url == result.pageUrl) continue;
      if (pages.any((page) => page.url == target.url)) continue;
      pages.add((
        url: target.url,
        options: target.options,
        address: item,
        base: result.pageUrl,
      ));
    }
    var walk = firstPage
        ? switch (pages.length) {
            0 => SourcePageWalk.none,
            1 => SourcePageWalk.sequential,
            _ => SourcePageWalk.declared,
          }
        : (pages.isEmpty ? SourcePageWalk.none : SourcePageWalk.sequential);
    // The next-chapter guard: the frozen applies it only in the sequential walk
    // (`BookContent.kt:85-88`), whose page is the list's first URL — a page the
    // walk already reached follows `firstOrNull` too.
    if (walk == SourcePageWalk.sequential &&
        nextChapterUrl != null &&
        pages.first.url == nextChapterUrl) {
      walk = SourcePageWalk.none;
    }
    return (pages: pages, walk: walk);
  }

  final firstPage = await visit(first, readNext: true);
  visits++;
  final firstDeclared = await declared(first, firstPage, firstPage: true);
  switch (firstDeclared.walk) {
    case SourcePageWalk.none:
      return visits;
    case SourcePageWalk.declared:
      for (final page in firstDeclared.pages) {
        await visit(page, readNext: false);
        visits++;
      }
      return visits;
    case SourcePageWalk.sequential:
      break;
  }

  // The frozen's one-URL branch (`BookChapterList.kt:84-101`,
  // `BookContent.kt:86-110`): follow the one declared URL, then read each
  // following page's own list. The repeated-URL check is the frozen
  // `nextUrlList.contains` guard, which this product answers with a named
  // refusal instead of stopping the walk.
  final visited = <Uri>{firstPage.pageUrl};
  var page = firstDeclared.pages.first;
  while (true) {
    if (!visited.add(page.url) || visited.length > maxPages) {
      throw StateError(cycleError);
    }
    final result = await visit(page, readNext: true);
    visits++;
    final declaredNext = await declared(page, result, firstPage: false);
    if (declaredNext.walk == SourcePageWalk.none) return visits;
    page = declaredNext.pages.first;
  }
}
