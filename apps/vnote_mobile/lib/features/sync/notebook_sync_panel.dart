// SPDX-License-Identifier: LGPL-3.0-only
import 'package:flutter/material.dart';
import 'package:vxcore_bridge/vxcore_bridge.dart';

import '../../l10n/app_strings.dart';
import '../../services/notebook_sync.dart';
import '../../services/sync_credentials.dart';

String notebookSyncStatus(BuildContext context, NotebookSyncState state) {
  if (state.facts == null && state.error == null && !state.busy) return AppStrings.of(context).text('Sync information is not ready');
  if (state.busy) return AppStrings.of(context).text('Sync: {name}', {'name': (AppStrings.of(context).text(state.phase.name)).toString()});
  if (state.recoveryRequired) return AppStrings.of(context).text('Sync needs recovery');
  if (state.queued) return AppStrings.of(context).text('Sync queued');
  return switch (state.readiness) {
    NotebookSyncReadiness.disabled => AppStrings.of(context).text('Sync off'),
    NotebookSyncReadiness.orphan => AppStrings.of(context).text('Sync credential cleanup pending'),
    NotebookSyncReadiness.unsupported => AppStrings.of(context).text('Unsupported sync backend'),
    NotebookSyncReadiness.invalidEndpoint => AppStrings.of(context).text('Sync needs an HTTPS endpoint'),
    NotebookSyncReadiness.missingCredentials => AppStrings.of(context).text('Sync needs credentials'),
    NotebookSyncReadiness.credentialsUnknown => AppStrings.of(context).text('Secure storage unavailable'),
    NotebookSyncReadiness.unregistered => AppStrings.of(context).text('Sync needs configuration recovery'),
    NotebookSyncReadiness.ready => AppStrings.of(context).text('WebDAV configured'),
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
  Widget build(BuildContext context) => AlertDialog(scrollable: true, 
    title: Text(AppStrings.of(context).text('Connect existing WebDAV notebook')),
    content: SizedBox(width: 560, child: SingleChildScrollView(child: Column(
      mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(AppStrings.of(context).text('Download into private staging, then validate and import the complete notebook. Existing notebook IDs are preserved. No existing notebook is overwritten.')),
        const SizedBox(height: 16),
        _EndpointField(controller: _endpoint),
        const SizedBox(height: 12),
        TextField(controller: _username, autocorrect: false, enableSuggestions: false,
          decoration: InputDecoration(labelText: AppStrings.of(context).text('WebDAV username'))),
        const SizedBox(height: 12),
        TextField(controller: _password, obscureText: true, autocorrect: false,
          enableSuggestions: false, decoration: InputDecoration(labelText: AppStrings.of(context).text('WebDAV password'))),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(AppStrings.of(context).text('Foreground automatic sync')),
          subtitle: Text(AppStrings.of(context).text('No guaranteed background execution.')), value: _automatic,
          onChanged: (value) => setState(() => _automatic = value)),
        if (_error != null) Text(AppStrings.of(context).message(_error!), style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ]))),
    actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(AppStrings.of(context).text('Cancel'))),
      FilledButton(onPressed: _submit, child: Text(AppStrings.of(context).text('Download notebook')))],
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
    onChanged: onChanged, decoration: InputDecoration(labelText: AppStrings.of(context).text('HTTPS WebDAV collection'),
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
      await showDialog<bool>(context: context, builder: (context) => AlertDialog(scrollable: true, 
        title: Text(title), content: Text(AppStrings.of(context).message(detail)), actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(AppStrings.of(context).text('Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(AppStrings.of(context).text(action))),
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
        setState(() => _formError = result.code == null
          ? result.error ?? 'Synchronization needs attention; retained data was not discarded.'
          : 'Core error ${result.code}: ${result.error ?? 'Synchronization needs attention; retained data was not discarded.'}');
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
      confirmed = await _confirm(AppStrings.of(context).text('Change WebDAV endpoint?'),
        AppStrings.of(context).text('Retire the previous local synchronization baseline before connecting to the new endpoint? Previous recovery archives and remote notebooks are not deleted. A failed new connection may remain disabled with recoverable state.'), AppStrings.of(context).text('Change endpoint'));
      if (!confirmed || !mounted) return;
    }
    await _act(() => widget.sync.configure(endpoint: endpoint, username: _username.text,
      password: _password.text, autoSyncEnabled: _automatic, confirmEndpointChange: confirmed), secret: true);
  }

  Future<void> _disable() async {
    if (!await _confirm(AppStrings.of(context).text('Disable WebDAV sync?'),
      AppStrings.of(context).text('Keep the local notebook and all remote data. Local routing and credentials are removed only after the corresponding steps succeed; failed cleanup remains visible.'), AppStrings.of(context).text('Disable sync')) || !mounted) { return; }
    await _act(widget.sync.disable);
  }

  String _resolution(CoreSyncResolution resolution) => switch (resolution) {
    CoreSyncResolution.keepLocal => AppStrings.of(context).text('Keep local'),
    CoreSyncResolution.keepRemote => AppStrings.of(context).text('Keep remote'),
    CoreSyncResolution.keepBoth => AppStrings.of(context).text('Keep both'),
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
        Expanded(child: Text(AppStrings.of(context).text('WebDAV synchronization'), style: const TextStyle(fontSize: 20))),
        IconButton(tooltip: AppStrings.of(context).text('Refresh sync facts'), onPressed: state.busy ? null : () => widget.sync.reconcile(),
          icon: const Icon(Icons.refresh)),
        IconButton(tooltip: AppStrings.of(context).text('Close sync information'), onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
      ])),
      if (state.busy) LinearProgressIndicator(semanticsLabel: AppStrings.of(context).text('Synchronization {name}', {'name': (AppStrings.of(context).text(state.phase.name)).toString()})),
      Expanded(child: SingleChildScrollView(padding: EdgeInsets.fromLTRB(16, 8, 16,
        16 + MediaQuery.viewInsetsOf(context).bottom), child: Center(child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(notebookSyncStatus(context, state), style: Theme.of(context).textTheme.titleMedium),
            Text(AppStrings.of(context).text('Configured is not proof of connectivity. Sync captures saved notebook data; unsaved editor input remains a separate private draft.')),
            if (last != null && last > 0) Padding(padding: const EdgeInsets.only(top: 8),
              child: Text(AppStrings.of(context).text('Last successful saved snapshot: {value}', {'value': (DateTime.fromMillisecondsSinceEpoch(last).toLocal()).toString()}))),
            if (state.error != null || _formError != null) Padding(padding: const EdgeInsets.symmetric(vertical: 12),
              child: SelectableText(AppStrings.of(context).message(_formError ?? state.error!), style: TextStyle(color: Theme.of(context).colorScheme.error))),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.icon(onPressed: state.canSync ? () => _act(widget.sync.syncNow) : null,
                icon: const Icon(Icons.sync), label: Text(AppStrings.of(context).text('Sync now'))),
              if (state.busy || state.queued) OutlinedButton(onPressed: () => widget.sync.cancel(), child: Text(AppStrings.of(context).text('Cancel sync'))),
              OutlinedButton(onPressed: !state.busy ? () => _act(() => widget.sync.recover(
                username: _username.text.isEmpty ? null : _username.text,
                password: _password.text.isEmpty ? null : _password.text), secret: true) : null,
                child: Text(AppStrings.of(context).text('Recover sync'))),
              TextButton(onPressed: !state.busy && (facts?.enabled == true || state.readiness == NotebookSyncReadiness.orphan)
                ? _disable : null, child: Text(AppStrings.of(context).text('Disable sync'))),
            ]),
            const Divider(height: 32),
            if (state.readiness == NotebookSyncReadiness.unsupported)
              Text(AppStrings.of(context).text('This backend is preserved but not supported by mobile. No automatic migration is performed.')),
            _EndpointField(controller: _endpoint, enabled: !state.busy,
              onChanged: (_) => _inputChanged = true),
            const SizedBox(height: 12),
            TextField(controller: _username, enabled: !state.busy, autocorrect: false,
              enableSuggestions: false, decoration: InputDecoration(labelText: AppStrings.of(context).text('WebDAV username'))),
            const SizedBox(height: 12),
            TextField(controller: _password, enabled: !state.busy, obscureText: true,
              autocorrect: false, enableSuggestions: false,
              decoration: InputDecoration(labelText: AppStrings.of(context).text('WebDAV password'), helperText: AppStrings.of(context).text('Password bytes are not trimmed. Stored secrets are never displayed here.'))),
            SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(AppStrings.of(context).text('Foreground automatic sync')),
              subtitle: Text(AppStrings.of(context).text('A coalescing 30-second window; no guaranteed background execution.')),
              value: _automatic, onChanged: state.busy ? null : (value) {
                setState(() { _automatic = value; _inputChanged = true; });
                if (facts?.enabled == true) _act(() => widget.sync.setAutoSyncEnabled(value));
              }),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton(onPressed: state.busy || state.readiness == NotebookSyncReadiness.unsupported ? null : _configure,
                child: Text(AppStrings.of(context).text('Enable / update connection'))),
              OutlinedButton(onPressed: state.busy || facts?.registered != true ? null : () => _act(
                () => widget.sync.rotateCredentials(username: _username.text, password: _password.text), secret: true),
                child: Text(AppStrings.of(context).text('Update credentials'))),
            ]),
            Padding(padding: EdgeInsets.only(top: 12), child: Text(AppStrings.of(context).text('Recovery may need credentials for a retained candidate account. It verifies recorded outcomes rather than overwriting a newer note or deleting uncertain data.'))),
            if (conflicts.isNotEmpty) ...[
              const Divider(height: 32),
              Text(AppStrings.of(context).text('Conflicts ({length})', {'length': (conflicts.length).toString()}), style: Theme.of(context).textTheme.titleMedium),
              Text(AppStrings.of(context).text('Choices are restricted to core capabilities. Metadata and protected content may not support Keep both.')),
              for (final conflict in rows) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SelectableText(conflict.path),
                  Text(conflict.binary ? AppStrings.of(context).text('Binary / opaque conflict') : AppStrings.of(context).text('File conflict')),
                  DropdownButton<CoreSyncResolution>(isExpanded: true, hint: Text(AppStrings.of(context).text('Choose resolution')),
                    value: _choices[conflict.path]?.resolution,
                    items: [CoreSyncResolution.keepLocal, CoreSyncResolution.keepRemote,
                      if (conflict.canKeepBoth) CoreSyncResolution.keepBoth]
                      .map((choice) => DropdownMenuItem(value: choice, child: Text(_resolution(choice)))).toList(),
                    onChanged: state.busy ? null : (choice) { if (choice != null) { setState(() => _choices[conflict.path] =
                      NotebookSyncResolution(path: conflict.path, resolution: choice, ownerGeneration: state.ownerGeneration)); } }),
                  for (final outcome in state.conflictOutcomes.where((item) => item.path == conflict.path && !item.success))
                    Text(AppStrings.of(context).message(outcome.code == null
                      ? outcome.error ?? 'This conflict remains unresolved.'
                      : 'Core error ${outcome.code}: ${outcome.error ?? 'This conflict remains unresolved.'}'),
                      style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ])),
              if (pages > 1) Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, children: [
                TextButton(onPressed: page == 0 ? null : () => setState(() => _page = page - 1), child: Text(AppStrings.of(context).text('Previous conflicts'))),
                Text(AppStrings.of(context).text('Page {value} of {pages}', {'value': (page + 1).toString(), 'pages': (pages).toString()})),
                TextButton(onPressed: page + 1 >= pages ? null : () => setState(() => _page = page + 1), child: Text(AppStrings.of(context).text('Next conflicts'))),
              ]),
              FilledButton(onPressed: state.busy || _choices.isEmpty ? null : () => _act(
                () => widget.sync.resolveConflicts(_choices.values.toList())),
                child: Text(AppStrings.of(context).text('Resolve selected ({length})', {'length': (_choices.length).toString()}))),
            ],
          ])))),
      ),
    ])));
  }
}
