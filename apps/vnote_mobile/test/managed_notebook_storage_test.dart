// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vnote_mobile/services/managed_notebook_storage.dart';

Future<void> _link(String path, String target) async {
  if (Platform.isWindows) {
    final result = await Process.run('cmd', [
      '/c',
      'mklink',
      '/J',
      path.replaceAll('/', r'\'),
      target.replaceAll('/', r'\'),
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  } else {
    await Link(path).create(target);
  }
}

void main() {
  late Directory temp;
  late ManagedNotebookStorage storage;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('vnote-library-storage-');
    storage = ManagedNotebookStorage(
      app: '${temp.path}/app',
      local: '${temp.path}/local',
      root: Directory('${temp.path}/notebooks').absolute.uri.toFilePath(),
    );
    await Directory(storage.root).create();
  });
  tearDown(() async {
    // Remove owned links first, never walk their external targets during cleanup.
    await for (final entity in Directory(
      storage.root,
    ).list(followLinks: false)) {
      if (entity is Link) await entity.delete();
    }
    await temp.delete(recursive: true);
  });

  test(
    'discovery preserves legacy roots and allocation never creates a notebook',
    () async {
      final legacy = await Directory('${storage.root}/Personal').create();
      final marker = File('${legacy.path}/opaque.txt');
      await marker.writeAsString('untouched');
      await File('${storage.root}/loose.txt').writeAsString('not a notebook');
      final candidates = await storage.candidates();
      expect(candidates.single.label, 'Personal');
      expect(candidates.single.error, isNull);
      expect((await storage.existing(legacy.path)).notebook, legacy.path);
      final next = await storage.allocate();
      expect(
        await FileSystemEntity.identical(
          Directory(next.notebook).parent.path,
          storage.root,
        ),
        isTrue,
      );
      expect(
        Directory(next.notebook).uri.pathSegments
            .where((part) => part.isNotEmpty)
            .last,
        matches(RegExp(r'^nb-[0-9a-f]{32}$')),
      );
      expect(
        await FileSystemEntity.type(next.notebook, followLinks: false),
        FileSystemEntityType.notFound,
      );
      expect(await marker.readAsString(), 'untouched');
      expect(
        await File('${storage.root}/loose.txt').readAsString(),
        'not a notebook',
      );
    },
  );

  test(
    'links and escaped children are not accepted as notebook locations',
    () async {
      final outside = await Directory('${temp.path}/outside').create();
      await File('${outside.path}/keep.txt').writeAsString('external');
      final linked = '${storage.root}/linked';
      await _link(linked, outside.path);
      final candidates = await storage.candidates();
      expect(candidates.single.error, isNotNull);
      await expectLater(storage.existing(linked), throwsStateError);
      await expectLater(storage.existing(outside.path), throwsStateError);
      await expectLater(
        storage.existing('${storage.root}/../outside'),
        throwsStateError,
      );
      expect(await File('${outside.path}/keep.txt').readAsString(), 'external');
    },
  );

  test(
    'candidate cap fails rather than publishing an incomplete library',
    () async {
      for (var i = 0; i < ManagedNotebookStorage.maxNotebooks; i++) {
        await Directory('${storage.root}/entry-$i').create();
      }
      final complete = await storage.candidates();
      expect(complete.map((entry) => entry.label).toSet(), {
        for (var i = 0; i < ManagedNotebookStorage.maxNotebooks; i++)
          'entry-$i',
      });
      await Directory('${storage.root}/over-limit').create();
      await expectLater(storage.candidates(), throwsStateError);
    },
  );
}
