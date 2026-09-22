import 'dart:convert';

import 'package:cgit_flutter/git_text.dart';
import 'package:flutter_test/flutter_test.dart';

/// The second half of the src/git-text.js port: conflict parsing, change
/// navigation, the AI endpoint, push/auth failure classification and the push
/// dialog's folder tree. Ported case for case from test/git-text.test.js.
const conflicted = 'top\n'
    '<<<<<<< HEAD\n'
    'mine\n'
    '||||||| base\n'
    'orig\n'
    '=======\n'
    'yours\n'
    '>>>>>>> other\n'
    'bottom';

const diff3 = 'one\n'
    '<<<<<<< ours\n'
    'ours\n'
    '||||||| base\n'
    'ANCESTOR\n'
    '=======\n'
    'theirs\n'
    '>>>>>>> theirs\n'
    'three';

final pushFiles = [
  'tests/test_openapi.py',
  'app/core/auth.py',
  'app/api/v1/openapi.py',
  'app/api/v1/__init__.py',
  'app/core/constants.py',
  'app/services/token_service.py',
  'app/utils/timeutil.py',
  'tests/test_token.py',
  'tests/conftest.py',
].map((p) => TreeFile(p, 'modified')).toList();

String _dump(List<ConflictBlock> blocks) => jsonEncode([
      for (final b in blocks)
        {
          'type': b.type.name,
          'lines': b.lines,
          'ours': b.ours,
          'base': b.base,
          'theirs': b.theirs,
        }
    ]);

void main() {
  group('conflict markers', () {
    test('splits context, ours, base and theirs', () {
      final parsed = parseConflicts(conflicted);
      expect(parsed.hasConflict, isTrue);
      expect(parsed.blocks.map((b) => b.type),
          [BlockType.ctx, BlockType.conflict, BlockType.ctx]);

      final c = parsed.blocks[1];
      expect(c.ours, ['mine']);
      expect(c.base, ['orig']);
      expect(c.theirs, ['yours']);

      // No marker line may survive into the parsed sides.
      expect(conflicted.contains('<<<<<<<'), isTrue);
      expect(_dump(parsed.blocks).contains('<<<<<<<'), isFalse);
    });

    test('leaves a clean file untouched', () {
      final parsed = parseConflicts('a\nb\n');
      expect(parsed.hasConflict, isFalse);
      expect(assembleConflict(parsed.blocks), 'a\nb\n');
    });

    test('assemble honours each block\'s resolution', () {
      String pick(String? res) {
        final blocks = parseConflicts(conflicted).blocks;
        blocks[1].resolution = res;
        return assembleConflict(blocks);
      }

      expect(pick('ours'), 'top\nmine\nbottom');
      expect(pick('theirs'), 'top\nyours\nbottom');
      expect(pick('both'), 'top\nmine\nyours\nbottom');
      expect(pick(null), 'top\nmine\nbottom',
          reason: 'unresolved defaults to ours');
      expect(pick('none'), 'top\nbottom',
          reason: 'both sides rejected drops the block');
    });

    test('assemble prefers hand-edited block text', () {
      final blocks = parseConflicts(conflicted).blocks;
      blocks[1].resolution = 'ours';
      blocks[1].edited = 'merged by hand\nsecond line';
      expect(
          assembleConflict(blocks), 'top\nmerged by hand\nsecond line\nbottom');

      blocks[0].edited = 'TOP';
      expect(
          assembleConflict(blocks), 'TOP\nmerged by hand\nsecond line\nbottom');
    });

    test('never writes the common ancestor into the result', () {
      final blocks = parseConflicts(diff3).blocks;
      expect(blocks[1].base, ['ANCESTOR'],
          reason: 'base is parsed for display');

      for (final res in ['ours', 'theirs', 'both', null]) {
        blocks[1].resolution = res;
        final out = assembleConflict(blocks);
        expect(out, isNot(contains('ANCESTOR')),
            reason: 'base leaked with $res');
        expect(out, isNot(contains('|||||||')),
            reason: 'marker leaked with $res');
      }
    });
  });

  group('change navigation', () {
    ChangeTarget step({
      required int blockIndex,
      required int navIndex,
      required int dir,
      int blockCount = 3,
      int navCount = 2,
    }) =>
        nextChangeTarget(
          blockIndex: blockIndex,
          blockCount: blockCount,
          navIndex: navIndex,
          navCount: navCount,
          dir: dir,
        );

    void expectTarget(ChangeTarget t, ChangeTargetKind kind, [int? index]) {
      expect(t.kind, kind);
      if (index != null) expect(t.index, index);
    }

    test('enters an unvisited file from the near end', () {
      expectTarget(
          step(blockIndex: -1, navIndex: 0, dir: 1), ChangeTargetKind.block, 0);
      expectTarget(step(blockIndex: -1, navIndex: 0, dir: -1),
          ChangeTargetKind.block, 2);
    });

    test('walks blocks inside the current file', () {
      expectTarget(
          step(blockIndex: 0, navIndex: 0, dir: 1), ChangeTargetKind.block, 1);
      expectTarget(
          step(blockIndex: 2, navIndex: 0, dir: -1), ChangeTargetKind.block, 1);
    });

    test('crosses into the adjacent file at either end', () {
      expectTarget(
          step(blockIndex: 2, navIndex: 0, dir: 1), ChangeTargetKind.file, 1);
      expectTarget(
          step(blockIndex: 0, navIndex: 1, dir: -1), ChangeTargetKind.file, 0);
    });

    test('stops at the very first and very last change', () {
      expectTarget(
          step(blockIndex: 2, navIndex: 1, dir: 1), ChangeTargetKind.none);
      expectTarget(
          step(blockIndex: 0, navIndex: 0, dir: -1), ChangeTargetKind.none);
    });

    test('skips straight to a file when the diff has no blocks', () {
      // A binary file or pure rename renders nothing to step through.
      expectTarget(
          step(blockIndex: -1, blockCount: 0, navIndex: 1, navCount: 3, dir: 1),
          ChangeTargetKind.file,
          2);
      expectTarget(
          step(
              blockIndex: -1, blockCount: 0, navIndex: 1, navCount: 3, dir: -1),
          ChangeTargetKind.file,
          0);
      // ...and reports nowhere-to-go rather than looping when it's the only file.
      expectTarget(
          step(blockIndex: -1, blockCount: 0, navIndex: 0, navCount: 1, dir: 1),
          ChangeTargetKind.none);
    });

    test('handles a single-block file without dead ends', () {
      expectTarget(
          step(blockIndex: -1, blockCount: 1, navIndex: 0, navCount: 1, dir: 1),
          ChangeTargetKind.block,
          0);
      expectTarget(
          step(blockIndex: 0, blockCount: 1, navIndex: 0, navCount: 1, dir: 1),
          ChangeTargetKind.none);
    });
  });

  group('AI endpoint', () {
    test('appends the chat path to a base url, once', () {
      expect(aiEndpoint('https://api.openai.com/v1'),
          'https://api.openai.com/v1/chat/completions');
      expect(aiEndpoint('https://api.openai.com/v1/'),
          'https://api.openai.com/v1/chat/completions');
      expect(aiEndpoint(' https://api.openai.com/v1/chat/completions '),
          'https://api.openai.com/v1/chat/completions');
    });
  });

  group('push and auth failures', () {
    test('a remote that moved ahead is recoverable', () {
      expect(isPushRejected(' ! [rejected]        main -> main (fetch first)'),
          isTrue);
      expect(
          isPushRejected('Updates were rejected because ... non-fast-forward'),
          isTrue);
    });

    test('a real failure does not trigger an update-and-retry', () {
      expect(isPushRejected('remote: Permission denied'), isFalse);
      expect(isPushRejected('fatal: Authentication failed'), isFalse);
    });

    test('GitHub 403 keeps the account the remote named', () {
      const stderr =
          'remote: Permission to Ckales/CGit.git denied to someuser.\n'
          'fatal: unable to access: The requested URL returned error: 403';
      final info = authFailureInfo(stderr)!;
      expect(info.kind, 'github-403');
      expect(info.username, 'someuser');
    });

    test('a plain 403 must not impersonate an auth error', () {
      expect(authFailureInfo('The requested URL returned error: 403'), isNull);
    });

    test('recognises the several ways git words a credential problem', () {
      expect(isAuthFailure('could not read Username for https://github.com'),
          isTrue);
      expect(isAuthFailure('fatal: Authentication failed for ...'), isTrue);
      expect(isAuthFailure('git@github.com: Permission denied (publickey).'),
          isTrue);
      expect(isAuthFailure('error: failed to push some refs'), isFalse);
    });

    test('a new token is saved first, otherwise the stored one is reused', () {
      expect(
        credentialAction(
            hasCredential: false, infoUsername: null, username: '', token: 'x'),
        'missing-username',
      );
      expect(
        credentialAction(
            hasCredential: false,
            infoUsername: null,
            username: 'me',
            token: 'tok'),
        'save-and-test',
      );
      expect(
        credentialAction(
            hasCredential: true, infoUsername: 'me', username: 'me', token: ''),
        'test',
      );
      expect(
        credentialAction(
            hasCredential: true,
            infoUsername: 'other',
            username: 'me',
            token: ''),
        'missing-token',
      );
    });
  });

  group('folder tree', () {
    test('groups files by folder and counts them', () {
      final root = pathTree(pushFiles);
      expect(root.count, 9);
      // Folders sort alphabetically, and each one knows its own total.
      expect(root.dirs.map((d) => [d.name, d.count]), [
        ['app', 6],
        ['tests', 3],
      ]);
      // Nothing sits loose at the root of this push.
      expect(root.files, isEmpty);
    });

    test('collapses single-child folder chains into one row', () {
      final app = pathTree(pushFiles).dirs.first;
      expect(
          app.dirs.map((d) => d.name), ['api/v1', 'core', 'services', 'utils']);
      expect(app.dirs.first.files.length, 2);
    });

    test('keeps root-level files and does not swallow the root', () {
      final root = pathTree([
        const TreeFile('README.md', 'new'),
        const TreeFile('src/a.js', 'new'),
      ]);
      expect(root.name, '');
      expect(root.files.map((f) => f.path), ['README.md']);
      expect(root.dirs.map((d) => d.name), ['src']);
    });

    test('can keep every folder level for an interactive tree', () {
      final app = pathTree(pushFiles, collapseSingleChild: false).dirs.first;
      // Uncollapsed, "api" and "v1" stay separate rows.
      expect(app.dirs.map((d) => d.name), ['api', 'core', 'services', 'utils']);
      expect(app.dirs.first.dirs.map((d) => d.name), ['v1']);
    });
  });
}
