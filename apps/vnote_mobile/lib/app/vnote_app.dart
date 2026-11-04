// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../l10n/app_strings.dart';
import '../l10n/locale_settings.dart';
import 'adaptive_workspace.dart';
import '../features/share/share_inbox_panel.dart';

import '../features/editor/notebook_editor.dart';
import '../features/library/notebook_browser.dart';
import '../features/library/notebook_library_screen.dart';
import '../services/notebook_library.dart';
import '../services/notebook_workspace.dart';
import '../services/web_surface_platform.dart';

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

class _VNoteAppState extends State<VNoteApp> with WidgetsBindingObserver {
  bool _dark = false;
  late final WebSurfacePlatform _surfaces;
  late final LocaleSettings _localeSettings;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.library.setForeground(WidgetsBinding.instance.lifecycleState == null ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed);
    _surfaces = WebSurfacePlatform();
    _localeSettings = LocaleSettings();
    unawaited(_localeSettings.initialize());
    unawaited(widget.library.initialize());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _localeSettings.dispose();
    widget.library.dispose();
    unawaited(widget.library.shutdown().then((_) => _surfaces.shutdown()).catchError((Object _) {}));
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    widget.library.setForeground(state == AppLifecycleState.resumed);
  }

  @override
  Widget build(BuildContext context) => ProviderScope(
    overrides: [_libraryProvider.overrideWithValue(widget.library)],
    child: LocaleSettingsScope(
      settings: _localeSettings,
      child: AnimatedBuilder(
        animation: _localeSettings,
        builder: (context, _) => MaterialApp(
      title: 'VNote Mobile',
      locale: _localeSettings.locale,
      supportedLocales: AppStrings.supportedLocales,
      localizationsDelegates: const [
        AppStrings.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      localeResolutionCallback: (locale, supported) =>
          locale?.languageCode == 'zh' ? const Locale('zh', 'CN') : const Locale('en'),
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      highContrastTheme: _theme(Brightness.light, highContrast: true),
      highContrastDarkTheme: _theme(Brightness.dark, highContrast: true),
      themeMode: _dark ? ThemeMode.dark : ThemeMode.light,
      home: Consumer(
        builder: (context, ref, _) {
          final library = ref.watch(_libraryProvider);
          return ValueListenableBuilder<NotebookLibraryState>(
            valueListenable: library,
            builder: (context, libraryState, _) {
              final workspace = libraryState.workspace;
              if (workspace == null) {
                return AdaptiveWorkspace(
                  contextPane: _contextPane(context),
                  child: NotebookLibraryScreen(
                  key: ObjectKey(library),
                  library: library,
                  dark: _dark,
                  onThemeChanged: (dark) => setState(() => _dark = dark),
                  ),
                );
              }
              return ValueListenableBuilder<NotebookWorkspaceState>(
                key: ObjectKey(workspace),
                valueListenable: workspace,
                builder: (context, state, _) => AdaptiveWorkspace(
                  contextPane: _contextPane(context,
                    notebookName: state.directory?.notebookName ?? state.session?.value.note?.notebookName,
                    notePath: state.session?.value.note?.path,
                    editing: state.session != null),
                  child: state.session == null
                    ? NotebookBrowser(
                        key: ObjectKey(workspace),
                        workspace: workspace,
                        onShowInbox: () => showModalBottomSheet<void>(
                          context: context, isScrollControlled: true, useSafeArea: true,
                          builder: (context) => FractionallySizedBox(heightFactor: 0.9,
                            child: SingleChildScrollView(padding: EdgeInsets.only(
                              bottom: MediaQuery.viewInsetsOf(context).bottom),
                              child: ShareInboxPanel(library: library, showOperationErrors: true)))),
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
                        surfaces: _surfaces,
                        session: state.session!,
                        dark: _dark,
                        onThemeChanged: (dark) => setState(() => _dark = dark),
                      ),
                ),
              );
            },
          );
        },
      ),
    ),
      ),
    ),
  );

  Widget _contextPane(BuildContext context, {
    String? notebookName, String? notePath, bool editing = false,
  }) => Semantics(
    label: AppStrings.of(context).text('Read-only context'),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(AppStrings.of(context).text('Notebook context'),
        style: Theme.of(context).textTheme.titleLarge),
      if (notebookName != null) ...[
        const SizedBox(height: 16),
        SelectableText(notebookName),
      ],
      if (notePath != null) ...[
        const SizedBox(height: 16),
        Text(AppStrings.of(context).text('Current note')),
        SelectableText(notePath),
      ],
      const SizedBox(height: 16),
      Text(AppStrings.of(context).text(editing
        ? 'Close the note to browse folders. Unsaved source must be saved, retained as a draft, or explicitly discarded.'
        : 'Only one notebook owner is active. Incoming shares and retained transfers are reconciled before notebook writes.')),
    ]),
  );

  ThemeData _theme(Brightness brightness, {bool highContrast = false}) => ThemeData(
    colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo,
      brightness: brightness, contrastLevel: highContrast ? 1 : 0),
    useMaterial3: true,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    iconButtonTheme: const IconButtonThemeData(style: ButtonStyle(
      minimumSize: WidgetStatePropertyAll(Size(48, 48)))),
    textButtonTheme: const TextButtonThemeData(style: ButtonStyle(
      minimumSize: WidgetStatePropertyAll(Size(48, 48)))),
    filledButtonTheme: const FilledButtonThemeData(style: ButtonStyle(
      minimumSize: WidgetStatePropertyAll(Size(48, 48)))),
    outlinedButtonTheme: const OutlinedButtonThemeData(style: ButtonStyle(
      minimumSize: WidgetStatePropertyAll(Size(48, 48)))),
  );
}
