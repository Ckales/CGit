/* Shapes shared by both data sources. They mirror the structs
   src-tauri/src/lib.rs already serializes, so the Tauri build, this port's
   CLI build and the web fixture build all speak the same language. */

class FileStatus {
  const FileStatus(this.path, this.status, this.staged);
  final String path;
  final String status;
  final bool staged;
}

class BranchInfo {
  const BranchInfo(this.name, this.isCurrent);
  final String name;
  final bool isCurrent;
}

class Hunks {
  const Hunks(this.header, this.hunks);
  final String header;
  final List<String> hunks;
}

class GitError implements Exception {
  GitError(this.message);
  final String message;
  @override
  String toString() => message;
}
