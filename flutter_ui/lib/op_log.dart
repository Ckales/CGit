import 'dart:io';

/// 操作日志：状态栏的每条消息和每个 git 失败的原文，追加到
/// ~/Library/Logs/CGit/cgit.log，方便事后排查。默认关，设置 → 通用里打开。
///
/// Written synchronously: lines are short and rare (one per user action), and
/// an async write could land out of order with the next one.
class OpLog {
  static bool enabled = false;

  static final String dir = '${Platform.environment['HOME']}/Library/Logs/CGit';
  static String get path => '$dir/cgit.log';

  // ponytail: one rotation (cgit.log.1), enough for a project this size.
  static const _maxBytes = 5 * 1024 * 1024;

  static void info(String message) => _write('INFO', message);
  static void error(String message) => _write('ERROR', message);

  static void _write(String level, String message) {
    if (!enabled) return;
    try {
      final file = File(path);
      if (!file.existsSync()) {
        file.createSync(recursive: true);
      } else if (file.lengthSync() > _maxBytes) {
        file.renameSync('$path.1');
      }
      final line = '${DateTime.now().toIso8601String()} [$level] '
          '${redactUrlCredentials(message.trimRight())}\n';
      File(path).writeAsStringSync(line, mode: FileMode.append);
    } on FileSystemException catch (e) {
      // A log that cannot be written must not break the action it describes.
      stderr.writeln('写操作日志失败：$e');
    }
  }
}

/// git echoes remote URLs in its errors, and an HTTPS URL can carry
/// `user:token@`. Nothing credential-shaped goes to disk.
String redactUrlCredentials(String text) =>
    text.replaceAll(RegExp(r'://[^/\s@]+@'), '://<REDACTED>@');
