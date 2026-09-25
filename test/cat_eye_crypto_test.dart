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

  group('the AES arguments come from the rule (#94)', () {
    // The two 猫眼 sources in the operator's library carry different keys, so a
    // constant decrypts one of them into garbage.
    test('reads the key, transformation and iv the rule names', () {
      final arguments = catEyeAesArguments(
        r'$.path@js:java.aesBase64DecodeToString(result,"4395daa50ad6baf7",'
        r'"AES/CBC/PKCS5Padding","0123456789abcdef")',
      );
      expect(arguments, isNotNull);
      expect(arguments!.key, '4395daa50ad6baf7');
      expect(arguments.iv, '0123456789abcdef');
    });

    test('the other 猫眼 source keeps its own key', () {
      final arguments = catEyeAesArguments(
        r'$.path@js:java.aesBase64DecodeToString(result, "f041c49714d39908", '
        r'"AES/CBC/PKCS5Padding", "0123456789abcdef")',
      );
      expect(arguments!.key, 'f041c49714d39908');
    });

    test('a rule that is not that call answers null', () {
      expect(catEyeAesArguments(r'$.path'), isNull);
      expect(
        catEyeAesArguments(
          r'$.path@js:java.aesBase64DecodeToString(result,"k","AES/ECB/NoPadding","i")',
        ),
        isNull,
        reason: 'a transformation this decoder does not implement is refused, '
            'so the field is answered the ordinary way',
      );
    });
  });
}
