import 'dart:io';

import 'package:cgit_flutter/update_check.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('appVersion 与 pubspec.yaml 保持一致', () async {
    final pubspec = await File('pubspec.yaml').readAsString();
    final version = RegExp(r'^version:\s*([0-9][^\s+]*)', multiLine: true)
        .firstMatch(pubspec)
        ?.group(1);
    expect(appVersion, version);
  });

  test('版本按数值比较而不是字符串顺序', () {
    expect(isNewerVersion('1.0.10', '1.0.9'), isTrue);
    expect(isNewerVersion('1.1.0', '1.0.99'), isTrue);
    expect(isNewerVersion('2.0.0', '1.99.99'), isTrue);
  });

  test('相同或更旧的版本不提示', () {
    expect(isNewerVersion('1.0.2', '1.0.2'), isFalse);
    expect(isNewerVersion('1.0.1', '1.0.2'), isFalse);
    expect(isNewerVersion('0.9.9', '1.0.0'), isFalse);
  });

  test('忽略 v 前缀、预发布与构建元数据', () {
    expect(isNewerVersion('v1.0.3', '1.0.2'), isTrue);
    expect(isNewerVersion('1.0.2', 'v1.0.2'), isFalse);
    expect(isNewerVersion('1.0.3-beta.1', '1.0.2'), isTrue);
    expect(isNewerVersion('1.0.3+build.7', '1.0.3'), isFalse);
  });
}
