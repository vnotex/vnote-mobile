// SPDX-License-Identifier: LGPL-3.0-only
import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';
import '../../services/notebook_library.dart';
import '../../services/share_inbox.dart';

/// The library remains the sole transfer/writer owner; this panel only makes
/// explicit decisions and never opens notebook/core owners of its own.
class ShareInboxPanel extends StatefulWidget {
  const ShareInboxPanel({super.key, required this.library, required this.showOperationErrors});
  final NotebookLibrary library;
  final bool showOperationErrors;

  @override
  State<ShareInboxPanel> createState() => _ShareInboxPanelState();
}

class _ShareInboxPanelState extends State<ShareInboxPanel> {
  bool _running = false;

  Future<void> _run(Future<void> Function() action) async {
    if (_running) return;
    setState(() => _running = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<bool> _confirm(String title, String detail) async {
    final strings = AppStrings.of(context);
    return await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: Text(strings.text(title)),
      content: SingleChildScrollView(child: Text(strings.text(detail))),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false),
          child: Text(strings.text('Cancel'))),
        FilledButton(onPressed: () => Navigator.pop(context, true),
          child: Text(strings.text('Confirm'))),
      ],
    )) ?? false;
  }

  Future<void> _import(ShareInboxRecord record) async {
    final library = widget.library;
    if (record.status == ShareInboxStatus.importing) {
      await library.importShare(record);
      return;
    }
    final state = library.value;
    final current = state.workspace?.value;
    final canUseCurrent = current?.directory != null && current?.session == null &&
      (current?.canMutate ?? false);
    final entries = state.entries.where((item) => item.canOpen).toList(growable: false);
    if (!canUseCurrent && entries.isEmpty) return;
    final strings = AppStrings.of(context);
    final name = TextEditingController();
    String? selected = canUseCurrent ? '@current' : entries.first.location;
    var valid = false;
    bool accepted;
    try {
      accepted = await showDialog<bool>(context: context, builder: (dialogContext) =>
        StatefulBuilder(builder: (context, update) => AlertDialog(
          title: Text(strings.text('Import shared item')),
          content: SizedBox(width: 480, child: SingleChildScrollView(child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(strings.text('Choose a managed notebook root or the current folder. A new child folder groups this delivery.')),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: selected,
                isExpanded: true,
                decoration: InputDecoration(labelText: strings.text('Destination')),
                items: [
                  if (canUseCurrent) DropdownMenuItem(value: '@current',
                    child: Text(strings.text('Current folder'))),
                  for (final entry in entries) DropdownMenuItem(value: entry.location,
                    child: Text(strings.text('{name} — notebook root', {'name': entry.name}),
                      overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (value) => update(() => selected = value),
              ),
              const SizedBox(height: 16),
              TextField(controller: name, autofocus: true, maxLength: 255,
                decoration: InputDecoration(labelText: strings.text('New child folder name'),
                  helperText: strings.text('The destination cannot change after import starts.')),
                onChanged: (value) => update(() => valid = ShareInbox.validName(value))),
            ],
          ))),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(strings.text('Cancel'))),
            FilledButton(onPressed: valid && selected != null
              ? () => Navigator.pop(dialogContext, true) : null,
              child: Text(strings.text('Import'))),
          ],
        ))) ?? false;
      if (!accepted) return;
      final target = await library.shareTarget(
        notebook: entries.where((item) => item.location == selected).firstOrNull,
        folderName: name.text, currentFolder: selected == '@current');
      if (target != null) await library.importShare(record, target: target);
    } finally {
      name.dispose();
    }
  }

  String _status(ShareInboxStatus status) => switch (status) {
    ShareInboxStatus.ready => 'Ready to import',
    ShareInboxStatus.importing => 'Import requires completion or recovery',
    ShareInboxStatus.consumed => 'Imported receipt',
    ShareInboxStatus.discarded => 'Discarded receipt',
    ShareInboxStatus.failed => 'Retained failed delivery',
  };

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<NotebookLibraryState>(
    valueListenable: widget.library,
    builder: (context, library, _) {
      final strings = AppStrings.of(context);
      final inbox = library.shareState;
      final busy = _running || library.busy || !library.inboxReady;
      final noteOpen = library.workspace?.value.session != null;
      Widget action(String label, Future<void> Function() callback, {bool enabled = true}) =>
        OutlinedButton(style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: busy || !enabled ? null : () => _run(callback),
          child: Text(strings.text(label)));
      return Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(header: true, child: Text(strings.text('Shared items'),
            style: Theme.of(context).textTheme.titleLarge)),
          const SizedBox(height: 8),
          if (!inbox.initialized) Text(strings.text('Checking retained shared items…')),
          if (inbox.initialized && !inbox.available)
            Text(strings.text('Incoming sharing is unavailable on this installation. System export may still be available.')),
          if (inbox.initialized && inbox.available && inbox.records.isEmpty)
            Text(strings.text('No retained shared items.')),
          if (noteOpen) Text(strings.text('Close the selected note before importing shared items.')),
          if (inbox.error != null) Semantics(liveRegion: true,
            child: Text(strings.message(inbox.error!))),
          if (widget.showOperationErrors && library.error != null && library.error != inbox.error)
            Semantics(liveRegion: true, child: Text(strings.message(library.error!))),
          if (widget.showOperationErrors && library.cohortState.error != null &&
              library.cohortState.error != inbox.error && library.cohortState.error != library.error)
            Semantics(liveRegion: true, child: Text(strings.message(library.cohortState.error!))),
          if (inbox.message != null) Semantics(liveRegion: true,
            child: Text(strings.message(inbox.message!))),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton(style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _running || library.busy ? null : () => _run(widget.library.refreshInbox),
              child: Text(strings.text('Check shared items'))),
            action('Forget settled history', () async {
              if (await _confirm('Forget settled history?',
                  'Settled receipts without retained duplicates will be forgotten. Pending imports and retained duplicate bytes remain. Sharing the same item again may then create a new import.')) {
                await widget.library.forgetShareHistory();
              }
            }, enabled: inbox.available),
            action('Clean up outgoing shares', () async {
              if (await _confirm('Clean up outgoing shares?',
                  'Confirm that every recipient has finished reading. This removes retained system-share copies, not notebook content. Android blocks cleanup while readers are active or uncertain. iOS cannot detect all recipients still reading shared file URLs; confirming cleanup revokes those copies.')) {
                await widget.library.cleanupSharedExports();
              }
            }),
          ]),
          if (inbox.records.isNotEmpty) ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.5),
            child: ListView.builder(primary: false, shrinkWrap: true,
              itemCount: inbox.records.length, itemBuilder: (context, index) {
              final record = inbox.records[index];
              return Padding(
            key: ValueKey(record.id),
            padding: const EdgeInsets.only(top: 16),
            child: DecoratedBox(decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(8)),
              child: Padding(padding: const EdgeInsets.all(12), child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(strings.text(_status(record.status)),
                    style: Theme.of(context).textTheme.titleMedium),
                  Text(strings.text('{files} files · {bytes} bytes',
                    {'files': record.files.length, 'bytes': record.bytes})),
                  for (final file in record.files) Text(file.name),
                  if (record.target != null) Text(strings.text('Destination: {folder}',
                    {'folder': record.target!.folderName})),
                  if (record.duplicateAvailable)
                    Text(strings.text('A repeated delivery is retained. It will not import automatically.')),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    if (record.status == ShareInboxStatus.ready || record.status == ShareInboxStatus.importing)
                      action(record.status == ShareInboxStatus.ready ? 'Choose destination and import' : 'Continue import',
                        () => _import(record), enabled: !noteOpen &&
                          (record.status == ShareInboxStatus.importing || !library.transferReserved)),
                    if (record.payloadAvailable || record.duplicateAvailable)
                      action('Share original bytes', () => widget.library.exportShare(record)),
                    if (!record.settled) action('Discard shared item', () async {
                      if (await _confirm('Discard shared item?',
                          'Discard only the retained delivery after native recovery proves it safe. A committed notebook folder is never removed. Uncertain imports remain retained.')) {
                        await widget.library.discardShare(record);
                      }
                    }),
                    if (record.settled && (record.payloadAvailable || record.duplicateAvailable))
                      action('Import another copy', () async {
                        if (await _confirm('Import another copy?',
                            'Create a new pending delivery from the retained bytes. The original receipt remains and no import starts until you choose a destination.')) {
                          await widget.library.anotherShareCopy(record);
                        }
                      }),
                    if (record.duplicateAvailable) action('Dismiss retained duplicate', () async {
                      if (await _confirm('Dismiss retained duplicate?',
                          'Remove only the repeated delivery bytes. Keep the original receipt so another redelivery does not import automatically.')) {
                        await widget.library.dismissShareDuplicate(record);
                      }
                    }),
                  ]),
                ],
              ))),
              );
            }),
          ),
        ],
      )));
    },
  );
}
