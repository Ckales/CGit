/* The single data path: every Git call goes through cgit-core over
   flutter_rust_bridge.

   There used to be a conditional export here picking between a Dart-side git
   CLI wrapper and a browser fixture. Both are gone: they were second
   implementations of rules that already live in cgit-core, and keeping a
   parallel set of fixtures in step with 81 commands would have cost more than
   the Xcode-free preview was worth. `git log` has them if that changes. */

export 'git_frb.dart';
