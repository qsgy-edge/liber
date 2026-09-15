import 'package:flutter_test/flutter_test.dart';
import 'package:liber/source/json_source_rules.dart';

void main() {
  test('decodes CatEye AES chapter URL', () {
    // AES-128-CBC, key/IV used by the source, plaintext https://example.com/1.
    expect(
      aesBase64DecodeToString(
        'CrmyNAzlhtf+PS2Axon2/aLpdWZrK0yA/ra+Gb6OTKA=',
        'f041c49714d39908',
        '0123456789abcdef',
      ),
      'https://example.com/1',
    );
  });
}
