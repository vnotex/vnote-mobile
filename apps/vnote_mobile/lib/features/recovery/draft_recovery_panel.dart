// SPDX-License-Identifier: LGPL-3.0-only
import 'package:flutter/material.dart';

import '../../services/editor_drafts.dart';
import '../../services/notebook_library.dart';

/// Recovery is always an explicit choice. Inspection/export never publishes a
/// notebook body, and keeping disk requires separate private-discard consent.
class DraftRecoveryPanel extends StatelessWidget {
  const DraftRecoveryPanel({required this.library, super.key});
  final NotebookLibrary library;

  Future<bool> _confirm(BuildContext context, String title, String detail,
      String action) async => await showDialog<bool>(context: context,
    builder: (context) => AlertDialog(title: Text(title), content: Text(detail),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false),
        child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(action))])) ?? false;

  Future<void> _inspect(BuildContext context, DraftRecoveryEntry entry) async {
    final inspection = await library.inspectDraft(entry);
    if (!context.mounted || inspection == null) return;
    await showDialog<void>(context: context, builder: (context) =>
      DefaultTabController(length: 3, child: AlertDialog(
        title: Text(entry.label),
        content: SizedBox(width: 720, height: 480, child: Column(children: [
          const TabBar(tabs: [Tab(text: 'Status'), Tab(text: 'Draft'), Tab(text: 'Base')]),
          Expanded(child: TabBarView(children: [
            SingleChildScrollView(child: SelectableText(_status(inspection))),
            _source(inspection.source, 'No valid source can be reconstructed. Export the raw journal archive.'),
            _source(inspection.baseSource, 'The opening checkpoint is unavailable or quarantined.'),
          ])),
        ])),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
      )));
  }

  static Widget _source(String? text, String unavailable) => SingleChildScrollView(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: SelectableText(text ?? unavailable,
      style: text == null ? null : const TextStyle(fontFamily: 'monospace')));

  static String _status(DraftRecoveryInspection value) => [
    switch (value.outcome) {
      'saved' => 'The exact saved disk prefix was established. Any later acknowledged edits remain recoverable in the original source representation.',
      'base' => 'The current disk matches the expected base. Restore opens the private source as a new, dirty capture; it does not overwrite disk.',
      'conflict' => 'Current disk, identity, or policy differs. Disk and private source are preserved separately. Export or explicitly keep disk; automatic overwrite is forbidden.',
      'quarantined' => 'Acknowledged journal data is invalid. No recovered text is fabricated. The owned raw archive remains exportable.',
      _ => 'The current disk outcome cannot be established. Private recovery data is retained.',
    },
    'Acknowledged draft revision: ${value.entry.revision}',
    if (value.savedRevision != null) 'Established saved prefix: ${value.savedRevision}',
    if (value.diskHash != null) 'Observed disk SHA-256: ${value.diskHash}',
    if (value.error != null) value.error!,
    'Unreceived or provisional input is outside the durability guarantee.',
  ].join('\n\n');

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<NotebookLibraryState>(
    valueListenable: library,
    builder: (context, state, _) {
      final drafts = state.draftState;
      final entries = drafts.entries.where((entry) => !entry.resolved).toList();
      if (entries.isEmpty && drafts.error == null) return const SizedBox.shrink();
      final busy = state.busy || drafts.busy || state.workspace != null;
      return Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Private draft recovery', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          const Text('Only acknowledged durable prefixes are listed. Restoring opens a new capture without overwriting current disk. Unreceived or composing input may not survive a view or process loss.'),
          if (drafts.error != null) Padding(padding: const EdgeInsets.only(top: 8),
            child: Semantics(liveRegion: true, child: Text(drafts.error!))),
          for (final entry in entries) Padding(padding: const EdgeInsets.only(top: 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(entry.label, style: Theme.of(context).textTheme.titleMedium),
              Text(entry.quarantined ? 'Quarantined journal; raw export remains available.'
                : 'Acknowledged revision ${entry.revision}; disk must be revalidated.'),
              Wrap(spacing: 8, runSpacing: 4, children: [
                OutlinedButton(onPressed: busy ? null : () => _inspect(context, entry),
                  child: const Text('Inspect base / draft / disk')),
                FilledButton(onPressed: busy || entry.quarantined ? null : () async {
                  if (await _confirm(context, 'Restore private draft?',
                    'Current disk will be checked again. Only a matching base or established saved prefix can be restored. Later acknowledged source opens as dirty until a new saved receipt is durable.', 'Restore')) {
                    await library.restoreDraft(entry);
                  }
                }, child: const Text('Restore as new capture')),
                OutlinedButton(onPressed: busy || state.transferReserved || entry.quarantined ? null
                  : () => library.exportDraft(entry), child: const Text('Export draft text')),
                OutlinedButton(onPressed: busy || state.transferReserved ? null
                  : () => library.exportDraft(entry, raw: true), child: const Text('Export raw journal')),
                TextButton(onPressed: busy ? null : () async {
                  if (await _confirm(context, 'Keep disk and discard private draft?',
                    'This permanently discards this private recovery capture. The current notebook file is unchanged. Export first if you need to keep private edits or evidence of corruption. An unfinished export may prevent discard.', 'Discard private draft')) {
                    await library.discardDraft(entry);
                  }
                }, child: const Text('Keep disk / discard draft')),
              ]),
            ])),
        ])));
    });
}
