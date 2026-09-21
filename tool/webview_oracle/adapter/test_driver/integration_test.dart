import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

/// Host-side driver. It writes each fixture's evidence to the committed
/// destination evidence directory, which is required because the runner
/// uninstalls the app after a run and an uninstall removes anything the app
/// wrote on the device. The path is outside `adapter/build/` so the evidence is
/// committed rather than discarded as a build artifact.
///
/// The destination row comes from the evidence itself, so a run cannot file
/// results under another platform's row. `TICKET13_EVIDENCE_ROOT` overrides the
/// containing directory, which the Windows sweep needs because MSVC cannot build
/// from the committed path's length and therefore builds from a short-path copy.
Future<void> main() => integrationDriver(
      // A failing run must still produce its evidence file; the default discards
      // the response data on failure, which would hide the observations that
      // explain the failure.
      writeResponseOnFailure: true,
      responseDataCallback: (Map<String, dynamic>? data) async {
        final encoded = data?['evidence'] as String?;
        if (encoded == null) return;
        final evidence = jsonDecode(encoded) as Map<String, Object?>;
        final target = evidence['target']! as String;
        final row = target.replaceFirst('-adapter', '');
        final root = Platform.environment['TICKET13_EVIDENCE_ROOT'] ??
            '../evidence';
        final directory = Directory('$root/$row');
        if (!directory.existsSync()) {
          directory.createSync(recursive: true);
        }
        final suffix = evidence['phase'] == 'restart' ? '.restart' : '';
        final file =
            File('${directory.path}/${evidence['fixtureId']}$suffix.json');
        file.writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(evidence)}\n',
        );
        stdout.writeln('evidence written: ${file.path}');
      },
    );
