// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/editor/notebook_editor.dart';
import '../features/library/notebook_browser.dart';
import '../services/notebook_workspace.dart';

// A dependency token, not a process-global notebook or native-core singleton.
final _workspaceProvider = Provider<NotebookWorkspace>(
  (ref) => throw StateError('NotebookWorkspace must be constructor-injected.'),
);

/// Owns the injected workspace for this application lifetime.
class VNoteApp extends StatefulWidget {
  const VNoteApp({required this.workspace, super.key});

  final NotebookWorkspace workspace;

  @override
  State<VNoteApp> createState() => _VNoteAppState();
}

class _VNoteAppState extends State<VNoteApp> {
  bool _dark = false;

  @override
  void initState() {
    super.initState();
    unawaited(widget.workspace.initialize());
  }

  @override
  void dispose() {
    widget.workspace.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ProviderScope(
    overrides: [_workspaceProvider.overrideWithValue(widget.workspace)],
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
          final workspace = ref.watch(_workspaceProvider);
          return ValueListenableBuilder<NotebookWorkspaceState>(
            valueListenable: workspace,
            builder: (context, state, _) => state.session == null
                ? NotebookBrowser(
                    workspace: workspace,
                    dark: _dark,
                    onThemeChanged: (dark) => setState(() => _dark = dark),
                  )
                : NotebookEditor(
                    key: ObjectKey(state.session),
                    workspace: workspace,
                    session: state.session!,
                    dark: _dark,
                    onThemeChanged: (dark) => setState(() => _dark = dark),
                  ),
          );
        },
      ),
    ),
  );
}
