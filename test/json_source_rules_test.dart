import 'package:flutter_test/flutter_test.dart';
import 'package:liber/source/json_source_rules.dart';

void main() {
  test('supports arrays and recursive JSONPath values', () {
    final root = {
      'data': [
        {'novelId': '1', 'name': 'A'},
        {'novelId': '2', 'name': 'B'},
      ],
      'meta': {'className': '玄幻'},
    };
    expect(JsonSourceRules.list(root, r'$.data[*]').length, 2);
    expect(JsonSourceRules.text(root, r'$.data[0].novelId'), '1');
    expect(JsonSourceRules.values(root, r'$..className'), ['玄幻']);
    expect(
      JsonSourceRules.template(
        root,
        'id=' '{{' r'$.data[1].novelId' '}}',
      ),
      'id=2',
    );
  });
}
