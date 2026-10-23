import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'dialogs.dart';
import 'op_log.dart';
import 'prefs.dart';
import 'theme.dart';

/// 当前应用版本。发布工作流会校验这里与 pubspec.yaml、两个 Cargo.toml 一致，
/// 所以升级版本时要一起改。
const appVersion = '1.0.2';

const _releaseOwner = 'Ckales';
const _releaseRepo = 'CGit';
const _latestApiUrl =
    'https://api.github.com/repos/$_releaseOwner/$_releaseRepo/releases/latest';
const _downloadUrl =
    'https://github.com/$_releaseOwner/$_releaseRepo/releases/latest';
const _timeout = Duration(seconds: 15);

class AppRelease {
  const AppRelease({required this.version, required this.notes});

  /// 去掉 `v` 前缀的版本号，如 `1.0.3`。
  final String version;

  /// Release 的说明正文；可能为空。
  final String notes;
}

/// 拉取 GitHub 最新 Release。比当前版本新时返回它，否则返回 null。
///
/// 网络失败、GitHub 限流等情况会抛出带中文说明的字符串，由调用方决定
/// 是提示用户还是静默忽略。
Future<AppRelease?> checkForUpdate() async {
  final release = await _fetchLatestRelease();
  return isNewerVersion(release.version, appVersion) ? release : null;
}

/// 启动时的静默检查：失败不打扰用户，只在确实有新版本时弹窗。
Future<void> checkForUpdateOnStartup(BuildContext context, Prefs prefs) async {
  AppRelease? release;
  try {
    release = await checkForUpdate();
  } catch (e) {
    // 启动检查是后台行为，不弹错误；写进操作日志供排查。
    OpLog.error('检查更新失败：$e');
    return;
  }
  if (release == null) return;
  if (!context.mounted) return;
  if (prefs.skippedVersion == release.version) return;
  await showUpdateDialog(context, release: release, prefs: prefs);
}

Future<AppRelease> _fetchLatestRelease() async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..findProxy = HttpClient.findProxyFromEnvironment;
  try {
    final request = await client
        .getUrl(Uri.parse(_latestApiUrl))
        .timeout(_timeout);
    request.headers
      ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
      ..set(HttpHeaders.userAgentHeader, 'CGit/$appVersion');
    final response = await request.close().timeout(_timeout);
    final body = await response.transform(utf8.decoder).join().timeout(_timeout);

    switch (response.statusCode) {
      case 200:
        break;
      case 403:
        throw 'GitHub API 请求受限，请稍后再试';
      case 404:
        throw '还没有找到已发布的版本';
      default:
        throw '请求 GitHub 失败（HTTP ${response.statusCode}）';
    }

    Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      throw 'GitHub 返回的内容无法解析';
    }
    if (json is! Map<String, dynamic>) throw 'GitHub 返回的内容格式不正确';
    final tag = json['tag_name'];
    if (tag is! String || tag.trim().isEmpty) throw 'GitHub 返回的版本号为空';
    final notes = json['body'];
    return AppRelease(
      version: _normalize(tag),
      notes: notes is String ? notes.trim() : '',
    );
  } on TimeoutException {
    throw '连接 GitHub 超时，请检查网络或代理';
  } finally {
    client.close(force: true);
  }
}

/// 按数值比较版本：1.0.10 比 1.0.9 新，`v` 前缀和预发布后缀都不影响判断。
bool isNewerVersion(String candidate, String current) {
  final a = _versionParts(candidate);
  final b = _versionParts(current);
  final length = a.length > b.length ? a.length : b.length;
  for (var i = 0; i < length; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}

List<int> _versionParts(String version) => _normalize(version)
    .split('.')
    .map((part) => int.tryParse(part) ?? 0)
    .toList();

String _normalize(String version) => version
    .trim()
    .replaceFirst(RegExp(r'^[vV]'), '')
    .split('+')
    .first
    .split('-')
    .first;

Future<void> openReleasePage() async {
  final url = _downloadUrl;
  if (Platform.isWindows) {
    await Process.run('rundll32', ['url.dll,FileProtocolHandler', url]);
  } else if (Platform.isMacOS) {
    await Process.run('open', [url]);
  } else {
    await Process.run('xdg-open', [url]);
  }
}

/// 新版本提示：显示版本变化与 Release 说明，并提供下载入口。
Future<void> showUpdateDialog(
  BuildContext context, {
  required AppRelease release,
  required Prefs prefs,
}) async {
  final p = Theming.of(context);
  final skip = await showAppDialog<bool>(
    context,
    title: '发现新版本 v${release.version}',
    badge: DialogBadge.info,
    maxWidth: 560,
    body: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '当前版本 v$appVersion，最新版本 v${release.version}。',
          style: ui.copyWith(color: p.textDim, fontSize: 13, height: 1.55),
        ),
        if (release.notes.isNotEmpty) ...[
          const SizedBox(height: 10),
          Container(
            constraints: const BoxConstraints(maxHeight: 240),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: p.bg,
              border: Border.all(color: p.border),
              borderRadius: BorderRadius.circular(6),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                release.notes,
                style: ui.copyWith(color: p.textDim, fontSize: 12, height: 1.5),
              ),
            ),
          ),
        ],
      ],
    ),
    actions: [
      DialogButton(
        '跳过此版本',
        onTap: () => Navigator.of(context).pop(true),
      ),
      DialogButton(
        '稍后',
        onTap: () => Navigator.of(context).pop(false),
      ),
      DialogButton(
        '前往下载',
        kind: DialogButtonKind.primary,
        autofocus: true,
        onTap: () async {
          Navigator.of(context).pop(false);
          await openReleasePage();
        },
      ),
    ],
  );
  if (skip == true) await prefs.setSkippedVersion(release.version);
}
