/* Which data source the build gets.

   The macOS desktop build has dart:io and talks to the git CLI; the web build
   (flutter run -d chrome, for looking at the UI without Xcode) gets fixtures.
   Everything else imports this file and never knows which one it got. */

export 'git_types.dart';
export 'git_web.dart' if (dart.library.io) 'git_io.dart';
