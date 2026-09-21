import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ticket13_adapter/fixture_runner.dart';
import 'package:ticket13_adapter/fixtures_concurrency.dart';
import 'package:ticket13_adapter/fixtures_error_paths.dart';

/// One fixture per invocation, selected at run time from a selector file the
/// run script writes to the app's external files directory, so a run can
/// require an explicit pass and collect that fixture's evidence before the next
/// one runs.
///
/// The selector is read at run time rather than compiled in with
/// `--dart-define`, because a compile-time define changes the APK for every
/// fixture and the accepted evidence must be attributable to one recorded build.
///
/// Evidence travels back through the binding's report data instead of a device
/// file: the runner uninstalls the app after a run, and an uninstall removes the
/// app's external files directory along with anything written there.
class Selection {
  Selection(this.fixtureId, this.phase, this.port);

  static Future<Selection> read() async {
    final paths = await DevicePaths.resolve();
    final file = File('${paths.root.path}/selector.json');
    final json = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    return Selection(
      json['fixture']! as String,
      (json['phase'] as String?) ?? 'main',
      (json['port'] as int?) ?? 0,
    );
  }

  final String fixtureId;
  final String phase;
  final int port;
}

final Map<String, Future<EvidenceRecord> Function()> runners = {
  'WV-01': runWv01,
  'WV-02': runWv02,
  'WV-03': runWv03,
  'WV-04': runWv04,
  'WV-05': runWv05,
  'WV-06': runWv06,
  'WV-07': runWv07,
  'WV-08': runWv08,
  'WV-09': runWv09,
  'WV-10': runWv10,
  'WV-11': runWv11,
  'WV-12': runWv12,
  'WV-13': runWv13,
  'WV-14': runWv14,
};

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'destination adapter fixture',
    (tester) async {
      final selection = await Selection.read();
      final selectedFixture = selection.fixtureId;
      final restartPort = selection.port;
      final restartRunners = <String, Future<EvidenceRecord> Function(int)>{
        'WV-07': runWv07Restart,
        'WV-08': runWv08Restart,
      };
      if (selection.phase == 'restart') {
        final restartRunner = restartRunners[selectedFixture];
        expect(
          restartRunner,
          isNotNull,
          reason: 'fixture "$selectedFixture" has no restart phase',
        );
        expect(restartPort, greaterThan(0), reason: 'selector.json needs a port');
        final restartRecord = await restartRunner!(restartPort);
        binding.reportData = <String, dynamic>{
          'evidence': jsonEncode(await restartRecord.toJson()),
        };
        expect(restartRecord.failure, isNull,
            reason: 'restart phase failed: ${restartRecord.failure}');
        expect(
          restartRecord.checks.entries
              .where((entry) => !entry.value)
              .map((e) => e.key),
          isEmpty,
          reason: 'failed restart checks',
        );
        return;
      }
      final runner = runners[selectedFixture];
      expect(
        runner,
        isNotNull,
        reason: 'unknown fixture "$selectedFixture" in selector.json',
      );
      final record = await runner!();
      binding.reportData = <String, dynamic>{
        'evidence': jsonEncode(await record.toJson()),
      };
      expect(record.failure, isNull, reason: 'adapter failed: ${record.failure}');
      expect(
        record.checks.entries.where((entry) => !entry.value).map((e) => e.key),
        isEmpty,
        reason: 'failed checks',
      );
      expect(record.verdict, record.policyRejected ? 'policy-rejected' : 'pass');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
