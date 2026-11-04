// SPDX-License-Identifier: LGPL-3.0-only
import 'package:flutter/material.dart';
import 'package:vxcore_bridge/vxcore_bridge.dart';

import '../../l10n/app_strings.dart';
import '../../l10n/locale_settings.dart';
import '../../services/notebook_library.dart';
import '../../services/notebook_export.dart';
import '../../services/notebook_import.dart';
import '../../services/document_transfer_platform.dart';
import '../../services/cohort_import.dart';
import '../../services/resource_transfer.dart';
import '../recovery/draft_recovery_panel.dart';
import '../share/share_inbox_panel.dart';
import '../sync/notebook_sync_panel.dart';

class NotebookLibraryScreen extends StatefulWidget {
  const NotebookLibraryScreen({
    required this.library,
    required this.dark,
    required this.onThemeChanged,
    super.key,
  });

  final NotebookLibrary library;
  final bool dark;
  final ValueChanged<bool> onThemeChanged;

  @override
  State<NotebookLibraryScreen> createState() => _NotebookLibraryScreenState();
}

class _NotebookLibraryScreenState extends State<NotebookLibraryScreen> {
  bool _isCurrent(NotebookLibrary library, NotebookLibraryState snapshot) =>
      mounted &&
      identical(widget.library, library) &&
      identical(library.value, snapshot) &&
      !snapshot.busy &&
      !snapshot.stale &&
      !snapshot.closed &&
      snapshot.workspace == null;

  Future<void> _create(
    NotebookLibrary library,
    NotebookLibraryState snapshot,
  ) async {
    if (!_isCurrent(library, snapshot)) return;
    final name = await showDialog<String>(
      context: context,
      builder: (context) => const _NewNotebookDialog(),
    );
    if (name == null || !_isCurrent(library, snapshot)) return;
    await library.createNotebook(name);
  }

  Future<void> _connect(NotebookLibrary library, NotebookLibraryState snapshot) async {
    if (!_isCurrent(library, snapshot) || snapshot.transferReserved) return;
    final input = await showWebDavConnectionDialog(context);
    if (input == null || !_isCurrent(library, snapshot)) return;
    await library.connectWebDav(endpoint: input.endpoint, username: input.username,
      password: input.password, autoSyncEnabled: input.autoSyncEnabled);
  }

  Future<void> _export(
    NotebookLibrary library,
    NotebookLibraryState snapshot,
    ManagedNotebookEntry entry,
  ) async {
    if (!_isCurrent(library, snapshot)) return;
    var selected = CoreExportFormat.notebook;
    final format = await showDialog<CoreExportFormat>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(scrollable: true, 
          title: Text(AppStrings.of(context).text('Export “{name}”?', {'name': (entry.name).toString()})),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownButton<CoreExportFormat>(
                  value: selected,
                  isExpanded: true,
                  items: [
                    DropdownMenuItem(
                      value: CoreExportFormat.notebook,
                      child: Text(AppStrings.of(context).text('Notebook backup')),
                    ),
                    DropdownMenuItem(
                      value: CoreExportFormat.filesAndAssets,
                      child: Text(AppStrings.of(context).text('Files and assets')),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(() => selected = value);
                    }
                  },
                ),
                const SizedBox(height: 12),
                Text(
                  selected == CoreExportFormat.notebook
                      ? AppStrings.of(context).text('Save a ZIP copy of the saved notebook, including attachments and recycle content. Local sync history/state is excluded.')
                      : AppStrings.of(context).text('Save raw files and assets with their original hierarchy and unchanged bytes. Unsupported files stay opaque. The entire vx_notebook directory, including unknown files stored there, and configured recycle data are omitted. Notebook identity, tags and configuration are not backed up. This is not a notebook backup. Protected content requires Notebook backup; nothing is decrypted or converted. Links are not rewritten; references to omitted or external data and VNote IDs may not work.'),
                ),
                const SizedBox(height: 12),
                Text(
                  AppStrings.of(context).text('Only saved content is exported. The ZIP itself is not encrypted. The notebook is not changed.'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(AppStrings.of(context).text('Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, selected),
              child: Text(AppStrings.of(context).text('Export ZIP')),
            ),
          ],
        ),
      ),
    );
    if (format != null && _isCurrent(library, snapshot)) {
      await library.exportNotebook(entry, format: format);
    }
  }

  @override
  Widget build(
    BuildContext context,
  ) => ValueListenableBuilder<NotebookLibraryState>(
    valueListenable: widget.library,
    builder: (context, state, _) {
      final library = widget.library;
      final idle = !state.busy && !state.closed && state.workspace == null;
      final available = idle && !state.stale;
      final messages = <String>[
        AppStrings.of(context).text('Local notebooks need your own exported copies. OS backup exclusion is requested, not guaranteed; app removal or device loss may remove local data.'),
        if (state.error != null) state.error!,
        if (state.closed) AppStrings.of(context).text('The notebook library is closed.'),
        if (state.stale && !state.closed && !state.busy)
          AppStrings.of(context).text('Refresh the library before creating or opening a notebook.'),
      ];
      return Scaffold(
        appBar: AppBar(
          title: Text(AppStrings.of(context).text('Notebooks')),
          actions: [
            const LanguageMenu(),
            IconButton(
              tooltip: widget.dark ? AppStrings.of(context).text('Use light theme') : AppStrings.of(context).text('Use dark theme'),
              onPressed: () => widget.onThemeChanged(!widget.dark),
              icon: Icon(
                widget.dark
                    ? Icons.light_mode_outlined
                    : Icons.dark_mode_outlined,
              ),
            ),
          ],
        ),
        body: SafeArea(
          child: LayoutBuilder(builder: (context, constraints) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ConstrainedBox(constraints: BoxConstraints(maxHeight: constraints.maxHeight * 0.45),
                child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (state.busy) const LinearProgressIndicator(),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  IconButton(
                    tooltip: AppStrings.of(context).text('Refresh'),
                    onPressed: idle ? library.refresh : null,
                    icon: const Icon(Icons.refresh),
                  ),
                  TextButton.icon(
                    onPressed: available ? () => _create(library, state) : null,
                    icon: const Icon(Icons.add),
                    label: Text(AppStrings.of(context).text('New notebook')),
                  ),
                  TextButton.icon(
                    onPressed: available && !state.transferReserved ? () => _connect(library, state) : null,
                    icon: const Icon(Icons.cloud_download_outlined),
                    label: Text(AppStrings.of(context).text('Connect WebDAV')),
                  ),
                  PopupMenuButton<DocumentImportKind>(
                    tooltip: AppStrings.of(context).text('Import notebook'),
                    icon: const Icon(Icons.file_download_outlined),
                    enabled: available && !state.transferReserved,
                    onSelected: (kind) async {
                      if (_isCurrent(library, state)) {
                        await library.prepareImport(kind);
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: DocumentImportKind.zip,
                        child: Text(AppStrings.of(context).text('Import ZIP')),
                      ),
                      PopupMenuItem(
                        value: DocumentImportKind.folder,
                        child: Text(AppStrings.of(context).text('Import folder')),
                      ),
                    ],
                  ),
                ],
              ),
              if (messages.isNotEmpty)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 180),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(messages.map(AppStrings.of(context).message).join('\n')),
                  ),
                ),
              ]))),
              Expanded(
                child: ListView.builder(
                  itemCount:
                      (state.entries.isEmpty ? 1 : state.entries.length) + 1,
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return Column(
                        children: [
                          ShareInboxPanel(library: library, showOperationErrors: false),
                          DraftRecoveryPanel(library: library),
                          _ImportPanel(
                            library: library,
                            state: state.importState,
                            available: available,
                            closed: state.closed,
                          ),
                          _ExportPanel(
                            library: library,
                            state: state.exportState,
                            closed: state.closed,
                          ),
                          _CohortPanel(
                            library: library,
                            state: state.cohortState,
                            available: available,
                            closed: state.closed,
                          ),
                          _ResourceTransfersPanel(
                            library: library,
                            state: state.resourceState,
                            available: available,
                            closed: state.closed,
                          ),
                        ],
                      );
                    }
                    if (state.entries.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          state.busy
                              ? AppStrings.of(context).text('Loading notebooks…')
                              : state.closed
                              ? AppStrings.of(context).text('Library closed.')
                              : state.stale
                              ? AppStrings.of(context).text('The notebook library is unavailable.')
                              : AppStrings.of(context).text('No notebooks yet. Choose New notebook to create one.'),
                        ),
                      );
                    }
                    final entry = state.entries[index - 1];
                    return ListTile(
                      key: ObjectKey(entry),
                      leading: Icon(
                        entry.canOpen
                            ? Icons.book_outlined
                            : Icons.error_outline,
                      ),
                      title: Text(entry.name),
                      subtitle: entry.canOpen
                          ? null
                          : Text(
                              AppStrings.of(context).text('Unavailable: {value}', {'value': (entry.error ?? AppStrings.of(context).text('The notebook could not be opened.')).toString()}),
                            ),
                      trailing: IconButton(
                        tooltip: AppStrings.of(context).text('Export {name}', {'name': (entry.name).toString()}),
                        icon: const Icon(Icons.ios_share),
                        onPressed:
                            available &&
                                !state.transferReserved &&
                                entry.canOpen &&
                                !state.exportState.busy &&
                                state.exportState.prepared == null &&
                                state.exportState.leftovers.isEmpty
                            ? () => _export(library, state, entry)
                            : null,
                      ),
                      onTap: available && entry.canOpen
                          ? () async {
                              if (_isCurrent(library, state)) {
                                await library.openNotebook(entry);
                              }
                            }
                          : null,
                    );
                  },
                ),
              ),
            ],
          )),
        ),
      );
    },
  );
}

Future<bool> _confirmPrivateDiscard(
  BuildContext context, {
  required String title,
  required String detail,
  String action = 'Discard staging',
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(scrollable: true, 
        title: Text(title),
        content: Text(AppStrings.of(context).message(detail)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(AppStrings.of(context).text('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(AppStrings.of(context).text(action)),
          ),
        ],
      ),
    ) ==
    true;

class _CohortPanel extends StatelessWidget {
  const _CohortPanel({
    required this.library,
    required this.state,
    required this.available,
    required this.closed,
  });
  final NotebookLibrary library;
  final CohortImportState state;
  final bool available;
  final bool closed;

  @override
  Widget build(BuildContext context) {
    if (!state.hasStaging &&
        !state.busy &&
        state.error == null &&
        state.message == null) {
      return const SizedBox.shrink();
    }
    final idle = available && !state.busy && !closed;
    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              AppStrings.of(context).text('Standalone files and assets'),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            if (state.busy) ...[
              const LinearProgressIndicator(),
              Text(AppStrings.of(context).text('Files: {name}…', {'name': (AppStrings.of(context).text(state.phase.name)).toString()})),
              TextButton(
                onPressed: closed ? null : library.cancelCohort,
                child: Text(AppStrings.of(context).text('Cancel files transfer')),
              ),
            ],
            if (state.error != null) SelectableText(AppStrings.of(context).message(state.error!)),
            if (state.message != null) SelectableText(AppStrings.of(context).message(state.message!)),
            for (final attempt in state.attempts)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${attempt.sourceName ?? AppStrings.of(context).text(attempt.kind.name)} → ${attempt.target.notebookRelative} / ${attempt.target.folderName}',
                    ),
                    SelectableText(
                      AppStrings.of(context).text('Notebook {notebookId}\nParent {parentId}', {'notebookId': (attempt.target.notebookId).toString(), 'parentId': (attempt.target.parentId).toString()}),
                    ),
                    Text(
                      AppStrings.of(context).text('{entries} entries · {bytes} bytes · {name}', {'entries': (attempt.entries).toString(), 'bytes': (attempt.bytes).toString(), 'name': (AppStrings.of(context).text(attempt.stage.name)).toString()}),
                    ),
                    if (attempt.cohortId != null)
                      SelectableText(
                        AppStrings.of(context).text('Stable imported root: {cohortId}', {'cohortId': (attempt.cohortId).toString()}),
                      ),
                    if (attempt.stage == TransferStage.quarantined ||
                        attempt.stage == TransferStage.intent)
                      Text(
                        AppStrings.of(context).text('Target notebook unavailable until its actual outcome is reconciled. Other notebooks may remain usable.'),
                      ),
                    Wrap(
                      spacing: 8,
                      children: [
                        if (attempt.stage != TransferStage.committed)
                          FilledButton(
                            onPressed: idle
                                ? () => library.retryCohort(attempt)
                                : null,
                            child: Text(switch (attempt.stage) {
                              TransferStage.receiving => AppStrings.of(context).text('Reselect source'),
                              TransferStage.captured =>
                                AppStrings.of(context).text('Prepare captured source'),
                              TransferStage.source =>
                                AppStrings.of(context).text('Prepare immutable folder'),
                              TransferStage.prepared =>
                                AppStrings.of(context).text('Apply to target folder'),
                              _ => AppStrings.of(context).text('Retry recovery'),
                            }),
                          ),
                        if (const [
                          TransferStage.receiving,
                          TransferStage.captured,
                          TransferStage.source,
                        ].contains(attempt.stage))
                          TextButton(
                            onPressed: idle
                                ? () async {
                                    final name = await showDialog<String>(
                                      context: context,
                                      builder: (_) => _CohortNameDialog(
                                        initial: attempt.target.folderName,
                                      ),
                                    );
                                    if (name != null &&
                                        library.value.cohortState.attempts.any(
                                          (item) => identical(item, attempt),
                                        )) {
                                      await library.renameCohortTarget(
                                        attempt,
                                        name,
                                      );
                                    }
                                  }
                                : null,
                            child: Text(AppStrings.of(context).text('Change new folder name')),
                          ),
                        TextButton(
                          onPressed: idle
                              ? () async {
                                  if (await _confirmPrivateDiscard(
                                        context,
                                        title: AppStrings.of(context).text('Discard files staging?'),
                                        detail:
                                            AppStrings.of(context).text('Recovery runs first if publication is unresolved. A committed folder is never deleted. Only proven private staging can be removed; ambiguous ownership stays quarantined.'),
                                      ) &&
                                      library.value.cohortState.attempts.any(
                                        (item) => identical(item, attempt),
                                      )) {
                                    await library.discardCohort(attempt);
                                  }
                                }
                              : null,
                          child: Text(AppStrings.of(context).text('Discard staging')),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            for (final item in state.leftovers)
              ListTile(
                title: Text(AppStrings.of(context).message(item.label)),
                subtitle: SelectableText('${AppStrings.of(context).message(item.reason)}\n${item.location}'),
                trailing: item.canDiscard
                    ? TextButton(
                        onPressed: idle
                            ? () async {
                                if (await _confirmPrivateDiscard(
                                  context,
                                  title: AppStrings.of(context).text('Discard private residue?'),
                                  detail: item.reason,
                                )) {
                                  await library.discardOfflineLeftover(
                                    item,
                                    cohort: true,
                                  );
                                }
                              }
                            : null,
                        child: Text(AppStrings.of(context).text('Discard')),
                      )
                    : null,
              ),
          ],
        ),
      ),
    );
  }
}

class _ResourceTransfersPanel extends StatelessWidget {
  const _ResourceTransfersPanel({
    required this.library,
    required this.state,
    required this.available,
    required this.closed,
  });
  final NotebookLibrary library;
  final ResourceTransferState state;
  final bool available;
  final bool closed;

  @override
  Widget build(BuildContext context) {
    if (!state.hasStaging &&
        !state.busy &&
        state.error == null &&
        state.message == null) {
      return const SizedBox.shrink();
    }
    final privateIdle = !state.busy && !closed && !library.value.busy && library.value.workspace == null;
    final idle = available && privateIdle;
    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              AppStrings.of(context).text('Retained file transfers'),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            if (state.busy) ...[
              const LinearProgressIndicator(),
              Text(AppStrings.of(context).text('Resources: {name}…', {'name': (AppStrings.of(context).text(state.phase.name)).toString()})),
              TextButton(
                onPressed: closed ? null : library.cancelResource,
                child: Text(AppStrings.of(context).text('Cancel resource transfer')),
              ),
            ],
            if (state.error != null) SelectableText(AppStrings.of(context).message(state.error!)),
            if (state.message != null) SelectableText(AppStrings.of(context).message(state.message!)),
            if (state.externalMayBeIncomplete)
              Text(
                AppStrings.of(context).text('A previous external Save As may already exist or be incomplete. Verify its destination before saving again.'),
              ),
            for (final attempt in state.attempts)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${AppStrings.of(context).text(attempt.operation.name)}: ${attempt.name}${attempt.newName == null ? '' : ' → ${attempt.newName}'} · ${AppStrings.of(context).text(attempt.stage.name)}',
                    ),
                    SelectableText(
                      AppStrings.of(context).text('Notebook {notebookId}\nNote {nodeId}', {'notebookId': (attempt.target.notebookId).toString(), 'nodeId': (attempt.target.nodeId).toString()}),
                    ),
                    if (attempt.stage == TransferStage.committed)
                      Text(
                        AppStrings.of(context).text('The file operation committed. No editor link is inserted by recovery. Open the note and explicitly insert a link; Write still controls source durability.'),
                      ),
                    if (state.listing?.notebookId ==
                            attempt.target.notebookId &&
                        state.listing?.nodeId == attempt.target.nodeId)
                      for (final entry in state.listing!.entries)
                        Text(
                          '${entry.name} · ${entry.tracked ? AppStrings.of(context).text('tracked') : AppStrings.of(context).text('unindexed')} · ${entry.exists ? AppStrings.of(context).text('{bytes} bytes', {'bytes': (entry.bytes).toString()}) : AppStrings.of(context).text('missing')}',
                        ),
                    Wrap(
                      spacing: 8,
                      children: [
                        if (attempt.stage == TransferStage.exportReady)
                          TextButton.icon(
                            onPressed: privateIdle ? () => library.shareResource(attempt) : null,
                            icon: const Icon(Icons.share_outlined),
                            label: Text(AppStrings.of(context).text('Share retained copy')),
                          ),
                        if (attempt.stage != TransferStage.exportUnavailable &&
                            (attempt.operation != ResourceOperation.export || attempt.origin == ResourceExportOrigin.asset))
                          TextButton(
                            onPressed: idle ? () => library.inspectResource(attempt) : null,
                            child: Text(AppStrings.of(context).text('Inspect actual resources')),
                          ),
                        if (attempt.stage == TransferStage.exportUnavailable)
                          Text(AppStrings.of(context).text('The immutable export source is unavailable. Only explicit private discard is allowed.')),
                        if (attempt.stage != TransferStage.committed && attempt.stage != TransferStage.exportUnavailable)
                          FilledButton(
                            onPressed: (attempt.stage == TransferStage.exportReady ? privateIdle : idle)
                                ? () => library.retryResource(attempt)
                                : null,
                            child: Text(
                              attempt.stage == TransferStage.exportReady
                                  ? AppStrings.of(context).text('Save As again')
                                  : AppStrings.of(context).text('Retry / recover'),
                            ),
                          ),
                        TextButton(
                          onPressed: (attempt.operation == ResourceOperation.export ? privateIdle : idle)
                              ? () async {
                                  if (await _confirmPrivateDiscard(
                                        context,
                                        title: AppStrings.of(context).text('Discard resource staging?'),
                                        detail:
                                            AppStrings.of(context).text('Only private staging is discarded. Committed attachments and images remain in the notebook. An unresolved live outcome must be recovered or explicitly abandoned.'),
                                      ) &&
                                      library.value.resourceState.attempts.any(
                                        (item) => identical(item, attempt),
                                      )) {
                                    await library.discardResource(attempt);
                                  }
                                }
                              : null,
                          child: Text(AppStrings.of(context).text('Discard staging')),
                        ),
                        if (attempt.stage == TransferStage.intent ||
                            attempt.stage == TransferStage.quarantined)
                          TextButton(
                            onPressed: idle
                                ? () async {
                                    if (await _confirmPrivateDiscard(
                                          context,
                                          title: AppStrings.of(context).text('Abandon private recovery records?'),
                                          detail:
                                              AppStrings.of(context).text('Inspect the listed actual resources first. The live outcome is ambiguous. Every live file, including an unexpected suffix copy, is preserved. Only private staging and recovery records are abandoned. Nothing is recopied, deleted live, or linked into source.'),
                                          action: AppStrings.of(context).text('Abandon private staging'),
                                        ) &&
                                        library.value.resourceState.attempts
                                            .any(
                                              (item) =>
                                                  identical(item, attempt),
                                            )) {
                                      await library.discardResource(
                                        attempt,
                                        abandon: true,
                                      );
                                    }
                                  }
                                : null,
                            child: Text(AppStrings.of(context).text('Abandon private staging')),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            for (final item in state.leftovers)
              ListTile(
                title: Text(AppStrings.of(context).message(item.label)),
                subtitle: SelectableText('${AppStrings.of(context).message(item.reason)}\n${item.location}'),
                trailing: item.canDiscard
                    ? TextButton(
                        onPressed: idle
                            ? () async {
                                if (await _confirmPrivateDiscard(
                                  context,
                                  title: AppStrings.of(context).text('Discard private residue?'),
                                  detail: item.reason,
                                )) {
                                  await library.discardOfflineLeftover(
                                    item,
                                    cohort: false,
                                  );
                                }
                              }
                            : null,
                        child: Text(AppStrings.of(context).text('Discard')),
                      )
                    : null,
              ),
          ],
        ),
      ),
    );
  }
}

class _CohortNameDialog extends StatefulWidget {
  const _CohortNameDialog({required this.initial});
  final String initial;
  @override
  State<_CohortNameDialog> createState() => _CohortNameDialogState();
}

class _CohortNameDialogState extends State<_CohortNameDialog> {
  late final _name = TextEditingController(text: widget.initial);
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(scrollable: true, 
    title: Text(AppStrings.of(context).text('New child folder name')),
    content: TextField(controller: _name, autofocus: true, autocorrect: false),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(AppStrings.of(context).text('Cancel')),
      ),
      FilledButton(
        onPressed: () {
          if (_name.text.trim().isNotEmpty) Navigator.pop(context, _name.text);
        },
        child: Text(AppStrings.of(context).text('Save name')),
      ),
    ],
  );
}

class _ImportPanel extends StatelessWidget {
  const _ImportPanel({
    required this.library,
    required this.state,
    required this.available,
    required this.closed,
  });
  final NotebookLibrary library;
  final NotebookImportState state;
  final bool available;
  final bool closed;
  Future<bool> _confirm(
    BuildContext context,
    String title,
    String detail,
    String action,
  ) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(scrollable: true, 
          title: Text(title),
          content: Text(AppStrings.of(context).message(detail)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(AppStrings.of(context).text('Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(AppStrings.of(context).text(action)),
            ),
          ],
        ),
      ) ==
      true;
  @override
  Widget build(BuildContext context) {
    final current = state.current;
    if (!state.busy &&
        !state.hasStaging &&
        state.error == null &&
        state.message == null) {
      return const SizedBox.shrink();
    }
    final idle = !closed && !state.busy;
    final canCommit =
        idle &&
        available &&
        current != null &&
        current.treeRelative != null &&
        current.inventoryHash != null;
    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (state.busy) ...[
              const LinearProgressIndicator(),
              Text(switch (state.phase) {
                NotebookImportPhase.receiving => current?.isWebDavClone == true
                    ? AppStrings.of(context).text('Downloading the WebDAV notebook into private staging…')
                    : AppStrings.of(context).text('Copying the selected source…'),
                NotebookImportPhase.validating =>
                  AppStrings.of(context).text('Validating notebook archive and paths…'),
                NotebookImportPhase.publishing =>
                  AppStrings.of(context).text('Validating identities and publishing notebook…'),
                NotebookImportPhase.finishing => AppStrings.of(context).text('Finishing published import…'),
                NotebookImportPhase.reconciling =>
                  AppStrings.of(context).text('Reconciling private import storage…'),
                _ => AppStrings.of(context).text('Working on import…'),
              }),
            ],
            if (current != null) ...[
              Text(
                AppStrings.of(context).text('Import: {value}', {'value': (current.notebookName ?? current.sourceName ?? AppStrings.of(context).text('Notebook source')).toString()}),
              ),
              Text(AppStrings.of(context).text('{entries} entries · {bytes} bytes', {'entries': (current.entries).toString(), 'bytes': (current.bytes).toString()})),
              if (current.isWebDavClone && !current.cloneComplete)
                Text(AppStrings.of(context).text('An incomplete WebDAV download cannot be resumed as a proved notebook. Discard its private staging before reconnecting.')),
              if (current.isWebDavClone && current.destination != null && !current.credentialsSettled)
                Text(AppStrings.of(context).text('The complete notebook is published and retained. Finish connection recovery before clearing its private publication receipt.')),
            ],
            if (state.error != null) SelectableText(AppStrings.of(context).message(state.error!)),
            if (state.message != null) SelectableText(AppStrings.of(context).message(state.message!)),
            if (state.busy &&
                state.phase != NotebookImportPhase.finishing &&
                state.phase != NotebookImportPhase.reconciling)
              TextButton(
                onPressed: closed ? null : library.cancelImport,
                child: Text(AppStrings.of(context).text('Cancel import')),
              ),
            if (current != null && !state.busy)
              Wrap(
                children: [
                  if (canCommit)
                    TextButton(
                      onPressed: () async {
                        if (await _confirm(
                              context,
                              current.isWebDavClone && current.destination != null ? AppStrings.of(context).text('Finish connection recovery?') : AppStrings.of(context).text('Import this notebook?'),
                              current.isWebDavClone && current.destination != null
                                ? AppStrings.of(context).text('The already-published notebook is retained while its credential and routing transaction finishes. No new copy is created.')
                                : AppStrings.of(context).text('The complete copy will be checked and registered with its original identities. Existing notebooks will not be overwritten or merged.'),
                              current.isWebDavClone && current.destination != null ? AppStrings.of(context).text('Finish connection') : AppStrings.of(context).text('Import notebook'),
                            ) &&
                            context.mounted &&
                            identical(
                              library.value.importState.current,
                              current,
                            ) &&
                            !library.value.closed) {
                          await library.commitImport(current);
                        }
                      },
                      child: Text(
                        current.destination == null ? AppStrings.of(context).text('Validate and import')
                            : current.isWebDavClone ? AppStrings.of(context).text('Finish connection') : AppStrings.of(context).text('Resume import'),
                      ),
                    ),
                  if (idle && current.treeRelative == null && (!current.isWebDavClone || current.cloneComplete))
                    TextButton(
                      onPressed: () => library.retryImport(current),
                      child: Text(AppStrings.of(context).text('Retry preparation')),
                    ),
                  TextButton(
                    onPressed: idle && !(current.isWebDavClone && current.destination != null && !current.credentialsSettled)
                        ? () async {
                            if (await _confirm(
                                  context,
                                  AppStrings.of(context).text('Discard this import?'),
                                  AppStrings.of(context).text('Remove this private staging and, only if ownership is proven, its unregistered published copy. Existing notebooks and the original source are not deleted.'),
                                  AppStrings.of(context).text('Discard import'),
                                ) &&
                                context.mounted &&
                                identical(
                                  library.value.importState.current,
                                  current,
                                ) &&
                                !library.value.importState.busy) {
                              await library.discardImport(current);
                            }
                          }
                        : null,
                    child: Text(AppStrings.of(context).text('Discard import')),
                  ),
                ],
              ),
            if (state.existingNotebookId != null)
              TextButton(
                onPressed: idle && available
                    ? library.openExistingImportNotebook
                    : null,
                child: Text(AppStrings.of(context).text('Open existing notebook')),
              ),
            for (final item in state.leftovers)
              ListTile(
                title: Text(item.label),
                subtitle: Text(AppStrings.of(context).message(item.reason)),
                trailing: IconButton(
                  tooltip: AppStrings.of(context).text('Discard import data {label}', {'label': (item.label).toString()}),
                  icon: const Icon(Icons.delete_outline),
                  onPressed: idle
                      ? () async {
                          if (await _confirm(
                                context,
                                AppStrings.of(context).text('Discard “{label}”?', {'label': (item.label).toString()}),
                                AppStrings.of(context).text('Only this private staging item may be removed. Ambiguous published roots remain quarantined.'),
                                AppStrings.of(context).text('Discard staging'),
                              ) &&
                              context.mounted &&
                              library.value.importState.leftovers.any(
                                (candidate) => identical(candidate, item),
                              ) &&
                              !library.value.importState.busy) {
                            await library.discardImportLeftover(item);
                          }
                        }
                      : null,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ExportPanel extends StatelessWidget {
  const _ExportPanel({
    required this.library,
    required this.state,
    required this.closed,
  });
  final NotebookLibrary library;
  final NotebookExportState state;
  final bool closed;

  Future<bool> _confirmDiscard(BuildContext context, String label) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(scrollable: true, 
          title: Text(AppStrings.of(context).text('Discard “{label}”?', {'label': (label).toString()})),
          content: Text(
            AppStrings.of(context).text('This removes only the selected app-private export copy or interrupted export data. It does not remove a notebook or a copy already saved to a provider.'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(AppStrings.of(context).text('Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(AppStrings.of(context).text('Discard')),
            ),
          ],
        ),
      ) ==
      true;

  @override
  Widget build(BuildContext context) {
    final prepared = state.prepared;
    if (!state.busy &&
        prepared == null &&
        state.leftovers.isEmpty &&
        state.error == null &&
        state.message == null) {
      return const SizedBox.shrink();
    }
    final idle = !closed && !state.busy && !library.value.busy && library.value.inboxReady;
    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (state.busy) ...[
              const LinearProgressIndicator(),
              Text(switch (state.phase) {
                NotebookExportPhase.reconciling =>
                  AppStrings.of(context).text('Updating private export storage…'),
                NotebookExportPhase.preparing =>
                  AppStrings.of(context).text('Preparing saved notebook snapshot…'),
                NotebookExportPhase.archiving => AppStrings.of(context).text('Creating ZIP copy…'),
                NotebookExportPhase.saving =>
                  AppStrings.of(context).text('Export in progress…'),
                NotebookExportPhase.idle => '',
              }),
            ],
            if (prepared != null) ...[
              Text(
                '${prepared.format == CoreExportFormat.notebook ? AppStrings.of(context).text('Notebook backup') : AppStrings.of(context).text('Files and assets')}: ${prepared.notebookName}',
              ),
              if (prepared.format == CoreExportFormat.filesAndAssets)
                Text(
                  AppStrings.of(context).text('Not a notebook backup. The entire vx_notebook directory (including unknown files), notebook identity, tags, configuration and configured recycle data are omitted.'),
                ),
              Text(
                AppStrings.of(context).text('{bytes} bytes · retained until saved or discarded', {'bytes': (prepared.bytes).toString()}),
              ),
            ],
            if (state.error != null) SelectableText(AppStrings.of(context).message(state.error!)),
            if (state.message != null) SelectableText(AppStrings.of(context).message(state.message!)),
            if (state.busy && state.phase != NotebookExportPhase.reconciling)
              TextButton(
                onPressed: closed ? null : library.cancelExport,
                child: Text(AppStrings.of(context).text('Cancel export')),
              ),
            if (prepared != null && !state.busy)
              Wrap(
                children: [
                  TextButton.icon(
                    onPressed: idle ? () => library.shareExport(prepared) : null,
                    icon: const Icon(Icons.share_outlined),
                    label: Text(AppStrings.of(context).text('Share')),
                  ),
                  TextButton.icon(
                    onPressed: idle ? () => library.saveExport(prepared) : null,
                    icon: const Icon(Icons.save_alt),
                    label: Text(AppStrings.of(context).text('Save export as…')),
                  ),
                  TextButton(
                    onPressed: idle
                        ? () async {
                            if (await _confirmDiscard(
                                  context,
                                  prepared.notebookName,
                                ) &&
                                context.mounted &&
                                !library.value.closed &&
                                !library.value.exportState.busy &&
                                identical(
                                  library.value.exportState.prepared,
                                  prepared,
                                )) {
                              await library.discardExport(prepared);
                            }
                          }
                        : null,
                    child: Text(AppStrings.of(context).text('Discard export')),
                  ),
                ],
              ),
            for (final leftover in state.leftovers)
              ListTile(
                title: Text(leftover.label),
                subtitle: Text(AppStrings.of(context).message(leftover.reason)),
                trailing: IconButton(
                  tooltip: AppStrings.of(context).text('Discard export data {label}', {'label': (leftover.label).toString()}),
                  icon: const Icon(Icons.delete_outline),
                  onPressed: idle
                      ? () async {
                          if (await _confirmDiscard(context, leftover.label) &&
                              context.mounted &&
                              !library.value.closed &&
                              !library.value.exportState.busy &&
                              library.value.exportState.leftovers.any(
                                (item) => identical(item, leftover),
                              )) {
                            await library.discardExportLeftover(leftover);
                          }
                        }
                      : null,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _NewNotebookDialog extends StatefulWidget {
  const _NewNotebookDialog();

  @override
  State<_NewNotebookDialog> createState() => _NewNotebookDialogState();
}

class _NewNotebookDialogState extends State<_NewNotebookDialog> {
  final _controller = TextEditingController();
  final _form = GlobalKey<FormState>();

  void _submit() {
    if (_form.currentState!.validate()) {
      Navigator.pop(context, _controller.text);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(scrollable: true, 
    title: Text(AppStrings.of(context).text('New notebook')),
    content: Form(
      key: _form,
      child: TextFormField(
        controller: _controller,
        autofocus: true,
        autocorrect: false,
        decoration: InputDecoration(labelText: AppStrings.of(context).text('Name')),
        validator: (value) =>
            value == null || value.trim().isEmpty ? AppStrings.of(context).text('Enter a name.') : null,
        onFieldSubmitted: (_) => _submit(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(AppStrings.of(context).text('Cancel')),
      ),
      FilledButton(onPressed: _submit, child: Text(AppStrings.of(context).text('Create'))),
    ],
  );
}
