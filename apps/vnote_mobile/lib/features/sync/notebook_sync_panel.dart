// SPDX-License-Identifier: LGPL-3.0-only
import 'package:flutter/material.dart';
import 'package:vxcore_bridge/vxcore_bridge.dart';

import '../../services/notebook_sync.dart';
import '../../services/sync_credentials.dart';

String notebookSyncStatus(NotebookSyncState state) {
  if (state.facts == null && state.error == null && !state.busy) return 'Sync information is not ready';
  if (state.busy) return 'Sync: ${state.phase.name}';
  if (state.recoveryRequired) return 'Sync needs recovery';
  if (state.queued) return 'Sync queued';
  return switch (state.readiness) {
    NotebookSyncReadiness.disabled => 'Sync off',
    NotebookSyncReadiness.orphan => 'Sync credential cleanup pending',
    NotebookSyncReadiness.unsupported => 'Unsupported sync backend',
    NotebookSyncReadiness.invalidEndpoint => 'Sync needs an HTTPS endpoint',
    NotebookSyncReadiness.missingCredentials => 'Sync needs credentials',
    NotebookSyncReadiness.credentialsUnknown => 'Secure storage unavailable',
    NotebookSyncReadiness.unregistered => 'Sync needs configuration recovery',
    NotebookSyncReadiness.ready => 'WebDAV configured',
  };
}

Future<void> showNotebookSyncPanel(BuildContext context, NotebookSync sync) =>
    showModalBottomSheet<void>(context: context, isScrollControlled: true, useSafeArea: true,
      builder: (context) => FractionallySizedBox(heightFactor: 0.94,
        child: NotebookSyncPanel(sync: sync)));

/// Transient form result, never stored in application presentation state.
class SyncConnectionInput {
  const SyncConnectionInput({required this.endpoint, required this.username,
    required this.password, required this.autoSyncEnabled});
  final String endpoint;
  final String username;
  final String password;
  final bool autoSyncEnabled;
  @override
  String toString() => 'SyncConnectionInput(redacted)';
}

Future<SyncConnectionInput?> showWebDavConnectionDialog(BuildContext context) =>
    showDialog<SyncConnectionInput>(context: context,
      builder: (context) => const _ConnectionDialog());

class _ConnectionDialog extends StatefulWidget {
  const _ConnectionDialog();
  @override
  State<_ConnectionDialog> createState() => _ConnectionDialogState();
}

class _ConnectionDialogState extends State<_ConnectionDialog> {
  final _endpoint = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _automatic = false;
  String? _error;
  @override
  void dispose() {
    _password.clear(); _password.dispose(); _username.dispose(); _endpoint.dispose();
    super.dispose();
  }
  void _submit() {
    try {
      final endpoint = canonicalSyncEndpoint(_endpoint.text);
      if (_username.text.isEmpty || _password.text.isEmpty) {
        setState(() => _error = 'Enter a username and password or app password.');
        return;
      }
      Navigator.pop(context, SyncConnectionInput(endpoint: endpoint,
        username: _username.text, password: _password.text, autoSyncEnabled: _automatic));
    } on Object {
      setState(() => _error = 'Use a valid HTTPS collection URL without user information, query or fragment.');
    }
  }
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Connect existing WebDAV notebook'),
    content: SizedBox(width: 560, child: SingleChildScrollView(child: Column(
      mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Download into private staging, then validate and import the complete notebook. '
          'Existing notebook IDs are preserved. No existing notebook is overwritten.'),
        const SizedBox(height: 16),
        _EndpointField(controller: _endpoint),
        const SizedBox(height: 12),
        TextField(controller: _username, autocorrect: false, enableSuggestions: false,
          decoration: const InputDecoration(labelText: 'WebDAV username')),
        const SizedBox(height: 12),
        TextField(controller: _password, obscureText: true, autocorrect: false,
          enableSuggestions: false, decoration: const InputDecoration(labelText: 'WebDAV password')),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Foreground automatic sync'),
          subtitle: const Text('No guaranteed background execution.'), value: _automatic,
          onChanged: (value) => setState(() => _automatic = value)),
        if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ]))),
    actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(onPressed: _submit, child: const Text('Download notebook'))],
  );
}

class _EndpointField extends StatelessWidget {
  const _EndpointField({required this.controller, this.enabled = true, this.onChanged});
  final TextEditingController controller;
  final bool enabled;
  final ValueChanged<String>? onChanged;
  @override
  Widget build(BuildContext context) => TextField(controller: controller, enabled: enabled,
    keyboardType: TextInputType.url, autocorrect: false, enableSuggestions: false,
    onChanged: onChanged, decoration: const InputDecoration(labelText: 'HTTPS WebDAV collection',
      hintText: 'https://server.example/dav/notebook/'));
}

class NotebookSyncPanel extends StatefulWidget {
  const NotebookSyncPanel({required this.sync, super.key});
  final NotebookSync sync;
  @override
  State<NotebookSyncPanel> createState() => _NotebookSyncPanelState();
}

class _NotebookSyncPanelState extends State<NotebookSyncPanel> {
  late final TextEditingController _endpoint;
  final _username = TextEditingController();
  final _password = TextEditingController();
  final Map<String, NotebookSyncResolution> _choices = {};
  String? _formError;
  bool _inputChanged = false;
  bool _automatic = false;
  int _page = 0;
  static const _pageSize = 100;

  @override
  void initState() {
    super.initState();
    _endpoint = TextEditingController(text: widget.sync.value.facts?.endpoint ?? '');
    _automatic = widget.sync.value.facts?.autoSyncEnabled ?? false;
    widget.sync.addListener(_changed);
  }
  void _changed() {
    if (!mounted) return;
    final facts = widget.sync.value.facts;
    if (!_inputChanged && facts != null) {
      _endpoint.text = facts.endpoint; _automatic = facts.autoSyncEnabled;
    }
    final current = {for (final conflict in facts?.conflicts ?? const <CoreSyncConflict>[]) conflict.path: conflict};
    _choices.removeWhere((path, selection) => selection.ownerGeneration != widget.sync.value.ownerGeneration ||
      !current.containsKey(path) || (selection.resolution == CoreSyncResolution.keepBoth && !current[path]!.canKeepBoth));
    setState(() {});
  }
  @override
  void dispose() {
    widget.sync.removeListener(_changed);
    _password.clear(); _password.dispose(); _username.dispose(); _endpoint.dispose();
    super.dispose();
  }
  Future<bool> _confirm(String title, String detail, String action) async =>
      await showDialog<bool>(context: context, builder: (context) => AlertDialog(
        title: Text(title), content: Text(detail), actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(action)),
        ])) == true;

  Future<void> _act(Future<NotebookSyncOutcome> Function() action, {bool secret = false}) async {
    setState(() => _formError = null);
    try {
      final result = await action();
      if (!mounted) return;
      for (final item in result.conflicts) {
        if (item.success) _choices.remove(item.path);
      }
      if (!result.success && !result.cancelled) {
        setState(() => _formError = result.error ?? 'Synchronization needs attention; retained data was not discarded.');
      }
    } on Object {
      if (mounted) setState(() => _formError = 'The synchronization action could not complete. Existing data and credentials remain protected.');
    } finally {
      if (secret && mounted) _password.clear();
    }
  }

  Future<void> _configure() async {
    String endpoint;
    try { endpoint = canonicalSyncEndpoint(_endpoint.text); }
    on Object {
      setState(() => _formError = 'Use a valid HTTPS collection URL without user information, query or fragment.');
      return;
    }
    final facts = widget.sync.value.facts;
    final previous = facts?.provider.bindingEndpoint ?? facts?.endpoint ?? '';
    var confirmed = false;
    if (previous.isNotEmpty && previous != endpoint) {
      confirmed = await _confirm('Change WebDAV endpoint?',
        'Retire the previous local synchronization baseline before connecting to the new endpoint? '
        'Previous recovery archives and remote notebooks are not deleted. '
        'A failed new connection may remain disabled with recoverable state.', 'Change endpoint');
      if (!confirmed || !mounted) return;
    }
    await _act(() => widget.sync.configure(endpoint: endpoint, username: _username.text,
      password: _password.text, autoSyncEnabled: _automatic, confirmEndpointChange: confirmed), secret: true);
  }

  Future<void> _disable() async {
    if (!await _confirm('Disable WebDAV sync?',
      'Keep the local notebook and all remote data. Local routing and credentials are removed '
      'only after the corresponding steps succeed; failed cleanup remains visible.', 'Disable sync') || !mounted) { return; }
    await _act(widget.sync.disable);
  }

  String _resolution(CoreSyncResolution resolution) => switch (resolution) {
    CoreSyncResolution.keepLocal => 'Keep local',
    CoreSyncResolution.keepRemote => 'Keep remote',
    CoreSyncResolution.keepBoth => 'Keep both',
  };

  @override
  Widget build(BuildContext context) {
    final state = widget.sync.value;
    final facts = state.facts;
    final conflicts = facts?.conflicts ?? const <CoreSyncConflict>[];
    final pages = (conflicts.length + _pageSize - 1) ~/ _pageSize;
    final page = pages == 0 ? 0 : _page.clamp(0, pages - 1).toInt();
    final rows = conflicts.skip(page * _pageSize).take(_pageSize);
    final last = state.lastSuccessUtcMillis;
    return Material(child: SafeArea(child: Column(children: [
      Padding(padding: const EdgeInsets.all(12), child: Row(children: [
        const Expanded(child: Text('WebDAV synchronization', style: TextStyle(fontSize: 20))),
        IconButton(tooltip: 'Refresh sync facts', onPressed: state.busy ? null : () => widget.sync.reconcile(),
          icon: const Icon(Icons.refresh)),
        IconButton(tooltip: 'Close sync information', onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
      ])),
      if (state.busy) LinearProgressIndicator(semanticsLabel: 'Synchronization ${state.phase.name}'),
      Expanded(child: SingleChildScrollView(padding: EdgeInsets.fromLTRB(16, 8, 16,
        16 + MediaQuery.viewInsetsOf(context).bottom), child: Center(child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(notebookSyncStatus(state), style: Theme.of(context).textTheme.titleMedium),
            const Text('Configured is not proof of connectivity. Sync captures saved notebook data; '
              'unsaved editor input remains a separate private draft.'),
            if (last != null && last > 0) Padding(padding: const EdgeInsets.only(top: 8),
              child: Text('Last successful saved snapshot: ${DateTime.fromMillisecondsSinceEpoch(last).toLocal()}')),
            if (state.error != null || _formError != null) Padding(padding: const EdgeInsets.symmetric(vertical: 12),
              child: SelectableText(_formError ?? state.error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.icon(onPressed: state.canSync ? () => _act(widget.sync.syncNow) : null,
                icon: const Icon(Icons.sync), label: const Text('Sync now')),
              if (state.busy || state.queued) OutlinedButton(onPressed: () => widget.sync.cancel(), child: const Text('Cancel sync')),
              OutlinedButton(onPressed: !state.busy ? () => _act(() => widget.sync.recover(
                username: _username.text.isEmpty ? null : _username.text,
                password: _password.text.isEmpty ? null : _password.text), secret: true) : null,
                child: const Text('Recover sync')),
              TextButton(onPressed: !state.busy && (facts?.enabled == true || state.readiness == NotebookSyncReadiness.orphan)
                ? _disable : null, child: const Text('Disable sync')),
            ]),
            const Divider(height: 32),
            if (state.readiness == NotebookSyncReadiness.unsupported)
              const Text('This backend is preserved but not supported by mobile. No automatic migration is performed.'),
            _EndpointField(controller: _endpoint, enabled: !state.busy,
              onChanged: (_) => _inputChanged = true),
            const SizedBox(height: 12),
            TextField(controller: _username, enabled: !state.busy, autocorrect: false,
              enableSuggestions: false, decoration: const InputDecoration(labelText: 'WebDAV username')),
            const SizedBox(height: 12),
            TextField(controller: _password, enabled: !state.busy, obscureText: true,
              autocorrect: false, enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'WebDAV password', helperText: 'Password bytes are not trimmed. Stored secrets are never displayed here.')),
            SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Foreground automatic sync'),
              subtitle: const Text('A coalescing 30-second window; no guaranteed background execution.'),
              value: _automatic, onChanged: state.busy ? null : (value) {
                setState(() { _automatic = value; _inputChanged = true; });
                if (facts?.enabled == true) _act(() => widget.sync.setAutoSyncEnabled(value));
              }),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton(onPressed: state.busy || state.readiness == NotebookSyncReadiness.unsupported ? null : _configure,
                child: const Text('Enable / update connection')),
              OutlinedButton(onPressed: state.busy || facts?.registered != true ? null : () => _act(
                () => widget.sync.rotateCredentials(username: _username.text, password: _password.text), secret: true),
                child: const Text('Update credentials')),
            ]),
            const Padding(padding: EdgeInsets.only(top: 12), child: Text('Recovery may need credentials for a retained candidate account. '
              'It verifies recorded outcomes rather than overwriting a newer note or deleting uncertain data.')),
            if (conflicts.isNotEmpty) ...[
              const Divider(height: 32),
              Text('Conflicts (${conflicts.length})', style: Theme.of(context).textTheme.titleMedium),
              const Text('Choices are restricted to core capabilities. Metadata and protected content may not support Keep both.'),
              for (final conflict in rows) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SelectableText(conflict.path),
                  Text(conflict.binary ? 'Binary / opaque conflict' : 'File conflict'),
                  DropdownButton<CoreSyncResolution>(isExpanded: true, hint: const Text('Choose resolution'),
                    value: _choices[conflict.path]?.resolution,
                    items: [CoreSyncResolution.keepLocal, CoreSyncResolution.keepRemote,
                      if (conflict.canKeepBoth) CoreSyncResolution.keepBoth]
                      .map((choice) => DropdownMenuItem(value: choice, child: Text(_resolution(choice)))).toList(),
                    onChanged: state.busy ? null : (choice) { if (choice != null) { setState(() => _choices[conflict.path] =
                      NotebookSyncResolution(path: conflict.path, resolution: choice, ownerGeneration: state.ownerGeneration)); } }),
                  for (final outcome in state.conflictOutcomes.where((item) => item.path == conflict.path && !item.success))
                    Text(outcome.error ?? 'This conflict remains unresolved.', style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ])),
              if (pages > 1) Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, children: [
                TextButton(onPressed: page == 0 ? null : () => setState(() => _page = page - 1), child: const Text('Previous conflicts')),
                Text('Page ${page + 1} of $pages'),
                TextButton(onPressed: page + 1 >= pages ? null : () => setState(() => _page = page + 1), child: const Text('Next conflicts')),
              ]),
              FilledButton(onPressed: state.busy || _choices.isEmpty ? null : () => _act(
                () => widget.sync.resolveConflicts(_choices.values.toList())),
                child: Text('Resolve selected (${_choices.length})')),
            ],
          ])))),
      ),
    ])));
  }
}
