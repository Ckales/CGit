import 'package:cgit_flutter/git_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('splitImportPatch', () {
    test('splits Git diffs and preserves complete per-file text', () {
      const first = r'''diff --git "a/\347\233\256\345\275\225/a file.txt" "b/\347\233\256\345\275\225/a file.txt"
index 1234567..89abcde 100644
--- "a/目录/a file.txt"
+++ "b/目录/a file.txt"
@@ -1 +1 @@
-old
+diff --git this is ordinary hunk content
''';
      const second = '''diff --git a/bin.dat b/bin.dat
new file mode 100644
index 0000000..1234567
GIT binary patch
literal 3
abc
''';
      final result = splitImportPatch('$first$second');

      expect(result, hasLength(2));
      expect(result[0].path, '目录/a file.txt');
      expect(result[0].status, 'modified');
      expect(result[0].patch, first);
      expect(result[1].path, 'bin.dat');
      expect(result[1].status, 'added');
      expect(result[1].patch, second);
    });

    test('uses the new path and rename status for rename labels', () {
      const patch = '''diff --git "a/old name.txt" "b/new 名称.txt"
similarity index 90%
rename from old name.txt
rename to new 名称.txt
''';

      final result = splitImportPatch(patch);

      expect(result, hasLength(1));
      expect(result.single.path, 'old name.txt → new 名称.txt');
      expect(result.single.targetPath, 'new 名称.txt');
      expect(result.single.status, 'renamed');
      expect(result.single.patch, patch);
    });

    test('removes format-patch envelope and signature but keeps diff', () {
      const diff = '''diff --git a/a.txt b/a.txt
--- a/a.txt
+++ b/a.txt
@@ -1 +1 @@
-before
+after
''';
      const patch = '''From abcdef0123456789 Mon Sep 17 00:00:00 2001
From: Example <example@example.com>
Subject: [PATCH] change a

Commit message containing diff --git words.
---

$diff-- 
2.45.0
''';

      final result = splitImportPatch(patch);

      expect(result, hasLength(1));
      expect(result.single.path, 'a.txt');
      expect(result.single.status, 'modified');
      expect(result.single.patch, diff);
    });

    test('accepts a plain single-file unified diff', () {
      const patch = '''--- "old name.txt"
+++ "new name.txt"
@@ -1 +1 @@
-old
+new
''';

      final result = splitImportPatch(patch);

      expect(result, hasLength(1));
      expect(result.single.path, 'new name.txt');
      expect(result.single.status, 'modified');
      expect(result.single.patch, patch);
    });

    test('reports deleted paths and handles quoted unified labels', () {
      const patch = '''--- "a/old name.txt"
+++ /dev/null
@@ -1 +0,0 @@
-old
''';

      final result = splitImportPatch(patch);

      expect(result, hasLength(1));
      expect(result.single.path, 'old name.txt');
      expect(result.single.status, 'deleted');
      expect(result.single.patch, patch);
    });

    test('reports an unrecognized patch clearly in Chinese', () {
      expect(
        () => splitImportPatch('not a patch'),
        throwsA(isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('无法识别'),
        )),
      );
    });
  });
}
