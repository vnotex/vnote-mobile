// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vxcore_bridge/vxcore_bridge.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../l10n/app_strings.dart';
import '../../l10n/locale_settings.dart';
import '../../app/adaptive_workspace.dart';
import '../../services/editor_session.dart';
import '../../services/managed_notebook_storage.dart';
import '../../services/notebook_session.dart';
import '../../services/notebook_workspace.dart';
import '../../services/notebook_library.dart';
import '../../services/preview_session.dart';
import '../../services/web_surface_platform.dart';
import '../../services/transfer_worker.dart' show runPreviewStore;
import '../preview/notebook_preview.dart';
import '../resources/resource_panel.dart';
import '../about/license_sheet.dart';
import '../sync/notebook_sync_panel.dart';
import '../../services/notebook_sync.dart';

class NotebookEditor extends StatefulWidget {
  const NotebookEditor({
    required this.workspace,
    required this.session,
    required this.library,
    required this.surfaces,
    required this.dark,
    required this.onThemeChanged,
    super.key,
  });
  final NotebookWorkspace workspace;
  final NotebookSession session;
  final NotebookLibrary library;
  final WebSurfacePlatform surfaces;
  final bool dark;
  final ValueChanged<bool> onThemeChanged;
  @override
  State<NotebookEditor> createState() => _NotebookEditorState();
}

class _NotebookEditorState extends State<NotebookEditor> {
  late final NotebookSession _notebook;
  late final EditorSend _transport = _send;
  EditorSession? _boundEditor;
  int _webEpoch = 0;
  WebViewController? _webView;
  EditorSurfaceBinding? _binding;
  String? _surfaceId;
  bool _navigationAdmitted = false;
  bool _pageStarted = false;
  bool _loadSent = false;
  bool _showingExitDialog = false;
  bool _disposed = false;
  bool _recoveringView = false;
  Future<void> _outbound = Future<void>.value();
  int _queuedMessages = 0;
  SurfacePreferences? _lastPreferences;
  String? _lastLocale;
  PreviewSession? _preview;
  bool _showPreview = false;
  Timer? _previewTimer;
  int _previewRequestedRevision = -1;
  String? _previewRoot;
  String? _initialPreviewFragment;

  @override
  void initState() {
    super.initState();
    _notebook = widget.session;
    _notebook.addListener(_notebookChanged);
    _notebookChanged();
  }

  SurfacePreferences _preferences() {
    final media = MediaQuery.of(context);
    return SurfacePreferences(
      dark: widget.dark,
      highContrast: media.highContrast,
      fontScale: (media.textScaler.scale(16) / 16).clamp(0.75, 3).toDouble(),
      reducedMotion: media.disableAnimations,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _preferencesChanged();
  }

  @override
  void didUpdateWidget(covariant NotebookEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    _preferencesChanged();
  }

  void _preferencesChanged() {
    if (_disposed) return;
    final next = _preferences();
    final locale = Localizations.localeOf(context).languageCode == 'zh' ? 'zh' : 'en';
    if (_lastPreferences == next && _lastLocale == locale) return;
    _lastPreferences = next;
    _lastLocale = locale;
    _sendPreferences();
    final preview = _preview;
    if (preview != null && _showPreview) {
      unawaited(preview.updatePreferences(next).catchError((Object error) => _showError(error)));
      _schedulePreview();
    }
  }

  void _sendPreferences() {
    final editor = _boundEditor;
    final preferences = _lastPreferences;
    if (editor == null || preferences == null) return;
    final message = editor.preferences(
      locale: _lastLocale ?? 'en',
      dark: preferences.dark,
      highContrast: preferences.highContrast,
      fontScale: preferences.fontScale,
      reducedMotion: preferences.reducedMotion,
    );
    if (message != null) _send(message);
  }

  void _notebookChanged() {
    if (_disposed || identical(_boundEditor, _notebook.value.editor)) return;
    _notebook.unbindTransport(_transport);
    _boundEditor?.removeListener(_sourceChanged);
    _boundEditor = _notebook.value.editor;
    _boundEditor?.addListener(_sourceChanged);
    _previewTimer?.cancel();
    final previousPreview = _preview;
    _preview = null;
    _showPreview = false;
    if (previousPreview != null) {
      unawaited(previousPreview.close().whenComplete(previousPreview.dispose).catchError((Object _) {}));
    }
    final previousSurface = _surfaceId;
    _surfaceId = null;
    _binding = null;
    _webView = null;
    _navigationAdmitted = _pageStarted = _loadSent = false;
    final epoch = ++_webEpoch;
    final editor = _boundEditor;
    if (previousSurface != null) {
      unawaited(widget.surfaces.disposeEditor(previousSurface).catchError((Object _) {}));
    }
    if (editor != null && !_notebook.value.restartRequired) unawaited(_initializeWebView(editor, epoch));
  }

  bool _current(EditorSession editor, int epoch) =>
      !_disposed && epoch == _webEpoch && identical(editor, _boundEditor);

  Future<void> _initializeWebView(EditorSession editor, int epoch) async {
    final surfaceId = WebSurfacePlatform.newSurfaceId();
    _surfaceId = surfaceId;
    try {
      final controller = WebViewController();
      _webView = controller;
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.addJavaScriptChannel('VNoteEditor', onMessageReceived: (message) {
        if (!_current(editor, epoch)) return;
        final wasReady = editor.value.ready;
        final reply = editor.receive(message.message);
        if (reply != null) _send(reply);
        if (!wasReady && editor.value.ready) {
          _notebook.bindTransport(_transport);
          _sendPreferences();
          _initialPreviewFragment = widget.workspace.takePreviewFragment(_notebook);
          if (_initialPreviewFragment?.isNotEmpty == true) unawaited(_openPreview());
        }
      });
      await controller.setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (request) {
          if (!_current(editor, epoch) || !request.isMainFrame ||
              _navigationAdmitted || _pageStarted || request.url != _binding?.entryUrl) {
            return NavigationDecision.prevent;
          }
          _navigationAdmitted = true;
          return NavigationDecision.navigate;
        },
        onPageStarted: (url) {
          if (!_current(editor, epoch)) return;
          if (_pageStarted || url != _binding?.entryUrl) {
            unawaited(_recoverLostView(editor, epoch));
            return;
          }
          _pageStarted = true;
        },
        onPageFinished: (url) {
          if (!_current(editor, epoch)) return;
          if (url != _binding?.entryUrl || _loadSent) return;
          _loadSent = true;
          final load = editor.beginLoad();
          if (load != null) _send(load);
        },
        onWebResourceError: (error) {
          if (_current(editor, epoch) && error.isForMainFrame != false) {
            _notebook.unbindTransport(_transport);
            editor.reportTransportError('The secure editor view failed. Received source and durable drafts are retained.');
          }
        },
      ));
      if (!_current(editor, epoch)) return;
      widget.surfaces.listen(surfaceId, (event) {
        if (_current(editor, epoch) && event.kind == SurfaceEventKind.editorLost) {
          unawaited(_recoverLostView(editor, epoch));
        }
      });
      final binding = await widget.surfaces.configureEditor(surfaceId, controller);
      if (!_current(editor, epoch)) return;
      _binding = binding;
      setState(() {});
      await widget.surfaces.loadEditor(binding);
    } on Object catch (error) {
      if (_current(editor, epoch)) {
        _notebook.unbindTransport(_transport);
        editor.reportTransportError(_describe(error));
        setState(() {});
      }
    }
  }

  Future<void> _recoverLostView(EditorSession editor, int epoch) async {
    if (!_current(editor, epoch) || _recoveringView || _notebook.value.restartRequired) return;
    _recoveringView = true;
    _notebook.unbindTransport(_transport);
    try {
      await _closePreview();
      await _notebook.recoverWebView();
    } on Object catch (error) {
      if (!_disposed) editor.reportTransportError(_describe(error));
    } finally {
      _recoveringView = false;
    }
  }

  void _send(Map<String, Object?> message) {
    final editor = _boundEditor;
    final controller = _webView;
    if (_disposed || editor == null || controller == null || message['generation'] != editor.generation) return;
    if (_queuedMessages >= 32) {
      editor.reportTransportError('The editor transport queue is full. Source and drafts are retained.');
      return;
    }
    _queuedMessages++;
    final literal = jsonEncode(message);
    final epoch = _webEpoch;
    _outbound = _outbound.then((_) async {
      try {
        if (_current(editor, epoch)) await controller.runJavaScript('window.vnoteEditor.receive($literal);');
      } on Object {
        if (_current(editor, epoch)) {
          _notebook.unbindTransport(_transport);
          editor.reportTransportError('Editor transport failed. Received source and durable drafts are retained.');
        }
      } finally { _queuedMessages--; }
    });
  }

  void _command(String command) {
    final message = _boundEditor?.command(command);
    if (message != null) _send(message);
  }

  Future<void> _format(String action) async {
    final editor = _boundEditor;
    if (editor == null) return;
    String? destination;
    if (action == 'link') {
      final controller = TextEditingController();
      try {
        destination = await showDialog<String>(context: context, builder: (context) => AlertDialog(scrollable: true, 
          title: Text(AppStrings.of(context).text('Link destination')),
          content: TextField(controller: controller, autofocus: true, autocorrect: false,
            maxLength: 2048, decoration: InputDecoration(hintText: AppStrings.of(context).text('Relative note, #heading, or HTTPS URL'))),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text(AppStrings.of(context).text('Cancel'))),
            FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: Text(AppStrings.of(context).text('Insert link'))),
          ],
        ));
      } finally { controller.dispose(); }
      if (destination == null || destination.isEmpty) return;
    }
    if (_disposed || !identical(editor, _boundEditor)) return;
    try {
      final heading = action.startsWith('heading-') ? int.parse(action.substring(8)) : null;
      await editor.format(_transport, EditorFormat(heading == null ? action : 'heading',
          level: heading, destination: destination));
    } on Object catch (error) { _showError(error); }
  }

  void _sourceChanged() {
    final editor = _boundEditor;
    if (editor != null && _preview != null && editor.value.revision != _previewRequestedRevision) {
      _schedulePreview();
    }
  }

  void _schedulePreview() {
    final editor = _boundEditor;
    final preview = _preview;
    if (editor == null || preview == null || preview.retiring || _disposed) return;
    _previewRequestedRevision = editor.value.revision;
    _previewTimer?.cancel();
    _previewTimer = Timer(const Duration(milliseconds: 250), () {
      if (_disposed || !identical(preview, _preview)) return;
      unawaited(preview.request(_preferences()).catchError((Object error) {
        _showError(error);
        return false;
      }));
    });
  }

  static Future<String> _obtainPreviewRoot() async {
    final storage = await ManagedNotebookStorage.obtain();
    final root = await storage.obtainPreviewRoot();
    final retired = await runPreviewStore({'op': 'retirePreviousProcess', 'previewRoot': root});
    if (retired['unrecognized'] != 0) {
      throw StateError('Unrecognized preview staging was retained. Source editing and export remain available.');
    }
    return root;
  }

  Future<void> _openPreview() async {
    if (_preview != null || _boundEditor?.value.ready != true || _notebook.value.note?.editorType != CoreEditorType.markdown) return;
    final editor = _boundEditor!;
    late final PreviewSession preview;
    preview = PreviewSession(
      platform: widget.surfaces,
      capture: (request) => _notebook.withPreview((core, source) async {
        request.check();
        if (!identical(editor, _boundEditor) || source.generation != editor.generation) {
          throw StateError('The preview source session changed.');
        }
        final root = _previewRoot ??= await _obtainPreviewRoot();
        request.check();
        request.onCancel = core.cancelPreview;
        try {
          return await core.preparePreview(previewsRoot: root, previewId: request.previewId,
            renderId: request.renderId, token: source.generation, revision: source.revision, source: source.text);
        } finally { request.onCancel = null; }
      }),
      isCurrent: (snapshot) => !_disposed && identical(editor, _boundEditor) && snapshot.token == editor.generation,
      onPrepared: () {
        if (!_disposed && identical(preview, _preview)) setState(() => _showPreview = true);
      },
      onNavigate: _navigatePreview,
    );
    _preview = preview;
    _previewRequestedRevision = editor.value.revision;
    setState(() {});
    try {
      final rendered = await preview.request(_preferences());
      final fragment = _initialPreviewFragment;
      if (rendered && fragment != null && identical(preview, _preview) && preview.value.snapshot != null) {
        await widget.surfaces.fragment(preview.surfaceId, preview.value.snapshot!.renderId, fragment);
        _initialPreviewFragment = null;
      }
    } on Object catch (error) { _showError(error); }
  }

  Future<void> _closePreview() async {
    _previewTimer?.cancel();
    final preview = _preview;
    if (!_disposed) setState(() => _showPreview = false);
    if (preview != null) {
      try {
        await preview.close();
        if (identical(_preview, preview)) {
          if (_disposed) { _preview = null; }
          else { setState(() => _preview = null); }
        }
        preview.dispose();
      } on Object catch (error) {
        _showError(error);
        rethrow;
      }
    }
  }

  Future<void> _refreshPreview() async {
    try { await _closePreview(); await _openPreview(); }
    on Object catch (error) { _showError(error); }
  }

  Future<void> _navigatePreview(CorePreviewSnapshot snapshot, CorePreviewNavigation target) async {
    final preview = _preview;
    if (preview == null || !preview.isCurrent(snapshot)) return;
    final detail = switch (target.kind) {
      CorePreviewNavigationKind.external => AppStrings.of(context).text('{value}Open {origin} in the system browser?', {'value': (target.insecure ? AppStrings.of(context).text('Unencrypted HTTP link. ') : '').toString(), 'origin': (target.origin).toString()}),
      CorePreviewNavigationKind.note => AppStrings.of(context).text('Open the linked note? Current input will be kept as a durable draft first.'),
      CorePreviewNavigationKind.export => AppStrings.of(context).text('Export a copy of this attachment? Another application or provider will receive its bytes.'),
    };
    final approved = await showDialog<bool>(context: context, builder: (context) => AlertDialog(scrollable: true, 
      title: Text(AppStrings.of(context).text('Follow preview link?')),
      content: Text(AppStrings.of(context).message(detail)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(AppStrings.of(context).text('Cancel'))),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(AppStrings.of(context).text('Continue'))),
      ],
    ));
    if (approved != true || _disposed || !identical(preview, _preview) || !preview.isCurrent(snapshot)) return;
    switch (target.kind) {
      case CorePreviewNavigationKind.external:
        await widget.surfaces.openExternal(Uri.parse(target.url!));
      case CorePreviewNavigationKind.export:
        await widget.library.exportPreview(widget.workspace, _notebook, snapshot, target.fileHandle!);
      case CorePreviewNavigationKind.note:
        if (target.notebookId != widget.workspace.notebookId) throw StateError('The linked notebook is not the selected notebook.');
        if (target.nodeId == _notebook.value.note?.nodeId) {
          if (target.fragment?.isNotEmpty == true) {
            await widget.surfaces.fragment(preview.surfaceId, snapshot.renderId, target.fragment!);
          }
          return;
        }
        await _closePreview();
        if (await widget.workspace.returnToBrowser(_notebook, NotebookDisposition.retain, _transport)) {
          await widget.workspace.openPreviewTarget(target.nodeId!, fragment: target.fragment);
        }
    }
  }

  Future<void> _showResources() async {
    final editor = _boundEditor;
    if (editor == null || _notebook.value.busy) return;
    await showModalBottomSheet<void>(context: context, isScrollControlled: true, useSafeArea: true,
      builder: (context) => FractionallySizedBox(heightFactor: 0.9,
        child: Padding(padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
          child: ResourcePanel(library: widget.library, workspace: widget.workspace,
            session: _notebook, editor: editor, send: _transport))));
  }

  Future<void> _copyReceivedText() async {
    try { await Clipboard.setData(ClipboardData(text: _boundEditor?.value.text ?? '')); }
    on Object catch (error) { _showError(error); }
  }

  Future<void> _recoverView() async {
    final editor = _boundEditor;
    if (editor == null || _recoveringView || _notebook.value.restartRequired) return;
    try {
      if (_loadSent && !_notebook.canRecoverQuiescedView) {
        final candidate = await editor.requestResync(_transport);
        if (_disposed || !mounted || !identical(editor, _boundEditor)) return;
        if (candidate.text == editor.value.text && candidate.revision == editor.value.revision) {
          await editor.resumeResync(_transport);
          _notebook.bindTransport(_transport);
          return;
        }
        final useView = await showDialog<bool>(context: context, builder: (context) => AlertDialog(scrollable: true, 
          title: Text(AppStrings.of(context).text('Two source versions are retained')),
          content: Text(AppStrings.of(context).text('The live editor differs from the received mirror. Choose which source to checkpoint into a new editor session; the other version remains recovery evidence.')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text(AppStrings.of(context).text('Cancel'))),
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(AppStrings.of(context).text('Use received source'))),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(AppStrings.of(context).text('Use editor source'))),
          ],
        ));
        if (useView == null || _disposed || !identical(editor, _boundEditor)) return;
        await _closePreview();
        _notebook.unbindTransport(_transport);
        await _notebook.resolveResync(useViewSource: useView);
      } else {
        await _recoverLostView(editor, _webEpoch);
      }
    } on Object catch (error) { _showError(error); }
  }

  Future<void> _requestExit() => _requestBarrier(reopen: false);
  Future<void> _requestBarrier({required bool reopen}) async {
    if (_showingExitDialog || _notebook.value.restartRequired || _notebook.value.transitioning || widget.workspace.value.busy) return;
    _showingExitDialog = true;
    final disposition = await showDialog<NotebookDisposition>(context: context, builder: (context) => AlertDialog(scrollable: true, 
      title: Text(reopen ? AppStrings.of(context).text('Reopen from disk?') : AppStrings.of(context).text('Return to notebook?')),
      content: Text(AppStrings.of(context).text('Finish composition and save the exact final revision, or keep it as a durable draft without writing the notebook. Explicit discard removes unwritten source only after confirmation.')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, NotebookDisposition.cancel), child: Text(AppStrings.of(context).text('Cancel'))),
        TextButton(onPressed: () => Navigator.pop(context, NotebookDisposition.discard), child: Text(AppStrings.of(context).text('Discard'))),
        TextButton(onPressed: _boundEditor?.canFlushSource == true
            ? () => Navigator.pop(context, NotebookDisposition.retain) : null, child: Text(AppStrings.of(context).text('Keep draft'))),
        FilledButton(onPressed: _boundEditor?.canFlushSource == true
            ? () => Navigator.pop(context, NotebookDisposition.write) : null, child: Text(AppStrings.of(context).text('Save and close'))),
      ],
    ));
    _showingExitDialog = false;
    if (_disposed || disposition == null || disposition == NotebookDisposition.cancel) return;
    try {
      await _closePreview();
      if (reopen) { await _notebook.reopen(disposition, _transport); }
      else { await widget.workspace.returnToBrowser(_notebook, disposition, _transport); }
    } on Object catch (error) { _showError(error); }
  }

  static String _describe(Object error) => error is StateError ? error.message.toString()
      : error is CoreException ? 'Core error ${error.code}: ${error.message}'
      : error.toString();
  void _showError(Object error) {
    if (!_disposed && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppStrings.of(context).message(_describe(error)))));
  }

  @override
  void dispose() {
    _disposed = true;
    _webEpoch++;
    _previewTimer?.cancel();
    _notebook.unbindTransport(_transport);
    _boundEditor?.removeListener(_sourceChanged);
    _notebook.removeListener(_notebookChanged);
    final preview = _preview;
    _preview = null;
    if (preview != null) unawaited(preview.close().whenComplete(preview.dispose).catchError((Object _) {}));
    final surface = _surfaceId;
    if (surface != null) unawaited(widget.surfaces.disposeEditor(surface).catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<NotebookSessionState>(
    valueListenable: _notebook,
    builder: (context, state, _) {
      final editor = state.editor?.value;
      final enabled = !state.restartRequired && editor?.ready == true && editor?.closing != true && editor?.quiesced != true;
      final markdown = state.note?.editorType == CoreEditorType.markdown;
      final error = state.restartRequired ? NotebookSession.ownerRestartRequiredMessage
        : state.syncError ?? state.durabilityError ?? state.error ?? editor?.error;
      final saved = editor != null && !state.dirty && !state.recoveryRequired &&
          state.durabilityError == null && state.error == null && editor.locallySaved;
      return PopScope<Object?>(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) { if (!didPop && !state.restartRequired) unawaited(_showPreview ? _closePreview() : _requestExit()); },
        child: Scaffold(
          resizeToAvoidBottomInset: true,
          appBar: AppBar(
            title: Text(state.note == null ? AppStrings.of(context).text('Note') : '${state.note!.notebookName} / ${state.note!.path}'),
            actions: [
              const LanguageMenu(),
              SizedBox(width: 144, child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
              IconButton(tooltip: AppStrings.of(context).text('Attachments and images'), onPressed: state.note != null && !state.busy && !state.syncBusy ? _showResources : null, icon: const Icon(Icons.attach_file)),
              IconButton(tooltip: AppStrings.of(context).text('WebDAV synchronization'), icon: const Icon(Icons.sync), onPressed: state.restartRequired ? null : () => showNotebookSyncPanel(context, widget.workspace.synchronization)),
              IconButton(tooltip: AppStrings.of(context).text('Legal notices'), icon: const Icon(Icons.info_outline), onPressed: () => showNotebookLicenses(context, _notebook.nativeNotices)),
              ]))),
              if (!state.restartRequired) IconButton(tooltip: AppStrings.of(context).text('Return to notebook'), onPressed: state.transitioning ? null : _requestExit, icon: const Icon(Icons.close)),
            ],
          ),
          body: SafeArea(child: LayoutBuilder(builder: (context, constraints) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ConstrainedBox(constraints: BoxConstraints(maxHeight: constraints.maxHeight * 0.5),
                child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (state.busy) const LinearProgressIndicator(),
              ValueListenableBuilder<NotebookSyncState>(valueListenable: widget.workspace.synchronization,
                builder: (context, sync, _) => TextButton.icon(
                  onPressed: state.restartRequired ? null : () => showNotebookSyncPanel(context, widget.workspace.synchronization),
                  icon: const Icon(Icons.cloud_outlined), label: Text(notebookSyncStatus(context, sync)))),
              Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), child: Semantics(liveRegion: true,
                child: Text(editor == null ? AppStrings.of(context).text('Opening selected note…') : AppStrings.of(context).text('{value} · Received {receivedRevision} · Draft {draftRevision} · Saved {value4}', {'value': (saved ? AppStrings.of(context).text('Saved locally') : AppStrings.of(context).text('Unwritten changes')).toString(), 'receivedRevision': (state.receivedRevision).toString(), 'draftRevision': (state.draftRevision).toString(), 'value4': (state.onDiskRevision ?? AppStrings.of(context).text('none')).toString()})))),
              if (!state.restartRequired) Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Text(
                state.writing ? AppStrings.of(context).text('Saving revision {value}; newer input remains editable.', {'value': (state.inFlightRevision ?? AppStrings.of(context).text('captured')).toString()})
                    : AppStrings.of(context).text('Foreground autosave is enabled. Only acknowledged durable prefixes survive supported process restart.'),
                style: Theme.of(context).textTheme.bodySmall)),
              if (state.note != null && state.note!.lineEnding != 0)
                Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Text(AppStrings.of(context).text('Edited writes use {value} line endings; opening preserves exact source.', {'value': (switch(state.note!.lineEnding) {1 => 'LF', 2 => 'CRLF', 3 => 'CR', _ => AppStrings.of(context).text('core-specified')}).toString()}))),
              Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
                IconButton(tooltip: AppStrings.of(context).text('Undo'), icon: const Icon(Icons.undo), onPressed: enabled && (!_showPreview || constraints.maxWidth >= 1000) ? () => _command('undo') : null),
                IconButton(tooltip: AppStrings.of(context).text('Redo'), icon: const Icon(Icons.redo), onPressed: enabled && (!_showPreview || constraints.maxWidth >= 1000) ? () => _command('redo') : null),
                PopupMenuButton<String>(tooltip: AppStrings.of(context).text('Format Markdown'), icon: const Icon(Icons.text_format), enabled: enabled && markdown && (!_showPreview || constraints.maxWidth >= 1000),
                  onSelected: (action) => unawaited(_format(action)), itemBuilder: (_) => [
                    PopupMenuItem(value: 'bold', child: Text(AppStrings.of(context).text('Bold'))),
                    PopupMenuItem(value: 'italic', child: Text(AppStrings.of(context).text('Italic'))),
                    PopupMenuItem(value: 'code', child: Text(AppStrings.of(context).text('Inline code'))),
                    PopupMenuItem(value: 'fence', child: Text(AppStrings.of(context).text('Code block'))),
                    PopupMenuItem(value: 'heading-1', child: Text(AppStrings.of(context).text('Heading 1'))),
                    PopupMenuItem(value: 'heading-2', child: Text(AppStrings.of(context).text('Heading 2'))),
                    PopupMenuItem(value: 'heading-3', child: Text(AppStrings.of(context).text('Heading 3'))),
                    PopupMenuItem(value: 'heading-4', child: Text(AppStrings.of(context).text('Heading 4'))),
                    PopupMenuItem(value: 'heading-5', child: Text(AppStrings.of(context).text('Heading 5'))),
                    PopupMenuItem(value: 'heading-6', child: Text(AppStrings.of(context).text('Heading 6'))),
                    PopupMenuItem(value: 'quote', child: Text(AppStrings.of(context).text('Block quote'))),
                    PopupMenuItem(value: 'bullet', child: Text(AppStrings.of(context).text('Bullet list'))),
                    PopupMenuItem(value: 'ordered', child: Text(AppStrings.of(context).text('Numbered list'))),
                    PopupMenuItem(value: 'task', child: Text(AppStrings.of(context).text('Task list'))),
                    PopupMenuItem(value: 'link', child: Text(AppStrings.of(context).text('Link'))),
                  ]),
                IconButton(tooltip: widget.dark ? AppStrings.of(context).text('Use light theme') : AppStrings.of(context).text('Use dark theme'),
                  icon: Icon(widget.dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
                  onPressed: () => widget.onThemeChanged(!widget.dark)),
                if (!state.restartRequired) FilledButton(onPressed: !state.busy && state.editor?.canFlushSource == true ? () => _notebook.write(_transport) : null, child: Text(AppStrings.of(context).text('Save now'))),
                if (!state.restartRequired) TextButton(onPressed: !state.transitioning && state.editor != null ? () => _requestBarrier(reopen: true) : null, child: Text(AppStrings.of(context).text('Reopen'))),
                TextButton.icon(onPressed: _preview != null ? _closePreview : enabled && markdown ? _openPreview : null,
                  icon: Icon(_preview != null ? Icons.code : Icons.preview_outlined), label: Text(_preview != null ? AppStrings.of(context).text('Source') : AppStrings.of(context).text('Preview'))),
              ]),
              if (error != null) ConstrainedBox(constraints: const BoxConstraints(maxHeight: 180), child: ColoredBox(
                color: Theme.of(context).colorScheme.errorContainer,
                child: SingleChildScrollView(padding: const EdgeInsets.all(8), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SelectableText(AppStrings.of(context).message(error)),
                  if (editor != null) Wrap(children: [
                    TextButton(onPressed: _copyReceivedText, child: Text(AppStrings.of(context).text('Copy received source'))),
                    if (!state.restartRequired) ...[
                      if (state.syncRecoveryRequired) TextButton(onPressed: () => widget.workspace.synchronization.recover(), child: Text(AppStrings.of(context).text('Recover sync')))
                      else TextButton(onPressed: state.transitioning ? null : _recoverView, child: Text(AppStrings.of(context).text('Recover editor view'))),
                      TextButton(onPressed: !state.busy && state.editor?.canFlushSource == true ? () => _notebook.write(_transport) : null, child: Text(AppStrings.of(context).text('Retry save / reconcile'))),
                    ],
                  ]) else if (!state.busy) TextButton(onPressed: _notebook.retryOpen, child: Text(AppStrings.of(context).text('Retry open'))),
                ])),
              )),
              ]))),
              Expanded(child: Stack(children: [
                Positioned.fill(child: AdaptiveEditorPanes(
                  showPreview: _showPreview,
                  source: _webView == null
                    ? Center(child: state.loading ? const CircularProgressIndicator() : Text(AppStrings.of(context).text('Native source is retained while the secure editor is unavailable.')))
                    : WebViewWidget(key: ValueKey(_webEpoch), controller: _webView!),
                  preview: _preview == null ? const SizedBox.shrink() : NotebookPreview(session: _preview!, onSource: () => unawaited(_closePreview()), onRefresh: () => unawaited(_refreshPreview())),
                )),
                if (_preview != null && !_showPreview && !_preview!.retiring) Align(alignment: Alignment.bottomCenter, child: LinearProgressIndicator(semanticsLabel: AppStrings.of(context).text('Capturing preview source'))),
              ])),
            ],
          ))),
        ),
      );
    },
  );
}
