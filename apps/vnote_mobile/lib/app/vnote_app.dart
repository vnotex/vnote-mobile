// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/editor/notebook_editor.dart';
import '../features/library/notebook_browser.dart';
import '../features/library/notebook_library_screen.dart';
import '../services/notebook_library.dart';
import '../services/notebook_workspace.dart';

// A dependency token, not a process-global notebook or native-core singleton.
final _libraryProvider = Provider<NotebookLibrary>(
  (ref) => throw StateError('NotebookLibrary must be constructor-injected.'),
);

/// Owns the injected notebook library for this application lifetime.
class VNoteApp extends StatefulWidget {
  const VNoteApp({required this.library, super.key});

  final NotebookLibrary library;

  @override
  State<VNoteApp> createState() => _VNoteAppState();
}

class _VNoteAppState extends State<VNoteApp> {
  bool _dark = false;

  @override
  void initState() {
    super.initState();
    unawaited(widget.library.initialize());
  }

  @override
  void dispose() {
    widget.library.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ProviderScope(
    overrides: [_libraryProvider.overrideWithValue(widget.library)],
    child: MaterialApp(
      title: 'VNote Mobile',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      themeMode: _dark ? ThemeMode.dark : ThemeMode.light,
      home: Consumer(
        builder: (context, ref, _) {
          final library = ref.watch(_libraryProvider);
          return ValueListenableBuilder<NotebookLibraryState>(
            valueListenable: library,
            builder: (context, libraryState, _) {
              final workspace = libraryState.workspace;
              if (workspace == null) {
                return NotebookLibraryScreen(
                  key: ObjectKey(library),
                  library: library,
                  dark: _dark,
                  onThemeChanged: (dark) => setState(() => _dark = dark),
                );
              }
              return ValueListenableBuilder<NotebookWorkspaceState>(
                key: ObjectKey(workspace),
                valueListenable: workspace,
                builder: (context, state, _) => state.session == null
                    ? NotebookBrowser(
                        key: ObjectKey(workspace),
                        workspace: workspace,
                        transferReserved: libraryState.transferReserved,
                        onImportFiles: (directory, kind, name) => library
                            .importFiles(workspace, directory, kind, name),
                        dark: _dark,
                        onThemeChanged: (dark) => setState(() => _dark = dark),
                        onShowNotebooks: () =>
                            unawaited(library.returnToLibrary(workspace)),
                      )
                    : NotebookEditor(
                        key: ObjectKey(state.session),
                        workspace: workspace,
                        library: library,
                        session: state.session!,
                        dark: _dark,
                        onThemeChanged: (dark) => setState(() => _dark = dark),
                      ),
              );
            },
          );
        },
      ),
    ),
  );
}
