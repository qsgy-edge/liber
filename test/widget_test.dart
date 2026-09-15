import 'package:flutter_test/flutter_test.dart';

import 'package:liber/main.dart';

void defaultAppTest() {
  testWidgets('Windows MVP shows the controlled source workbench', (
    tester,
  ) async {
    await tester.pumpWidget(const LiberApp());

    expect(find.text('书架'), findsNWidgets(2));
    expect(find.text('Wayfinder 受控书源'), findsOneWidget);
    expect(find.text('尚未运行'), findsOneWidget);
  });
}

void main() {
  defaultAppTest();
}
