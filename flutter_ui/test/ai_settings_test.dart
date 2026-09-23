import 'package:cgit_flutter/ai_settings.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The point of this class is that the token is held apart from the rest. The
/// Tauri app keeps it in localStorage beside the endpoint; here it goes to the
/// Keychain, and these pin that split so a later refactor cannot quietly undo
/// it by "simplifying" the token into shared_preferences.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, String> keychain;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    keychain = {};
    FlutterSecureStorage.setMockInitialValues(keychain);
  });

  test('an unconfigured install cannot generate', () async {
    final ai = await AiSettings.load();
    expect(ai.isConfigured, isFalse);
    expect(ai.baseUrl, isEmpty);
    expect(ai.model, isEmpty);
  });

  test('the default prompt is present out of the box', () async {
    final ai = await AiSettings.load();
    expect(ai.prompt, defaultAiPrompt);
    expect(ai.prompt, contains('提交说明'));
  });

  test('endpoint and model round-trip, and are trimmed', () async {
    final ai = await AiSettings.load();
    await ai.setBaseUrl('  https://api.example.com/v1  ');
    await ai.setModel(' gpt-4o-mini ');

    final reloaded = await AiSettings.load();
    expect(reloaded.baseUrl, 'https://api.example.com/v1');
    expect(reloaded.model, 'gpt-4o-mini');
    expect(reloaded.isConfigured, isTrue);
  });

  test('the token never lands in shared_preferences', () async {
    final ai = await AiSettings.load();
    await ai.setBaseUrl('https://api.example.com/v1');
    await ai.writeToken('sk-secret-value');

    expect(await ai.readToken(), 'sk-secret-value');

    // The whole reason this class exists: nothing in the plist holds it.
    final store = await SharedPreferences.getInstance();
    for (final key in store.getKeys()) {
      expect(store.get(key).toString(), isNot(contains('sk-secret-value')),
          reason: '$key leaked the token into preferences');
    }
  });

  test('clearing the field removes the credential rather than storing ""',
      () async {
    final ai = await AiSettings.load();
    await ai.writeToken('sk-secret-value');
    await ai.writeToken('   ');

    expect(await ai.readToken(), isNull,
        reason: 'an empty token must delete the item, not blank it');
  });

  test('a missing token reads as null, not as an error', () async {
    expect(await (await AiSettings.load()).readToken(), isNull);
  });
}
