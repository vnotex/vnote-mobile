// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../services/editor_session.dart';
import '../../services/notebook_session.dart';
import '../../services/notebook_workspace.dart';
import '../../services/notebook_library.dart';
import '../resources/resource_panel.dart';
import '../about/license_sheet.dart';

class NotebookEditor extends StatefulWidget {
  const NotebookEditor({
    required this.workspace,
    required this.session,
    required this.library,
    required this.dark,
    required this.onThemeChanged,
    super.key,
  });

  final NotebookWorkspace workspace;
  final NotebookSession session;
  final NotebookLibrary library;

  final bool dark;
  final ValueChanged<bool> onThemeChanged;

  @override
  State<NotebookEditor> createState() => _NotebookEditorState();
}

class _NotebookEditorState extends State<NotebookEditor> {
  static const _assetPath = 'assets/editor/index.html';
  late final NotebookSession _notebook;
  EditorSession get _session => _notebook.value.editor!;
  EditorSession? _boundEditor;
  int _webEpoch = 0;
  bool _themeSent = false;
  WebViewController? _webView;
  String? _assetUrl;
  bool _navigationAdmitted = false;
  bool _pageStarted = false;
  bool _loadSent = false;
  bool _showingExitDialog = false;
  bool _disposed = false;
  Future<void> _outbound = Future<void>.value();
  int _queuedMessages = 0;

  @override
  void initState() {
    super.initState();
    _notebook = widget.session;
    _notebook.addListener(_notebookChanged);
    _notebookChanged();
  }

  void _notebookChanged() {
    if (_disposed || identical(_boundEditor, _notebook.value.editor)) return;
    _boundEditor = _notebook.value.editor;
    if (_boundEditor == null) return;
    _assetUrl = null;
    _navigationAdmitted = _pageStarted = _loadSent = _themeSent = false;
    _webView = null;
    unawaited(_initializeWebView());
  }

  Future<void> _initializeWebView() async {
    final session = _session;
    final epoch = ++_webEpoch;
    try {
      final controller = WebViewController();
      _webView = controller;
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.addJavaScriptChannel(
        'VNoteEditor',
        onMessageReceived: (message) {
          if (_disposed || epoch != _webEpoch) return;
          final reply = session.receive(message.message);
          if (reply != null) _send(reply);
          if (session.value.ready && !_themeSent) {
            _themeSent = true;
            final theme = session.theme(dark: widget.dark);
            if (theme != null) _send(theme);
          }
        },
      );
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            // Pin the sole bundled main-frame navigation; links, network URLs,
            // subframes and even same-URL reloads cannot replace dirty text.
            if (_disposed ||
                epoch != _webEpoch ||
                !request.isMainFrame ||
                _navigationAdmitted ||
                _pageStarted ||
                !_isBundledEntry(request.url)) {
              return NavigationDecision.prevent;
            }
            _navigationAdmitted = true;
            _assetUrl = request.url;
            return NavigationDecision.navigate;
          },
          onPageStarted: (url) {
            if (_disposed || epoch != _webEpoch) return;
            if (_pageStarted ||
                !_isBundledEntry(url) ||
                (_assetUrl != null && _assetUrl != url)) {
              session.reportTransportError(
                'Unexpected navigation. The received text is retained; automatic recovery is disabled.',
              );
              return;
            }
            _pageStarted = true;
            _assetUrl = url;
          },
          onPageFinished: (url) {
            if (_disposed || epoch != _webEpoch) return;
            if (!_isBundledEntry(url) || url != _assetUrl || _loadSent) {
              session.reportTransportError(
                'Unexpected page completion. No document replacement was attempted.',
              );
              return;
            }
            _loadSent = true;
            final load = session.beginLoad();
            if (load != null) _send(load);
          },
          onWebResourceError: (error) {
            if (_disposed ||
                epoch != _webEpoch ||
                error.isForMainFrame == false) {
              return;
            }
            session.reportTransportError(
              'The bundled editor failed. Received text remains available for copying.',
            );
          },
        ),
      );
      if (_disposed || epoch != _webEpoch) return;
      setState(() {});
      await controller.loadFlutterAsset(_assetPath);
    } on Object catch (_) {
      if (!_disposed && epoch == _webEpoch) {
        session.reportTransportError(
          'Cannot start the bundled editor. Received source is retained.',
        );
      }
    }
  }

  static bool _isBundledEntry(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'file' ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.host.isNotEmpty && uri.host != 'localhost')) {
      return false;
    }
    // Android and iOS choose different private asset roots. Before first load,
    // allow only the known Flutter asset entry beneath such a local root;
    // callbacks then pin its entire URL, not arbitrary file paths.
    return uri.path.endsWith('/flutter_assets/$_assetPath') &&
        !uri.pathSegments.contains('..');
  }

  void _send(Map<String, Object?> message) {
    if (_disposed || _webView == null) return;
    if (_queuedMessages >= 32) {
      _session.reportTransportError(
        'The editor transport queue is full. Text is retained; no reload was attempted.',
      );
      return;
    }
    _queuedMessages++;
    // The JSON literal is the only interpolated value. Source is never HTML,
    // executable fragments, a URL, or an additional native channel.
    final literal = jsonEncode(message);
    final epoch = _webEpoch;
    final controller = _webView!;
    _outbound = _outbound.then((_) async {
      try {
        if (!_disposed && epoch == _webEpoch) {
          await controller.runJavaScript(
            'window.vnoteEditor.receive($literal);',
          );
        }
      } on Object catch (_) {
        if (!_disposed && epoch == _webEpoch) {
          _session.reportTransportError(
            'Editor transport failed. The received text is retained.',
          );
        }
      } finally {
        _queuedMessages--;
      }
    });
  }

  void _command(String command) {
    final message = _session.command(command);
    if (message != null) _send(message);
  }

  void _toggleTheme() {
    final next = !widget.dark;
    final message = _session.theme(dark: next);
    if (message == null) return;
    _send(message);
    // Rebuild Flutter chrome only. The controller, generation and CM view stay.
    widget.onThemeChanged(next);
  }

  Future<void> _write() async {
    await _notebook.write(_send);
  }

  Future<void> _showResources() async {
    final editor = _notebook.value.editor;
    if (editor == null || _notebook.value.busy) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => FractionallySizedBox(
        heightFactor: 0.9,
        child: ResourcePanel(
          library: widget.library,
          workspace: widget.workspace,
          session: _notebook,
          editor: editor,
          send: _send,
        ),
      ),
    );
  }

  Future<void> _copyReceivedText() async {
    try {
      await Clipboard.setData(ClipboardData(text: _session.value.text));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Copied received text only. Pending editor input may differ.',
          ),
        ),
      );
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Cannot copy received text: $error')),
      );
    }
  }

  Future<void> _requestExit() => _requestBarrier(reopen: false);

  Future<void> _requestBarrier({required bool reopen}) async {
    if (_showingExitDialog ||
        _notebook.value.busy ||
        widget.workspace.value.busy) {
      return;
    }
    _showingExitDialog = true;
    // Ask even when received revisions match: JS may still hold a local batch
    // or active composition that the native host has not received yet.
    final disposition = await showDialog<NotebookDisposition>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(reopen ? 'Reopen from disk?' : 'Return to notebook?'),
        content: const Text(
          'Write current editor input first, or discard input not on disk. '
          'Finish keyboard composition before Write. Unsaved input has no '
          'autosave or crash-recovery guarantee.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, NotebookDisposition.cancel),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(context, NotebookDisposition.discard),
            child: const Text('Discard'),
          ),
          FilledButton(
            onPressed: _notebook.value.editor?.canRequestSnapshot == true
                ? () => Navigator.pop(context, NotebookDisposition.write)
                : null,
            child: const Text('Write'),
          ),
        ],
      ),
    );
    _showingExitDialog = false;
    if (!mounted || disposition == null) return;
    if (reopen) {
      await _notebook.reopen(disposition, _send);
    } else {
      await widget.workspace.returnToBrowser(_notebook, disposition, _send);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _webEpoch++;
    _notebook.removeListener(_notebookChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final notebook = _notebook;
    return ValueListenableBuilder<NotebookSessionState>(
      valueListenable: notebook,
      builder: (context, state, _) {
        final editor = state.editor?.value;
        final enabled = editor?.ready == true && editor?.closing != true;
        final error = state.error ?? editor?.error;
        return PopScope<Object?>(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop) unawaited(_requestExit());
          },
          child: Scaffold(
            resizeToAvoidBottomInset: true,
            appBar: AppBar(
              title: Text(
                state.note == null
                    ? 'Note'
                    : '${state.note!.notebookName} / ${state.note!.path}',
              ),
              actions: [
                IconButton(
                  tooltip: 'Attachments and images',
                  onPressed: state.note != null && !state.busy
                      ? _showResources
                      : null,
                  icon: const Icon(Icons.attach_file),
                ),
                IconButton(
                  tooltip: 'Legal notices',
                  icon: const Icon(Icons.info_outline),
                  onPressed: () =>
                      showNotebookLicenses(context, notebook.nativeNotices),
                ),
                IconButton(
                  tooltip: 'Return to notebook',
                  onPressed: state.busy ? null : _requestExit,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            body: SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1200),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (state.busy) const LinearProgressIndicator(),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        child: Text(
                          editor == null
                              ? 'Opening selected note…'
                              : 'On disk: revision ${state.onDiskRevision} · '
                                    'Received: ${editor.revision} · '
                                    '${state.dirty ? 'Unwritten changes' : 'Received revision is on disk'}',
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(
                          state.busy
                              ? 'Waiting for completed composition or native operation. Typing remains available during Write.'
                              : 'Write is explicit. Pending input is not on disk; no autosave or crash recovery.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      if (state.note != null && state.note!.lineEnding != 0)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Text(
                            'Edited writes use ${switch (state.note!.lineEnding) {
                              1 => 'LF',
                              2 => 'CRLF',
                              3 => 'CR',
                              _ => 'core-specified',
                            }} line endings; opening preserves exact source.',
                          ),
                        ),
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          IconButton(
                            tooltip: 'Undo',
                            icon: const Icon(Icons.undo),
                            onPressed: enabled ? () => _command('undo') : null,
                          ),
                          IconButton(
                            tooltip: 'Redo',
                            icon: const Icon(Icons.redo),
                            onPressed: enabled ? () => _command('redo') : null,
                          ),
                          IconButton(
                            tooltip: widget.dark
                                ? 'Use light theme'
                                : 'Use dark theme',
                            icon: Icon(
                              widget.dark
                                  ? Icons.light_mode_outlined
                                  : Icons.dark_mode_outlined,
                            ),
                            onPressed: enabled ? _toggleTheme : null,
                          ),
                          FilledButton(
                            onPressed:
                                !state.busy &&
                                    state.editor?.canRequestSnapshot == true
                                ? _write
                                : null,
                            child: const Text('Write'),
                          ),
                          TextButton(
                            onPressed: !state.busy && state.editor != null
                                ? () => _requestBarrier(reopen: true)
                                : null,
                            child: const Text('Reopen'),
                          ),
                        ],
                      ),
                      if (error != null)
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 140),
                          child: ColoredBox(
                            color: Theme.of(context).colorScheme.errorContainer,
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.all(8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SelectableText(error),
                                  if (editor != null)
                                    TextButton(
                                      onPressed: _copyReceivedText,
                                      child: const Text('Copy received text'),
                                    )
                                  else if (!state.busy)
                                    TextButton(
                                      onPressed: notebook.retryOpen,
                                      child: const Text('Retry open'),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      Expanded(
                        child: _webView == null
                            ? Center(
                                child: state.loading
                                    ? const CircularProgressIndicator()
                                    : const Text(
                                        'The native notebook must open before editing.',
                                      ),
                              )
                            : WebViewWidget(
                                key: ValueKey(_webEpoch),
                                controller: _webView!,
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
