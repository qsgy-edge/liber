// Generates the two Traditional Chinese interfaces from the Simplified
// template: `lib/l10n/app_zh_Hant_TW.arb` and `lib/l10n/app_zh_Hant_HK.arb`
// (#28).
//
// The interface's own copy is short, terminology-heavy text, and the reader
// already carries audited Simplified → Traditional word tables in
// `packages/fjs/liber_text` (`convert_to`, ADR 0010). The three Chinese
// interfaces are therefore maintained as one — the Simplified template plus the
// two generated files — rather than as three hand-written copies that drift.
//
// Usage, from the repository root, with the built native library:
//
//   dart run tool/l10n/generate_traditional.dart \
//     build/windows/x64/runner/Debug/fjs.dll
//
// A generated file stays editable: a hand correction is made in the ARB file
// *and* recorded in `tool/l10n/overrides.json` under the locale's own object, so
// the next run keeps it. A value that differs from what the tables produce and
// is not in that list is reported and the run fails, because regenerating would
// silently drop it.
import 'dart:convert';
import 'dart:io';

import 'package:fjs/fjs.dart' show ConvertTarget, LibFjs, textConvertTo;
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;

/// The template, and the file every message key comes from.
const String templatePath = 'lib/l10n/app_zh.arb';

/// Where the per-key hand corrections live.
const String overridesPath = 'tool/l10n/overrides.json';

/// The generated interfaces, in the order `l10n.yaml`'s locales are listed.
const Map<String, ConvertTarget> generated = {
  'zh_Hant_TW': ConvertTarget.traditionalTaiwan,
  'zh_Hant_HK': ConvertTarget.traditionalHongKong,
};

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln(
      'usage: dart run tool/l10n/generate_traditional.dart <fjs library>',
    );
    exit(64);
  }
  final library = args.single;
  if (!File(library).existsSync()) {
    stderr.writeln('the native library $library does not exist');
    exit(66);
  }
  await LibFjs.init(externalLibrary: ExternalLibrary.open(library));
  try {
    _generate();
  } finally {
    LibFjs.dispose();
  }
}

void _generate() {
  final template = _readArb(templatePath);
  final messages = <String, String>{
    for (final entry in template.entries)
      if (!entry.key.startsWith('@')) entry.key: entry.value as String,
  };
  final overrides = _readOverrides();
  var drifted = false;
  for (final entry in generated.entries) {
    final locale = entry.key;
    final corrected = <String, String>{
      for (final message in messages.entries)
        message.key: textConvertTo(text: message.value, target: entry.value),
    };
    for (final override
        in (overrides[locale] ?? const <String, String>{}).entries) {
      corrected[override.key] = override.value;
    }
    final path = 'lib/l10n/app_$locale.arb';
    final existing = File(path).existsSync() ? _readArb(path) : null;
    if (existing != null) {
      final kept = <String>[];
      for (final message in corrected.entries) {
        final onDisk = existing[message.key];
        if (onDisk is String && onDisk != message.value) {
          kept.add('${message.key} (on disk: ${jsonEncode(onDisk)})');
        }
      }
      if (kept.isNotEmpty) {
        drifted = true;
        stderr.writeln(
          '$path holds values the word tables do not produce. Record each in '
          '$overridesPath under "$locale", or regenerate to drop it:',
        );
        for (final line in kept) {
          stderr.writeln('  $line');
        }
      }
    }
    final output = <String, Object?>{'@@locale': locale};
    for (final key in corrected.keys.toList()..sort()) {
      output[key] = corrected[key];
    }
    File(path).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(output)}\n',
    );
    stdout.writeln('wrote $path (${corrected.length} messages)');
  }
  if (drifted) {
    stderr.writeln(
      'the generated files on disk differed from the tables; the run wrote the '
      'tables\' output and reported what would have been dropped',
    );
    exit(1);
  }
}

Map<String, Object?> _readArb(String path) {
  final decoded = jsonDecode(File(path).readAsStringSync());
  if (decoded is! Map<String, Object?>) {
    stderr.writeln('$path is not a JSON object');
    exit(65);
  }
  return decoded;
}

/// The per-key hand corrections, keyed by locale. A missing file is an empty
/// list of corrections rather than an error: the first run has none.
Map<String, Map<String, String>> _readOverrides() {
  if (!File(overridesPath).existsSync()) return const {};
  final decoded = jsonDecode(File(overridesPath).readAsStringSync());
  if (decoded is! Map<String, Object?>) {
    stderr.writeln('$overridesPath is not a JSON object');
    exit(65);
  }
  return {
    for (final locale in decoded.entries)
      locale.key: {
        for (final override in (locale.value! as Map<String, Object?>).entries)
          override.key: override.value! as String,
      },
  };
}
