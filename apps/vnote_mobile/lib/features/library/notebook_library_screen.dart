// SPDX-License-Identifier: LGPL-3.0-only
import 'package:flutter/material.dart';

import '../../services/notebook_library.dart';

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
                child: state.entries.isEmpty
                    ? Center(
                        child: Text(
                          state.busy
                              ? 'Loading notebooks…'
                              : state.closed
                              ? 'Library closed.'
                              : state.stale
                              ? 'The notebook library is unavailable.'
                              : 'No notebooks yet. Choose New notebook to create one.',
                        ),
                      )
                    : ListView.builder(
                        itemCount: state.entries.length,
                        itemBuilder: (context, index) {
                          final entry = state.entries[index];
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
