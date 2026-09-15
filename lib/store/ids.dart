import 'dart:math';

final _random = Random();

/// Mints a space-local id.
///
/// Ids are minted once and never derived from a mutable fact: a book's identity
/// has to survive its source being replaced, and a group's identity has to
/// survive a rename (`docs/user-data-contract.md` D2, D3).
String mintId(String prefix) =>
    '$prefix-${DateTime.now().toUtc().microsecondsSinceEpoch.toRadixString(36)}'
    '-${_random.nextInt(1 << 30).toRadixString(36)}';
