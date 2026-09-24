import 'package:cgit_flutter/op_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('credentials in remote URLs never reach the log', () {
    expect(
      redactUrlCredentials(
          "fatal: unable to access 'https://Ckales:ghp_abc123@github.com/x.git/'"),
      "fatal: unable to access 'https://<REDACTED>@github.com/x.git/'",
    );
    const plain = 'To https://github.com/Ckales/CTerminal.git';
    expect(redactUrlCredentials(plain), plain);
  });
}
