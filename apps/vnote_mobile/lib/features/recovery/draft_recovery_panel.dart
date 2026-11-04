// SPDX-License-Identifier: LGPL-3.0-only
import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';
import '../../services/editor_drafts.dart';
import '../../services/notebook_library.dart';

/// Recovery is always an explicit choice. Inspection/export never publishes a
/// notebook body, and keeping disk requires separate private-discard consent.
class DraftRecoveryPanel extends StatelessWidget {
  const DraftRecoveryPanel({required this.library, super.key});
  final NotebookLibrary library;

  Future<bool> _confirm(BuildContext context, String title, String detail,
      String action) async => await showDialog<bool>(context: context,
    builder: (context) => AlertDialog(scrollable: true, title: Text(title), content: Text(AppStrings.of(context).message(detail)),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false),
        child: Text(AppStrings.of(context).text('Cancel'))),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(AppStrings.of(context).text(action)))])) ?? false;

  static String _label(BuildContext context, DraftRecoveryEntry entry) =>
      entry.descriptor?['pathHint'] as String? ??
      AppStrings.of(context).text('Quarantined private draft');

  Future<void> _inspect(BuildContext context, DraftRecoveryEntry entry) async {
    final inspection = await library.inspectDraft(entry);
    if (!context.mounted || inspection == null) return;
    await showDialog<void>(context: context, builder: (context) =>
      DefaultTabController(length: 3, child: AlertDialog(scrollable: true, 
        title: Text(_label(context, entry)),
        content: SizedBox(width: 720, height: 480, child: Column(children: [
          TabBar(tabs: [Tab(text: AppStrings.of(context).text('Status')), Tab(text: AppStrings.of(context).text('Draft')), Tab(text: AppStrings.of(context).text('Base'))]),
          Expanded(child: TabBarView(children: [
            SingleChildScrollView(child: SelectableText(_status(context, inspection))),
            _source(inspection.source, AppStrings.of(context).text('No valid source can be reconstructed. Export the raw journal archive.')),
            _source(inspection.baseSource, AppStrings.of(context).text('The opening checkpoint is unavailable or quarantined.')),
          ])),
        ])),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(AppStrings.of(context).text('Close')))],
      )));
  }

  static Widget _source(String? text, String unavailable) => SingleChildScrollView(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: SelectableText(text ?? unavailable,
      style: text == null ? null : const TextStyle(fontFamily: 'monospace')));

  static String _status(BuildContext context, DraftRecoveryInspection value) => [
    switch (value.outcome) {
      'saved' => AppStrings.of(context).text('The exact saved disk prefix was established. Any later acknowledged edits remain recoverable in the original source representation.'),
      'base' => AppStrings.of(context).text('The current disk matches the expected base. Restore opens the private source as a new, dirty capture; it does not overwrite disk.'),
      'conflict' => AppStrings.of(context).text('Current disk, identity, or policy differs. Disk and private source are preserved separately. Export or explicitly keep disk; automatic overwrite is forbidden.'),
      'quarantined' => AppStrings.of(context).text('Acknowledged journal data is invalid. No recovered text is fabricated. The owned raw archive remains exportable.'),
      _ => AppStrings.of(context).text('The current disk outcome cannot be established. Private recovery data is retained.'),
    },
    AppStrings.of(context).text('Acknowledged draft revision: {revision}', {'revision': (value.entry.revision).toString()}),
    if (value.savedRevision != null) AppStrings.of(context).text('Established saved prefix: {savedRevision}', {'savedRevision': (value.savedRevision).toString()}),
    if (value.diskHash != null) AppStrings.of(context).text('Observed disk SHA-256: {diskHash}', {'diskHash': (value.diskHash).toString()}),
    if (value.error != null) AppStrings.of(context).message(value.error!),
    AppStrings.of(context).text('Unreceived or provisional input is outside the durability guarantee.'),
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
          Text(AppStrings.of(context).text('Private draft recovery'), style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(AppStrings.of(context).text('Only acknowledged durable prefixes are listed. Restoring opens a new capture without overwriting current disk. Unreceived or composing input may not survive a view or process loss.')),
          if (drafts.error != null) Padding(padding: const EdgeInsets.only(top: 8),
            child: Semantics(liveRegion: true, child: Text(AppStrings.of(context).message(drafts.error!)))),
          for (final entry in entries) Padding(padding: const EdgeInsets.only(top: 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_label(context, entry), style: Theme.of(context).textTheme.titleMedium),
              Text(entry.quarantined ? AppStrings.of(context).text('Quarantined journal; raw export remains available.')
                : AppStrings.of(context).text('Acknowledged revision {revision}; disk must be revalidated.', {'revision': (entry.revision).toString()})),
              Wrap(spacing: 8, runSpacing: 4, children: [
                OutlinedButton(onPressed: busy ? null : () => _inspect(context, entry),
                  child: Text(AppStrings.of(context).text('Inspect base / draft / disk'))),
                FilledButton(onPressed: busy || entry.quarantined ? null : () async {
                  if (await _confirm(context, AppStrings.of(context).text('Restore private draft?'),
                    AppStrings.of(context).text('Current disk will be checked again. Only a matching base or established saved prefix can be restored. Later acknowledged source opens as dirty until a new saved receipt is durable.'), AppStrings.of(context).text('Restore'))) {
                    await library.restoreDraft(entry);
                  }
                }, child: Text(AppStrings.of(context).text('Restore as new capture'))),
                OutlinedButton(onPressed: busy || state.transferReserved || entry.quarantined ? null
                  : () => library.exportDraft(entry), child: Text(AppStrings.of(context).text('Export draft text'))),
                OutlinedButton(onPressed: busy || state.transferReserved ? null
                  : () => library.exportDraft(entry, raw: true), child: Text(AppStrings.of(context).text('Export raw journal'))),
                TextButton(onPressed: busy ? null : () async {
                  if (await _confirm(context, AppStrings.of(context).text('Keep disk and discard private draft?'),
                    AppStrings.of(context).text('This permanently discards this private recovery capture. The current notebook file is unchanged. Export first if you need to keep private edits or evidence of corruption. An unfinished export may prevent discard.'), AppStrings.of(context).text('Discard private draft'))) {
                    await library.discardDraft(entry);
                  }
                }, child: Text(AppStrings.of(context).text('Keep disk / discard draft'))),
              ]),
            ])),
        ])));
    });
}
