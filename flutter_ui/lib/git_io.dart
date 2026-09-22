import 'dart:io';

import 'git_text.dart';
import 'git_types.dart';

/* The live data layer. In the shipping app these calls cross the Tauri IPC seam
   into src-tauri/src/lib.rs, where gix serves the read paths and the git CLI
   serves anything touching the network, the index, the worktree, refs or
   history.

   ponytail: this port shells out to the git CLI directly so the UI comparison
   runs without a bridge layer. The real port keeps lib.rs as-is and exposes the
   same 80 commands through flutter_rust_bridge — a mechanical change to the
   #[tauri::command] wrappers, not to the gix logic underneath. */

/// Where the app starts looking when argv gives it nothing.
String get defaultRepoPath => Directory.current.path;

const _nul = '\u0000';
const _fieldSep = '\u001f';
const _recordSep = '\u001e';

class Git {
  Git(this.repo);
  final String repo;

  Future<String> _run(List<String> args) async {
    final r = await Process.run('git', args, workingDirectory: repo);
    if (r.exitCode != 0) {
      final err = (r.stderr as String).trim();
      throw GitError(err.isEmpty ? 'git ${args.first} 失败' : err);
    }
    return r.stdout as String;
  }

  Future<String> currentBranch() async {
    final out = await _run(['rev-parse', '--abbrev-ref', 'HEAD']);
    return out.trim();
  }

  /// Porcelain v1 status. The two status columns are index and worktree, so one
  /// path can produce two rows — staged and unstaged — which is exactly what the
  /// changes list shows.
  Future<List<FileStatus>> status() async {
    final out = await _run(['status', '--porcelain=v1', '-z', '-uall']);
    final entries = out.split(_nul).where((s) => s.isNotEmpty).toList();
    final files = <FileStatus>[];

    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      if (entry.length < 4) continue;
      final index = entry[0];
      final tree = entry[1];
      final path = entry.substring(3);

      // A rename carries its source path in the following NUL-separated field.
      if (index == 'R' || index == 'C') {
        if (i + 1 < entries.length) i++;
      }

      if (index != ' ' && index != '?') {
        files.add(FileStatus(path, index, true));
      }
      if (tree != ' ') {
        files.add(FileStatus(path, tree, false));
      }
    }
    return files;
  }

  Future<List<BranchInfo>> branches() async {
    final out = await _run(['branch', '--format=%(refname:short)%09%(HEAD)']);
    final list = <BranchInfo>[];
    for (final line in out.split('\n')) {
      if (line.trim().isEmpty) continue;
      final parts = line.split('\t');
      list.add(BranchInfo(parts[0], parts.length > 1 && parts[1] == '*'));
    }
    return list;
  }

  Future<List<String>> tags() async {
    final out = await _run(['tag', '--sort=-creatordate']);
    return out.split('\n').where((s) => s.trim().isNotEmpty).toList();
  }

  Future<List<String>> remotes() async {
    final out = await _run(['remote']);
    return out.split('\n').where((s) => s.trim().isNotEmpty).toList();
  }

  /// Topologically-sorted commits with parent ids and ref decorations, matching
  /// what `get_graph` returns from lib.rs so layoutGraph consumes it unchanged.
  Future<List<GraphCommit>> graph({int limit = 200}) async {
    // Unit separator between fields, record separator between records: neither
    // appears in commit text, which a comma or a tab cannot promise.
    const fmt = '--pretty=format:%H%x1f%s%x1f%an%x1f%at%x1f%P%x1f%D%x1e';
    final out = await _run(['log', '--all', '--topo-order', '-n', '$limit', fmt]);

    final commits = <GraphCommit>[];
    for (final record in out.split(_recordSep)) {
      final line = record.replaceFirst(RegExp(r'^\n'), '');
      if (line.trim().isEmpty) continue;
      final f = line.split(_fieldSep);
      if (f.length < 6) continue;
      commits.add(GraphCommit(
        id: f[0],
        summary: f[1],
        author: f[2],
        time: int.tryParse(f[3]) ?? 0,
        parents: f[4].split(' ').where((s) => s.isNotEmpty).toList(),
        refs: f[5]
            .split(', ')
            .where((s) => s.isNotEmpty)
            .map((s) => s.replaceFirst('HEAD -> ', ''))
            .toList(),
      ));
    }
    return commits;
  }

  /// Split `git diff [--cached] -- <file>` into header and hunks, verbatim, so
  /// the text round-trips back into `git apply` unchanged.
  Future<Hunks> hunks(String file, {required bool staged}) async {
    final args = ['diff', if (staged) '--cached', '--', file];
    final patch = await _run(args);
    final split = splitPatchText(patch);
    return Hunks(split.header, split.hunks);
  }

  Future<List<String>> commitFiles(String oid) async {
    final out = await _run(['show', '--name-only', '--pretty=format:', oid]);
    return out.split('\n').where((s) => s.trim().isNotEmpty).toList();
  }

  Future<Hunks> commitDiff(String oid, String file) async {
    final patch = await _run(['show', '--format=', oid, '--', file]);
    final split = splitPatchText(patch);
    return Hunks(split.header, split.hunks);
  }

  Future<void> stage(String file) => _run(['add', '--', file]);
  Future<void> unstage(String file) => _run(['restore', '--staged', '--', file]);

  /// Apply one rebuilt hunk to the index — the line-level staging path.
  /// `--cached` keeps the worktree untouched; `--reverse` turns it into unstage.
  Future<void> applyPatch(String patch, {required bool reverse}) async {
    final p = await Process.start(
      'git',
      ['apply', '--cached', '--unidiff-zero', if (reverse) '--reverse', '-'],
      workingDirectory: repo,
    );
    p.stdin.write(patch);
    await p.stdin.close();
    final err = await p.stderr.transform(const SystemEncoding().decoder).join();
    if (await p.exitCode != 0) {
      throw GitError(err.trim().isEmpty ? 'git apply 失败' : err.trim());
    }
  }

  Future<void> commit(String message) async {
    final p = await Process.start('git', ['commit', '-F', '-'], workingDirectory: repo);
    p.stdin.write(message);
    await p.stdin.close();
    final err = await p.stderr.transform(const SystemEncoding().decoder).join();
    if (await p.exitCode != 0) {
      throw GitError(err.trim().isEmpty ? 'git commit 失败' : err.trim());
    }
  }

  static Future<String?> discoverRoot(String start) async {
    final r = await Process.run('git', ['rev-parse', '--show-toplevel'],
        workingDirectory: start);
    if (r.exitCode != 0) return null;
    final root = (r.stdout as String).trim();
    return root.isEmpty ? null : root;
  }
}
