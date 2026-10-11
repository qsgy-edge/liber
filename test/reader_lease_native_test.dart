import 'dart:io';

import 'package:fjs/fjs.dart' show TextEngineError_Io;
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/local/library_access.dart';
import 'package:liber/local/reader_engine.dart';
import 'package:liber/source/native_library.dart';

import 'native_library.dart';
import 'temp_directory.dart';

void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);

  test(
    'native reader resolves a fresh lease for each index and bounded read',
    () async {
      final scratch = await Directory.systemTemp.createTemp(
        'liber-reader-lease-',
      );
      try {
        final file = File('${scratch.path}/book.txt');
        const content = '第一章 新版\n正文位置在书库内\n第二章 继续\n之后的正文';
        await file.writeAsString(content);
        var acquired = 0;
        var released = 0;
        final engine = NativeReaderEngine(
          acquireRead: () async {
            acquired++;
            return LibraryReadLease(
              path: file.path,
              onRelease: () async {
                released++;
              },
            );
          },
        );
        final index = await engine.index('content://stale-original-reference');
        expect(index.codeUnitLength, content.length);
        expect(acquired, 1);
        expect(released, 1);
        final window = await engine.readWindow(
          path: 'content://stale-original-reference',
          encoding: index.encoding,
          textOffset: 4,
          maxCodeUnits: 12,
        );
        expect(window.text, content.substring(4, 16));
        expect(acquired, 2);
        expect(released, 2);
        expect(await file.readAsString(), content);
      } finally {
        await deleteTempDirectory(scratch);
      }
    },
  );

  test(
    'native reader releases the granted resource after an asynchronous IO failure',
    () async {
      final scratch = await Directory.systemTemp.createTemp(
        'liber-reader-lease-error-',
      );
      try {
        var released = 0;
        final engine = NativeReaderEngine(
          acquireRead: () async => LibraryReadLease(
            path: '${scratch.path}/missing.txt',
            onRelease: () async {
              released++;
            },
          ),
        );
        await expectLater(
          engine.index('ignored-old-path'),
          throwsA(isA<TextEngineError_Io>()),
        );
        expect(released, 1);
        await expectLater(
          engine.readWindow(
            path: 'ignored-old-path',
            encoding: 'UTF-8',
            textOffset: 0,
            maxCodeUnits: 10,
          ),
          throwsA(isA<TextEngineError_Io>()),
        );
        expect(released, 2);
      } finally {
        await deleteTempDirectory(scratch);
      }
    },
  );
}
