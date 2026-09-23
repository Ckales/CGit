import 'package:cgit_flutter/ai_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

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

  test('the token survives a reload', () async {
    final ai = await AiSettings.load();
    await ai.writeToken('  sk-secret-value  ');

    expect(await (await AiSettings.load()).readToken(), 'sk-secret-value');
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
