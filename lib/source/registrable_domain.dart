import 'package:public_suffix/public_suffix.dart';

import 'public_suffix_list.dart';

/// The cookie key the frozen baseline uses for a URL's host: the registrable
/// domain (eTLD+1), or the host itself when it is an IP literal (ADR 0011 §3).
///
/// `CookieStore.kt:27` stores under `NetworkUtils.getSubDomain(url)`, which is
/// Guava's `PublicSuffixDatabase.getEffectiveTldPlusOne`, so the public suffix
/// list decides where a site ends and the private section counts: `blogspot.com`
/// is a suffix, `www.example.co.uk` and `other.example.co.uk` share one key, and
/// `example.com` and `example.org` do not. The list is the snapshot in
/// [publicSuffixList], whose header names its own VERSION and COMMIT — the key a
/// build writes is the list that build shipped.
///
/// Hosts the list gives no registrable domain (a bare suffix such as `co.uk`, or
/// a name the list does not know such as `localhost`) stay themselves, so a host
/// with a cookie always has a key. An IP literal stays itself because the list
/// knows nothing about addresses: `127.0.0.1` is its own site.
String registrableDomain(String host) {
  final normalized = host.toLowerCase();
  if (normalized.isEmpty || _isIpLiteral(normalized)) return normalized;
  final parsed = PublicSuffix.fromUrl(
    Uri(scheme: 'http', host: normalized),
    suffixRules: _rules(),
    leniency: Leniency.allowAll,
  );
  return parsed?.domain ?? normalized;
}

/// The rules of [publicSuffixList], parsed once per process.
///
/// Parsing is lazy because it is the only cost the dependency adds: the list is
/// 10 329 rules, and a process that never touches a cookie (a migration import,
/// the local reader) never pays for them.
SuffixRules _rules() => _parsed ??= SuffixRules.fromString(publicSuffixList);
SuffixRules? _parsed;

/// Whether [host] is an IPv4 or IPv6 literal rather than a name.
///
/// `Uri.host` drops the brackets of an IPv6 literal, so a colon is one here.
bool _isIpLiteral(String host) {
  if (host.contains(':')) return true;
  final parts = host.split('.');
  if (parts.length != 4) return false;
  for (final part in parts) {
    if (part.isEmpty || part.length > 3) return false;
    final value = int.tryParse(part);
    if (value == null || value > 255) return false;
  }
  return true;
}
