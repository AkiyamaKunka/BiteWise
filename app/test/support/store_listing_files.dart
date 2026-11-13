/// The App Store listing's own files, for tests that read every one of
/// them: fastlane's `*.txt` under `ios/store/metadata/<locale>/`.
///
/// A checkout can hold other files beside them that git does not track:
/// Finder's .DS_Store (git-ignored), an editor's swap file
/// (.description.txt.swp), the ._ files macOS writes on FAT and network
/// volumes, and the description.txt.orig that git mergetool leaves after a
/// conflict. They are not the listing, and some are binary, so a test that
/// read them would fail on that checkout and pass on CI.
library;

import 'dart:io';

/// The listing files in [dir], and below it when [recursive]: each `*.txt`
/// whose name does not start with a dot.
List<File> storeListingFiles(Directory dir, {bool recursive = false}) => [
      for (final file in dir.listSync(recursive: recursive).whereType<File>())
        if (_isListingFile(file.uri.pathSegments.last)) file,
    ];

bool _isListingFile(String name) =>
    name.endsWith('.txt') && !name.startsWith('.');
