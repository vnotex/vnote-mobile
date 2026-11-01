// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/editor_session.dart';

// A dependency token, not a process-global editor or native-core singleton.
final _sessionProvider = Provider<EditorSession>(
  (ref) => throw StateError('EditorSession must be constructor-injected.'),
);

/// Takes ownership of the injected, memory-only session for this app lifetime.
class EditorValidationApp extends StatefulWidget {
  const EditorValidationApp({required this.session, super.key});

  final EditorSession session;

  @override
  State<EditorValidationApp> createState() => _EditorValidationAppState();
}

class _EditorValidationAppState extends State<EditorValidationApp> {
  bool _dark = false;

  @override
  void dispose() {
    widget.session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ProviderScope(
    overrides: [_sessionProvider.overrideWithValue(widget.session)],
    child: MaterialApp(
      title: 'Editor validation',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      themeMode: _dark ? ThemeMode.dark : ThemeMode.light,
      home: _EditorScreen(
        dark: _dark,
        onThemeChanged: (dark) => setState(() => _dark = dark),
      ),
    ),
  );
}

class _EditorScreen extends ConsumerStatefulWidget {
  const _EditorScreen({required this.dark, required this.onThemeChanged});

  final bool dark;
  final ValueChanged<bool> onThemeChanged;

  @override
  ConsumerState<_EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends ConsumerState<_EditorScreen> {
  static const _assetPath = 'assets/editor/index.html';
  late final EditorSession _session;
  WebViewController? _webView;
  String? _assetUrl;
  bool _navigationAdmitted = false;
  bool _pageStarted = false;
  bool _loadSent = false;
  bool _showingExitDialog = false;
  bool _allowExit = false;
  bool _disposed = false;
  Timer? _closeTimer;
  Future<void> _outbound = Future<void>.value();
  int _queuedMessages = 0;

  @override
  void initState() {
    super.initState();
    _session = ref.read(_sessionProvider);
    unawaited(_initializeWebView());
  }

  Future<void> _initializeWebView() async {
    try {
      final controller = WebViewController();
      _webView = controller;
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.addJavaScriptChannel(
        'VNoteEditor',
        onMessageReceived: (message) {
          if (_disposed) return;
          final reply = _session.receive(message.message);
          if (reply != null) _send(reply);
          if (_session.value.closed) unawaited(_finishExit());
        },
      );
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            // Pin the sole bundled main-frame navigation; links, network URLs,
            // subframes and even same-URL reloads cannot replace dirty text.
            if (!request.isMainFrame ||
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
            if (_disposed) return;
            if (_pageStarted ||
                !_isBundledEntry(url) ||
                (_assetUrl != null && _assetUrl != url)) {
              _session.reportTransportError(
                'Unexpected navigation. The received text is retained; automatic recovery is disabled.',
              );
              return;
            }
            _pageStarted = true;
            _assetUrl = url;
          },
          onPageFinished: (url) {
            if (_disposed) return;
            if (!_isBundledEntry(url) || url != _assetUrl || _loadSent) {
              _session.reportTransportError(
                'Unexpected page completion. No document replacement was attempted.',
              );
              return;
            }
            _loadSent = true;
            final load = _session.beginLoad();
            if (load != null) _send(load);
          },
          onWebResourceError: (error) {
            if (_disposed || error.isForMainFrame == false) return;
            _session.reportTransportError(
              'WebView error: ${error.description}. The received text and current view are retained.',
            );
          },
        ),
      );
      if (_disposed) return;
      setState(() {});
      await controller.loadFlutterAsset(_assetPath);
    } on Object catch (error) {
      if (!_disposed) {
        _session.reportTransportError(
          'Cannot start the bundled editor: $error',
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
    _outbound = _outbound.then((_) async {
      try {
        if (!_disposed) {
          await _webView!.runJavaScript(
            'window.vnoteEditor.receive($literal);',
          );
        }
      } on Object catch (error) {
        if (!_disposed) {
          _session.reportTransportError(
            'Editor transport failed: $error. The received text is retained.',
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

  void _snapshot() {
    final message = _session.requestSnapshot();
    if (message != null) {
      _send(message);
      setState(() {});
    }
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

  Future<void> _requestExit() async {
    if (_showingExitDialog || _allowExit) return;
    if (_session.value.closing) {
      await _showCloseWait();
      return;
    }
    _showingExitDialog = true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard this memory-only document?'),
        content: const Text(
          'Nothing has been saved to a notebook or recovery draft. Closing loses all text in this validation session. Finish any keyboard composition before closing.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep open'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Discard and close'),
          ),
        ],
      ),
    );
    _showingExitDialog = false;
    if (!mounted || discard != true) return;
    final close = _session.closeAfterDiscardConsent();
    if (close == null) {
      // No document was loaded into JS. Explicit discard consent still applies.
      if (!_loadSent) {
        await _finishExit();
      } else {
        await _showCloseWait();
      }
      return;
    }
    _send(close);
    _closeTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && !_session.value.closed) unawaited(_showCloseWait());
    });
  }

  Future<void> _showCloseWait() async {
    if (!mounted || _showingExitDialog || _allowExit) return;
    _showingExitDialog = true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Editor has not finished closing'),
        content: const Text(
          'Finish keyboard composition if it is active. The view and received text remain open; a timeout is not success. You may explicitly discard even unreceived or composing text, or keep the view open while waiting.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep open'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Discard without waiting'),
          ),
        ],
      ),
    );
    _showingExitDialog = false;
    if (mounted && discard == true) await _finishExit();
  }

  Future<void> _finishExit() async {
    if (!mounted || _allowExit) return;
    _closeTimer?.cancel();
    setState(() => _allowExit = true);
    // Only a completed close barrier or explicit force-discard reaches here.
    await SystemNavigator.pop();
  }

  @override
  void dispose() {
    _disposed = true;
    _closeTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(_sessionProvider);
    return ValueListenableBuilder<EditorSessionState>(
      valueListenable: session,
      builder: (context, state, _) => PopScope<Object?>(
        canPop: _allowExit,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) unawaited(_requestExit());
        },
        child: Scaffold(
          resizeToAvoidBottomInset: true,
          appBar: AppBar(
            title: const Text('Editor validation'),
            actions: [
              IconButton(
                tooltip: 'Legal notices',
                icon: const Icon(Icons.info_outline),
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  useSafeArea: true,
                  isScrollControlled: true,
                  builder: (context) => const FractionallySizedBox(
                    heightFactor: 0.9,
                    child: _LegalNotices(),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Close memory-only editor',
                onPressed: _requestExit,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1200),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final compact = constraints.maxHeight < 400;
                    final enabled = state.ready && !state.closing;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                          child: Text(
                            'Memory only · Not saved · Notebook unavailable',
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                        ),
                        if (!compact)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Text(
                              state.closing
                                  ? 'Waiting for composition and the close barrier. No text is saved.'
                                  : !state.ready
                                  ? 'Waiting for the host/editor handshake. Existing text is retained on error.'
                                  : 'Received revision ${state.revision} (volatile only).'
                                        '${state.snapshotRevision == null ? '' : ' Snapshot matched revision ${state.snapshotRevision}; not saved.'}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            IconButton(
                              tooltip: 'Undo',
                              onPressed: enabled
                                  ? () => _command('undo')
                                  : null,
                              icon: const Icon(Icons.undo),
                            ),
                            IconButton(
                              tooltip: 'Redo',
                              onPressed: enabled
                                  ? () => _command('redo')
                                  : null,
                              icon: const Icon(Icons.redo),
                            ),
                            IconButton(
                              tooltip: widget.dark
                                  ? 'Use light theme'
                                  : 'Use dark theme',
                              onPressed: enabled ? _toggleTheme : null,
                              icon: Icon(
                                widget.dark
                                    ? Icons.light_mode_outlined
                                    : Icons.dark_mode_outlined,
                              ),
                            ),
                            TextButton(
                              onPressed: session.canRequestSnapshot
                                  ? _snapshot
                                  : null,
                              child: const Text('Check snapshot'),
                            ),
                          ],
                        ),
                        if (state.error != null)
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight: compact ? 76 : 140,
                            ),
                            child: ColoredBox(
                              color: Theme.of(context)
                                  .colorScheme
                                  .errorContainer,
                              child: SingleChildScrollView(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                child: Semantics(
                                  liveRegion: true,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(state.error!),
                                      TextButton(
                                        onPressed: _copyReceivedText,
                                        child: const Text('Copy received text'),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        Expanded(
                          child: _webView == null
                              ? const Center(
                                  child: Text('Starting the bundled editor…'),
                                )
                              : WebViewWidget(controller: _webView!),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LegalNotices extends StatefulWidget {
  const _LegalNotices();

  @override
  State<_LegalNotices> createState() => _LegalNoticesState();
}

class _LegalNoticesState extends State<_LegalNotices> {
  late final Future<List<String>> _texts = Future.wait([
    rootBundle.loadString('assets/legal/COPYING.LESSER'),
    rootBundle.loadString('assets/legal/COPYING'),
    rootBundle.loadString('assets/editor/NOTICE.txt'),
  ]);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Legal notices', style: Theme.of(context).textTheme.headlineSmall),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text(
            'VNote Mobile application code is licensed under GNU LGPLv3, the same license as VNote. Bundled dependencies retain their own licenses. The full LGPL and referenced GPL terms are included below.',
          ),
        ),
        TextButton(
          onPressed: () => showLicensePage(
            context: context,
            applicationName: 'VNote Mobile — Editor validation',
            applicationVersion: '0.1.0',
          ),
          child: const Text('Flutter and plugin licenses'),
        ),
        Expanded(
          child: FutureBuilder<List<String>>(
            future: _texts,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return SelectableText(
                  'Legal assets could not be loaded: ${snapshot.error}',
                );
              }
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              const titles = [
                'GNU LGPL version 3',
                'GNU GPL version 3',
                'Bundled editor dependency notices',
              ];
              return ListView.builder(
                itemCount: titles.length,
                itemBuilder: (context, index) => ExpansionTile(
                  title: Text(titles[index]),
                  childrenPadding: const EdgeInsets.all(8),
                  children: [SelectableText(snapshot.data![index])],
                ),
              );
            },
          ),
        ),
      ],
    ),
  );
}
