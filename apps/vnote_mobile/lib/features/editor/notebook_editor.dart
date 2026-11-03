// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vxcore_bridge/vxcore_bridge.dart';
import 'package:webview_flutter/webview_flutter.dart';

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

class _NotebookEditorState extends State<NotebookEditor> with WidgetsBindingObserver {
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
    WidgetsBinding.instance.addObserver(this);
    _notebook.setForeground(WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed);
    _notebook.addListener(_notebookChanged);
    _notebookChanged();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _notebook.setForeground(state == AppLifecycleState.resumed);
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
    if (_lastPreferences == next) return;
    _lastPreferences = next;
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
    if (editor != null) unawaited(_initializeWebView(editor, epoch));
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
    if (!_current(editor, epoch) || _recoveringView) return;
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
        destination = await showDialog<String>(context: context, builder: (context) => AlertDialog(
          title: const Text('Link destination'),
          content: TextField(controller: controller, autofocus: true, autocorrect: false,
            maxLength: 2048, decoration: const InputDecoration(hintText: 'Relative note, #heading, or HTTPS URL')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Insert link')),
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
      CorePreviewNavigationKind.external => '${target.insecure ? 'Unencrypted HTTP link. ' : ''}Open ${target.origin} in the system browser?',
      CorePreviewNavigationKind.note => 'Open the linked note? Current input will be kept as a durable draft first.',
      CorePreviewNavigationKind.export => 'Export a copy of this attachment? Another application or provider will receive its bytes.',
    };
    final approved = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('Follow preview link?'),
      content: Text(detail),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Continue')),
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
        child: ResourcePanel(library: widget.library, workspace: widget.workspace,
          session: _notebook, editor: editor, send: _transport)));
  }

  Future<void> _copyReceivedText() async {
    try { await Clipboard.setData(ClipboardData(text: _boundEditor?.value.text ?? '')); }
    on Object catch (error) { _showError(error); }
  }

  Future<void> _recoverView() async {
    final editor = _boundEditor;
    if (editor == null || _recoveringView) return;
    try {
      if (_loadSent) {
        final candidate = await editor.requestResync(_transport);
        if (_disposed || !mounted || !identical(editor, _boundEditor)) return;
        if (candidate.text == editor.value.text && candidate.revision == editor.value.revision) {
          await editor.resumeResync(_transport);
          _notebook.bindTransport(_transport);
          return;
        }
        final useView = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
          title: const Text('Two source versions are retained'),
          content: const Text('The live editor differs from the received mirror. Choose which source to checkpoint into a new editor session; the other version remains recovery evidence.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Use received source')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Use editor source')),
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
    if (_showingExitDialog || _notebook.value.transitioning || widget.workspace.value.busy) return;
    _showingExitDialog = true;
    final disposition = await showDialog<NotebookDisposition>(context: context, builder: (context) => AlertDialog(
      title: Text(reopen ? 'Reopen from disk?' : 'Return to notebook?'),
      content: const Text('Finish composition and save the exact final revision, or keep it as a durable draft without writing the notebook. Explicit discard removes unwritten source only after confirmation.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, NotebookDisposition.cancel), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(context, NotebookDisposition.discard), child: const Text('Discard')),
        TextButton(onPressed: _boundEditor?.canFlushSource == true
            ? () => Navigator.pop(context, NotebookDisposition.retain) : null, child: const Text('Keep draft')),
        FilledButton(onPressed: _boundEditor?.canFlushSource == true
            ? () => Navigator.pop(context, NotebookDisposition.write) : null, child: const Text('Save and close')),
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
      : error is CoreException ? error.message
      : 'The operation could not complete. Source and durable drafts are retained.';
  void _showError(Object error) {
    if (!_disposed && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_describe(error))));
  }

  @override
  void dispose() {
    _disposed = true;
    _webEpoch++;
    _previewTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
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
      final enabled = editor?.ready == true && editor?.closing != true && editor?.quiesced != true;
      final markdown = state.note?.editorType == CoreEditorType.markdown;
      final error = state.syncError ?? state.durabilityError ?? state.error ?? editor?.error;
      final saved = editor != null && !state.dirty && !state.recoveryRequired &&
          state.durabilityError == null && state.error == null && editor.locallySaved;
      return PopScope<Object?>(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) { if (!didPop) unawaited(_showPreview ? _closePreview() : _requestExit()); },
        child: Scaffold(
          resizeToAvoidBottomInset: true,
          appBar: AppBar(
            title: Text(state.note == null ? 'Note' : '${state.note!.notebookName} / ${state.note!.path}'),
            actions: [
              IconButton(tooltip: 'Attachments and images', onPressed: state.note != null && !state.busy && !state.syncBusy ? _showResources : null, icon: const Icon(Icons.attach_file)),
              IconButton(tooltip: 'WebDAV synchronization', icon: const Icon(Icons.sync), onPressed: () => showNotebookSyncPanel(context, widget.workspace.synchronization)),
              IconButton(tooltip: 'Legal notices', icon: const Icon(Icons.info_outline), onPressed: () => showNotebookLicenses(context, _notebook.nativeNotices)),
              IconButton(tooltip: 'Return to notebook', onPressed: state.transitioning ? null : _requestExit, icon: const Icon(Icons.close)),
            ],
          ),
          body: SafeArea(child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1200), child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (state.busy) const LinearProgressIndicator(),
              ValueListenableBuilder<NotebookSyncState>(valueListenable: widget.workspace.synchronization,
                builder: (context, sync, _) => TextButton.icon(
                  onPressed: () => showNotebookSyncPanel(context, widget.workspace.synchronization),
                  icon: const Icon(Icons.cloud_outlined), label: Text(notebookSyncStatus(sync)))),
              Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), child: Semantics(liveRegion: true,
                child: Text(editor == null ? 'Opening selected note…' : '${saved ? 'Saved locally' : 'Unwritten changes'} · Received ${state.receivedRevision} · Draft ${state.draftRevision} · Saved ${state.onDiskRevision ?? 'none'}'))),
              Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Text(
                state.writing ? 'Saving revision ${state.inFlightRevision ?? 'captured'}; newer input remains editable.'
                    : 'Foreground autosave is enabled. Only acknowledged durable prefixes survive supported process restart.',
                style: Theme.of(context).textTheme.bodySmall)),
              if (state.note != null && state.note!.lineEnding != 0)
                Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Text('Edited writes use ${switch(state.note!.lineEnding) {1 => 'LF', 2 => 'CRLF', 3 => 'CR', _ => 'core-specified'}} line endings; opening preserves exact source.')),
              Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
                IconButton(tooltip: 'Undo', icon: const Icon(Icons.undo), onPressed: enabled && !_showPreview ? () => _command('undo') : null),
                IconButton(tooltip: 'Redo', icon: const Icon(Icons.redo), onPressed: enabled && !_showPreview ? () => _command('redo') : null),
                PopupMenuButton<String>(tooltip: 'Format Markdown', icon: const Icon(Icons.text_format), enabled: enabled && markdown && !_showPreview,
                  onSelected: (action) => unawaited(_format(action)), itemBuilder: (_) => const [
                    PopupMenuItem(value: 'bold', child: Text('Bold')),
                    PopupMenuItem(value: 'italic', child: Text('Italic')),
                    PopupMenuItem(value: 'code', child: Text('Inline code')),
                    PopupMenuItem(value: 'fence', child: Text('Code block')),
                    PopupMenuItem(value: 'heading-1', child: Text('Heading 1')),
                    PopupMenuItem(value: 'heading-2', child: Text('Heading 2')),
                    PopupMenuItem(value: 'heading-3', child: Text('Heading 3')),
                    PopupMenuItem(value: 'heading-4', child: Text('Heading 4')),
                    PopupMenuItem(value: 'heading-5', child: Text('Heading 5')),
                    PopupMenuItem(value: 'heading-6', child: Text('Heading 6')),
                    PopupMenuItem(value: 'quote', child: Text('Block quote')),
                    PopupMenuItem(value: 'bullet', child: Text('Bullet list')),
                    PopupMenuItem(value: 'ordered', child: Text('Numbered list')),
                    PopupMenuItem(value: 'task', child: Text('Task list')),
                    PopupMenuItem(value: 'link', child: Text('Link')),
                  ]),
                IconButton(tooltip: widget.dark ? 'Use light theme' : 'Use dark theme',
                  icon: Icon(widget.dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
                  onPressed: () => widget.onThemeChanged(!widget.dark)),
                FilledButton(onPressed: !state.busy && state.editor?.canFlushSource == true ? () => _notebook.write(_transport) : null, child: const Text('Save now')),
                TextButton(onPressed: !state.transitioning && state.editor != null ? () => _requestBarrier(reopen: true) : null, child: const Text('Reopen')),
                TextButton.icon(onPressed: _preview != null ? _closePreview : enabled && markdown ? _openPreview : null,
                  icon: Icon(_preview != null ? Icons.code : Icons.preview_outlined), label: Text(_preview != null ? 'Source' : 'Preview')),
              ]),
              if (error != null) ConstrainedBox(constraints: const BoxConstraints(maxHeight: 180), child: ColoredBox(
                color: Theme.of(context).colorScheme.errorContainer,
                child: SingleChildScrollView(padding: const EdgeInsets.all(8), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SelectableText(error),
                  if (editor != null) Wrap(children: [
                    TextButton(onPressed: _copyReceivedText, child: const Text('Copy received source')),
                    if (state.syncRecoveryRequired) TextButton(onPressed: () => widget.workspace.synchronization.recover(), child: const Text('Recover sync'))
                    else TextButton(onPressed: state.transitioning ? null : _recoverView, child: const Text('Recover editor view')),
                    TextButton(onPressed: !state.busy && state.editor?.canFlushSource == true ? () => _notebook.write(_transport) : null, child: const Text('Retry save / reconcile')),
                  ]) else if (!state.busy) TextButton(onPressed: _notebook.retryOpen, child: const Text('Retry open')),
                ])),
              )),
              Expanded(child: Stack(children: [
                Positioned.fill(child: Offstage(offstage: _showPreview, child: _webView == null
                    ? Center(child: state.loading ? const CircularProgressIndicator() : const Text('Native source is retained while the secure editor is unavailable.'))
                    : WebViewWidget(key: ValueKey(_webEpoch), controller: _webView!))),
                if (_showPreview && _preview != null) Positioned.fill(child: NotebookPreview(session: _preview!, onSource: () => unawaited(_closePreview()), onRefresh: () => unawaited(_refreshPreview()))),
                if (_preview != null && !_showPreview && !_preview!.retiring) const Align(alignment: Alignment.bottomCenter, child: LinearProgressIndicator(semanticsLabel: 'Capturing preview source')),
              ])),
            ],
          )))),
        ),
      );
    },
  );
}
