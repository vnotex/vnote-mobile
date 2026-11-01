// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:vxcore_bridge/vxcore_bridge.dart';

import '../../services/notebook_workspace.dart';
import '../about/license_sheet.dart';

class NotebookBrowser extends StatefulWidget {
  const NotebookBrowser({
    required this.workspace,
    required this.dark,
    required this.onThemeChanged,
    super.key,
  });

  final NotebookWorkspace workspace;
  final bool dark;
  final ValueChanged<bool> onThemeChanged;

  @override
  State<NotebookBrowser> createState() => _NotebookBrowserState();
}

class _NotebookBrowserState extends State<NotebookBrowser> {
  NotebookWorkspace get _workspace => widget.workspace;

  bool _stillCurrent(CoreDirectory directory) =>
      mounted &&
      identical(_workspace.value.directory, directory) &&
      _workspace.value.canMutate;

  Future<String?> _nameDialog({
    required String title,
    String initial = '',
    bool note = false,
  }) => showDialog<String>(
    context: context,
    builder: (context) =>
        _NameDialog(title: title, initial: initial, note: note),
  );

  Future<void> _create({required bool folder}) async {
    final directory = _workspace.value.directory!;
    final name = await _nameDialog(
      title: folder ? 'New folder' : 'New note',
      note: !folder,
    );
    if (name == null || !_stillCurrent(directory)) return;
    if (folder) {
      await _workspace.createFolder(name);
    } else {
      await _workspace.createNote(name);
    }
  }

  Future<void> _action(CoreEntry entry, String action) async {
    final directory = _workspace.value.directory!;
    switch (action) {
      case 'rename':
        final name = await _nameDialog(title: 'Rename', initial: entry.name);
        if (name != null && _stillCurrent(directory)) {
          await _workspace.rename(entry, name);
        }
      case 'move':
        final destination = await showDialog<String>(
          context: context,
          builder: (context) => _FolderPicker(
            workspace: _workspace,
            source: entry,
            sourcePath: _childPath(directory.path, entry.name),
          ),
        );
        if (destination != null && _stillCurrent(directory)) {
          await _workspace.move(entry, destination);
        }
      case 'delete':
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Delete “${entry.name}”?'),
            content: Text(
              '${entry.isFolder ? 'This includes the folder and its contents. ' : ''}'
              'The core tries to recycle deleted content, but may permanently '
              'delete it if recycling fails. This app does not provide undo or restore.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
        if (confirmed == true && _stillCurrent(directory)) {
          await _workspace.delete(entry);
        }
    }
  }

  @override
  Widget build(
    BuildContext context,
  ) => ValueListenableBuilder<NotebookWorkspaceState>(
    valueListenable: _workspace,
    builder: (context, state, _) {
      final directory = state.directory;
      final mutation = state.mutation;
      final messages = <String>[
        if (state.error != null) state.error!,
        if (mutation != null && mutation.applied)
          mutation.refreshError == null ? 'Change applied.' : 'Change applied, but the folder could not be refreshed. It was not rolled back.',
        if (mutation?.error != null) 'Change failed: ${mutation!.error}',
        if (mutation?.refreshError != null)
          'Refresh failed: ${mutation!.refreshError}',
        if (state.stale && directory != null) 'This is the last known folder listing. Refresh before changing or opening notes.',
      ];
      return PopScope<Object?>(
        canPop: !state.busy && directory?.parentId == null,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop && state.canBrowse && directory?.parentId != null) {
            unawaited(_workspace.navigate(directory!.parentId));
          }
        },
        child: Scaffold(
          appBar: AppBar(
            title: Text(directory?.notebookName ?? 'Personal'),
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
              IconButton(
                tooltip: 'Legal notices',
                onPressed: () =>
                    showNotebookLicenses(context, _workspace.nativeNotices),
                icon: const Icon(Icons.info_outline),
              ),
            ],
          ),
          body: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (state.busy) const LinearProgressIndicator(),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: SelectableText(
                    directory == null
                        ? 'Managed notebook'
                        : directory.path == '.'
                        ? '/'
                        : directory.path,
                  ),
                ),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    IconButton(
                      tooltip: 'Up one folder',
                      onPressed: state.canBrowse && directory?.parentId != null
                          ? () => _workspace.navigate(directory!.parentId)
                          : null,
                      icon: const Icon(Icons.arrow_upward),
                    ),
                    TextButton(
                      onPressed: state.canBrowse
                          ? () => _workspace.navigate(null)
                          : null,
                      child: const Text('Root'),
                    ),
                    IconButton(
                      tooltip: 'Refresh',
                      onPressed: state.canBrowse ? _workspace.refresh : null,
                      icon: const Icon(Icons.refresh),
                    ),
                    TextButton.icon(
                      onPressed: state.canMutate
                          ? () => _create(folder: false)
                          : null,
                      icon: const Icon(Icons.note_add_outlined),
                      label: const Text('New note'),
                    ),
                    TextButton.icon(
                      onPressed: state.canMutate
                          ? () => _create(folder: true)
                          : null,
                      icon: const Icon(Icons.create_new_folder_outlined),
                      label: const Text('New folder'),
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
                  child: directory == null
                      ? Center(
                          child: Text(
                            state.busy ? 'Opening managed notebook…' : 'The notebook could not open. Use Refresh to retry.',
                          ),
                        )
                      : directory.entries.isEmpty
                      ? const Center(child: Text('This folder is empty.'))
                      : ListView.builder(
                          itemCount: directory.entries.length,
                          itemBuilder: (context, index) {
                            final entry = directory.entries[index];
                            final markers = <String>[
                              if (!entry.exists) 'Missing content',
                              if (entry.encrypted) 'Encrypted',
                              if (entry.isFolder) 'Folder',
                            ];
                            return ListTile(
                              key: ValueKey(entry.id),
                              leading: Icon(
                                entry.isFolder
                                    ? Icons.folder_outlined
                                    : Icons.description_outlined,
                              ),
                              title: Text(entry.name),
                              subtitle: markers.isEmpty
                                  ? null
                                  : Text(markers.join(' · ')),
                              onTap: !state.canMutate
                                  ? null
                                  : () {
                                      if (entry.isFolder) {
                                        unawaited(
                                          _workspace.navigate(entry.id),
                                        );
                                      } else {
                                        unawaited(_workspace.openNote(entry));
                                      }
                                    },
                              trailing: PopupMenuButton<String>(
                                tooltip: 'Actions for ${entry.name}',
                                enabled: state.canMutate,
                                onSelected: (action) => _action(entry, action),
                                itemBuilder: (context) => const [
                                  PopupMenuItem(
                                    value: 'rename',
                                    child: Text('Rename'),
                                  ),
                                  PopupMenuItem(
                                    value: 'move',
                                    child: Text('Move'),
                                  ),
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: Text('Delete'),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({
    required this.title,
    required this.initial,
    required this.note,
  });

  final String title;
  final String initial;
  final bool note;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _controller = TextEditingController(text: widget.initial);
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
    title: Text(widget.title),
    content: Form(
      key: _form,
      child: TextFormField(
        controller: _controller,
        autofocus: true,
        autocorrect: false,
        decoration: InputDecoration(
          labelText: 'Name',
          helperText: widget.note
              ? 'Include .md (Markdown) or .txt (plain text).'
              : null,
        ),
        validator: (value) =>
            value == null || value.isEmpty ? 'Enter a name.' : null,
        onFieldSubmitted: (_) => _submit(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Save')),
    ],
  );
}

String _childPath(String parent, String name) =>
    parent == '.' ? name : '$parent/$name';

class _FolderPicker extends StatefulWidget {
  const _FolderPicker({
    required this.workspace,
    required this.source,
    required this.sourcePath,
  });

  final NotebookWorkspace workspace;
  final CoreEntry source;
  final String sourcePath;

  @override
  State<_FolderPicker> createState() => _FolderPickerState();
}

class _FolderPickerState extends State<_FolderPicker> {
  CoreDirectory? _directory;
  bool _loading = true;
  String? _error;
  String? _requestedFolder;

  bool _excluded(String path) =>
      widget.source.isFolder &&
      (path == widget.sourcePath || path.startsWith('${widget.sourcePath}/'));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load(null));
    });
  }

  Future<void> _load(String? folderId) async {
    setState(() {
      _loading = true;
      _error = null;
      _requestedFolder = folderId;
    });
    try {
      final directory = await widget.workspace.listDestination(folderId);
      if (!mounted) return;
      setState(() => _directory = directory);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = NotebookWorkspace.describeError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final directory = _directory;
    final folders =
        directory?.entries.where((entry) => entry.isFolder).toList() ??
        <CoreEntry>[];
    return AlertDialog(
      title: Text('Move “${widget.source.name}”'),
      content: SizedBox(
        width: 420,
        height: 360,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_loading) const LinearProgressIndicator(),
            Text(
              directory == null || directory.path == '.' ? '/' : directory.path,
            ),
            Wrap(
              children: [
                TextButton(
                  onPressed: _loading ? null : () => _load(null),
                  child: const Text('Root'),
                ),
                TextButton(
                  onPressed: !_loading && directory?.parentId != null
                      ? () => _load(directory!.parentId)
                      : null,
                  child: const Text('Up'),
                ),
                TextButton(
                  onPressed: _loading ? null : () => _load(_requestedFolder),
                  child: const Text('Refresh'),
                ),
              ],
            ),
            if (_error != null)
              Flexible(
                child: SingleChildScrollView(child: SelectableText(_error!)),
              ),
            Expanded(
              child: ListView.builder(
                itemCount: folders.length,
                itemBuilder: (context, index) {
                  final entry = folders[index];
                  final excluded = _excluded(
                    _childPath(directory!.path, entry.name),
                  );
                  return ListTile(
                    key: ValueKey(entry.id),
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(entry.name),
                    subtitle: Text(
                      excluded
                          ? 'Cannot move into this folder or its descendants'
                          : !entry.exists
                          ? 'Missing content'
                          : 'Folder',
                    ),
                    onTap: _loading || _error != null || excluded
                        ? null
                        : () => _load(entry.id),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _loading ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed:
              !_loading &&
                  _error == null &&
                  directory != null &&
                  !_excluded(directory.path)
              ? () => Navigator.pop(context, directory.folderId)
              : null,
          child: const Text('Move here'),
        ),
      ],
    );
  }
}
