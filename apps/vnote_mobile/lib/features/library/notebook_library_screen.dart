// SPDX-License-Identifier: LGPL-3.0-only
import 'package:flutter/material.dart';

import '../../services/notebook_library.dart';
import '../../services/notebook_export.dart';

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

  Future<void> _export(
    NotebookLibrary library,
    NotebookLibraryState snapshot,
    ManagedNotebookEntry entry,
  ) async {
    if (!_isCurrent(library, snapshot)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Export “${entry.name}”?'),
        content: const Text(
          'Save a ZIP copy of the saved notebook, including attachments and recycle content. The ZIP itself is not encrypted. Local sync history/state is excluded; the notebook is not changed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Export ZIP'),
          ),
        ],
      ),
    );
    if (confirmed == true && _isCurrent(library, snapshot)) {
      await library.exportNotebook(entry);
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
        'Local notebooks need your own exported copies. OS backup exclusion is requested, not guaranteed; app removal or device loss may remove local data.',
        if (state.error != null) state.error!,
        if (state.closed) 'The notebook library is closed.',
        if (state.stale && !state.closed && !state.busy)
          'Refresh the library before creating or opening a notebook.',
      ];
      return Scaffold(
        appBar: AppBar(
          title: const Text('Notebooks'),
          actions: [
            IconButton(
              tooltip: widget.dark ? 'Use light theme' : 'Use dark theme',
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (state.busy) const LinearProgressIndicator(),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  IconButton(
                    tooltip: 'Refresh',
                    onPressed: idle ? library.refresh : null,
                    icon: const Icon(Icons.refresh),
                  ),
                  TextButton.icon(
                    onPressed: available ? () => _create(library, state) : null,
                    icon: const Icon(Icons.add),
                    label: const Text('New notebook'),
                  ),
                ],
              ),
              if (messages.isNotEmpty)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 180),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(messages.join('\n')),
                  ),
                ),
              Expanded(
                child: ListView.builder(
                  itemCount:
                      (state.entries.isEmpty ? 1 : state.entries.length) + 1,
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return _ExportPanel(
                        library: library,
                        state: state.exportState,
                        closed: state.closed,
                      );
                    }
                    if (state.entries.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          state.busy
                              ? 'Loading notebooks…'
                              : state.closed
                              ? 'Library closed.'
                              : state.stale
                              ? 'The notebook library is unavailable.'
                              : 'No notebooks yet. Choose New notebook to create one.',
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
                              'Unavailable: ${entry.error ?? 'The notebook could not be opened.'}',
                            ),
                      trailing: IconButton(
                        tooltip: 'Export ${entry.name}',
                        icon: const Icon(Icons.ios_share),
                        onPressed:
                            available &&
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
          ),
        ),
      );
    },
  );
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
        builder: (context) => AlertDialog(
          title: Text('Discard “$label”?'),
          content: const Text(
            'This removes only the selected app-private export copy or interrupted export data. It does not remove a notebook or a copy already saved to a provider.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Discard'),
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
    final idle = !closed && !state.busy;
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
                  'Updating private export storage…',
                NotebookExportPhase.preparing =>
                  'Preparing saved notebook snapshot…',
                NotebookExportPhase.archiving => 'Creating ZIP copy…',
                NotebookExportPhase.saving =>
                  'Saving to the selected provider…',
                NotebookExportPhase.idle => '',
              }),
            ],
            if (prepared != null) ...[
              Text('Prepared export: ${prepared.notebookName}'),
              Text(
                '${prepared.bytes} bytes · retained until saved or discarded',
              ),
            ],
            if (state.error != null) SelectableText(state.error!),
            if (state.message != null) SelectableText(state.message!),
            if (state.busy && state.phase != NotebookExportPhase.reconciling)
              TextButton(
                onPressed: closed ? null : library.cancelExport,
                child: const Text('Cancel export'),
              ),
            if (prepared != null && !state.busy)
              Wrap(
                children: [
                  TextButton.icon(
                    onPressed: idle ? () => library.saveExport(prepared) : null,
                    icon: const Icon(Icons.save_alt),
                    label: const Text('Save export as…'),
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
                    child: const Text('Discard export'),
                  ),
                ],
              ),
            for (final leftover in state.leftovers)
              ListTile(
                title: Text(leftover.label),
                subtitle: Text(leftover.reason),
                trailing: IconButton(
                  tooltip: 'Discard export data ${leftover.label}',
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
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('New notebook'),
    content: Form(
      key: _form,
      child: TextFormField(
        controller: _controller,
        autofocus: true,
        autocorrect: false,
        decoration: const InputDecoration(labelText: 'Name'),
        validator: (value) =>
            value == null || value.trim().isEmpty ? 'Enter a name.' : null,
        onFieldSubmitted: (_) => _submit(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Create')),
    ],
  );
}
