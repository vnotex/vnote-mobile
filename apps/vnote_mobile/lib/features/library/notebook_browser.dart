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
    required this.onShowNotebooks,
    super.key,
  });

  final NotebookWorkspace workspace;
  final bool dark;
  final ValueChanged<bool> onThemeChanged;
  final VoidCallback onShowNotebooks;

  @override
  State<NotebookBrowser> createState() => _NotebookBrowserState();
}

class _NotebookBrowserState extends State<NotebookBrowser> {
  NotebookWorkspace get _workspace => widget.workspace;
  bool _showSearch = false;

  void _closeSearch() {
    _workspace.clearSearch();
    setState(() => _showSearch = false);
  }

  bool _stillCurrent(CoreDirectory directory) =>
      mounted &&
      identical(_workspace.value.directory, directory) &&
      _workspace.value.canMutate;

  Future<String?> _nameDialog({
    required String title,
    String initial = '',
    bool note = false,
    bool notebook = false,
  }) => showDialog<String>(
    context: context,
    builder: (context) => _NameDialog(
      title: title,
      initial: initial,
      note: note,
      notebook: notebook,
    ),
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

  Future<void> _renameNotebook(CoreDirectory directory) async {
    if (!_stillCurrent(directory)) return;
    final name = await _nameDialog(
      title: 'Rename notebook',
      initial: directory.notebookName,
      notebook: true,
    );
    if (name == null || !_stillCurrent(directory)) return;
    await _workspace.renameNotebook(name);
  }

  Future<void> _action(CoreEntry entry, String action) async {
    final directory = _workspace.value.directory!;
    switch (action) {
      case 'tags':
        final saved = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => _TagDialog(workspace: _workspace, entry: entry),
        );
        if (saved == true && mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('Tags saved.')));
        }
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
        canPop: !_showSearch && !state.busy && directory?.parentId == null,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) return;
          if (_showSearch) {
            _closeSearch();
          } else if (state.canBrowse && directory?.parentId != null) {
            unawaited(_workspace.navigate(directory!.parentId));
          }
        },
        child: Scaffold(
          appBar: AppBar(
            title: Text(directory?.notebookName ?? 'Notebook'),
            leading: IconButton(
              tooltip: 'Notebooks',
              onPressed: state.canBrowse ? widget.onShowNotebooks : null,
              icon: const Icon(Icons.library_books_outlined),
            ),
            actions: [
              IconButton(
                tooltip: 'Rename notebook',
                onPressed: state.canMutate
                    ? () => _renameNotebook(directory!)
                    : null,
                icon: const Icon(Icons.drive_file_rename_outline),
              ),
              IconButton(
                tooltip: 'Search notebook',
                onPressed: state.canMutate && !_showSearch
                    ? () => setState(() => _showSearch = true)
                    : null,
                icon: const Icon(Icons.search),
              ),
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
                if (!_showSearch)
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
                if (!_showSearch)
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      IconButton(
                        tooltip: 'Up one folder',
                        onPressed:
                            state.canBrowse && directory?.parentId != null
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
                  child: _showSearch
                      ? _SearchPanel(
                          workspace: _workspace,
                          state: state,
                          onClose: _closeSearch,
                        )
                      : directory == null
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
                                itemBuilder: (context) => [
                                  if (!entry.isFolder)
                                    const PopupMenuItem(
                                      value: 'tags',
                                      child: Text('Tags'),
                                    ),
                                  const PopupMenuItem(
                                    value: 'rename',
                                    child: Text('Rename'),
                                  ),
                                  const PopupMenuItem(
                                    value: 'move',
                                    child: Text('Move'),
                                  ),
                                  const PopupMenuItem(
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

class _SearchPanel extends StatefulWidget {
  const _SearchPanel({
    required this.workspace,
    required this.state,
    required this.onClose,
  });

  final NotebookWorkspace workspace;
  final NotebookWorkspaceState state;
  final VoidCallback onClose;

  @override
  State<_SearchPanel> createState() => _SearchPanelState();
}

class _SearchPanelState extends State<_SearchPanel> {
  final _text = TextEditingController();
  CoreTags? _tags;
  String? _tag;
  String? _tagsError;
  bool _caseSensitive = false;
  bool _loadingTags = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_loadTags());
    });
  }

  Future<void> _loadTags() async {
    widget.workspace.clearSearch();
    setState(() {
      _loadingTags = true;
      _tagsError = null;
    });
    try {
      final tags = await widget.workspace.loadTags();
      if (!mounted) return;
      setState(() {
        _tags = tags;
        if (!tags.tags.any((tag) => tag.name == _tag)) _tag = null;
      });
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _tags = null;
          _tag = null;
          _tagsError = NotebookWorkspace.describeError(error);
        });
      }
    } finally {
      if (mounted) setState(() => _loadingTags = false);
    }
  }

  void _submit() {
    if (!widget.state.canMutate || _loadingTags) return;
    FocusScope.of(context).unfocus();
    unawaited(
      widget.workspace.search(
        _text.text,
        tag: _tag,
        caseSensitive: _caseSensitive,
      ),
    );
  }

  void _clear() {
    _text.clear();
    setState(() {
      _tag = null;
      _caseSensitive = false;
    });
    widget.workspace.clearSearch();
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final result = state.search;
    final editable = state.canMutate || state.searching;
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: 1 + (result?.matches.length ?? 0),
      itemBuilder: (context, index) {
        if (index != 0) {
          final currentResult = result!;
          final hit = currentResult.matches[index - 1];
          return ListTile(
            key: ValueKey('search-${hit.id}'),
            leading: const Icon(Icons.description_outlined),
            title: Text(hit.path),
            subtitle: hit.line == 0
                ? const Text('Matches selected tag')
                : Text('Line ${hit.line}: ${hit.snippet}'),
            onTap: state.canMutate
                ? () => widget.workspace.openSearchHit(currentResult, hit)
                : null,
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Search saved Markdown and text notes throughout this notebook. '
              'Unsaved editor changes are not searched.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _text,
              enabled: editable,
              autocorrect: false,
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(labelText: 'Search text'),
              onChanged: (_) => widget.workspace.clearSearch(),
              onSubmitted: (_) => _submit(),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Case sensitive'),
              value: _caseSensitive,
              onChanged: editable
                  ? (value) {
                      setState(() => _caseSensitive = value!);
                      widget.workspace.clearSearch();
                    }
                  : null,
            ),
            InputDecorator(
              decoration: const InputDecoration(labelText: 'Filter by tag'),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _tag ?? '',
                  isExpanded: true,
                  items: [
                    const DropdownMenuItem(value: '', child: Text('Any tag')),
                    for (final tag in _tags?.tags ?? <CoreTag>[])
                      DropdownMenuItem(
                        value: tag.name,
                        child: Text(
                          _tagLabel(tag),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: editable && !_loadingTags && _tagsError == null
                      ? (value) {
                          setState(() => _tag = value == '' ? null : value);
                          widget.workspace.clearSearch();
                        }
                      : null,
                ),
              ),
            ),
            if (_loadingTags) const Text('Loading tag filters…'),
            if (_tagsError != null) ...[
              SelectableText('Tag filters could not load: $_tagsError'),
              TextButton(
                onPressed: state.canMutate ? _loadTags : null,
                child: const Text('Retry tag filters'),
              ),
            ],
            Wrap(
              spacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: state.canMutate && !_loadingTags ? _submit : null,
                  icon: const Icon(Icons.search),
                  label: const Text('Search'),
                ),
                if (state.searching)
                  TextButton(
                    onPressed: state.searchCancelled
                        ? null
                        : widget.workspace.cancelSearch,
                    child: const Text('Cancel search'),
                  ),
                TextButton(
                  onPressed: _clear,
                  child: const Text('Clear search'),
                ),
                TextButton(
                  onPressed: widget.onClose,
                  child: const Text('Back to folders'),
                ),
              ],
            ),
            if (state.searching)
              Text(
                state.searchCancelled
                    ? 'Cancelling search…'
                    : 'Searching saved notes…',
              )
            else if (state.searchCancelled)
              const Text('Search cancelled.'),
            if (state.searchError != null)
              SelectableText('Search failed: ${state.searchError}'),
            if (result != null) ...[
              Text(
                result.matches.isEmpty
                    ? 'No matching notes.'
                    : '${result.matches.length} matching notes.',
              ),
              if (result.limited)
                const Text(
                  'Results are incomplete: the search limit was reached. Narrow your search.',
                ),
              if (result.skipped != 0)
                Text(
                  '${result.skipped} unsupported or unavailable notes were skipped.',
                ),
            ],
          ],
        );
      },
    );
  }
}

String _tagLabel(CoreTag tag) =>
    tag.parent.isEmpty ? tag.name : '${tag.name} (parent: ${tag.parent})';

class _TagDialog extends StatefulWidget {
  const _TagDialog({required this.workspace, required this.entry});

  final NotebookWorkspace workspace;
  final CoreEntry entry;

  @override
  State<_TagDialog> createState() => _TagDialogState();
}

class _TagDialogState extends State<_TagDialog> {
  CoreTags? _tags;
  Set<String> _selected = {};
  bool _busy = true;
  String? _error;
  String? _message;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _tags = null;
      _error = null;
      _message = null;
    });
    try {
      final tags = await widget.workspace.loadTags(widget.entry);
      if (!mounted) return;
      setState(() {
        _tags = tags;
        _selected = tags.assigned.toSet();
      });
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = NotebookWorkspace.describeError(error));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() async {
    final snapshot = _tags;
    if (snapshot == null || _busy || _error != null) return;
    final name = await showDialog<String>(
      context: context,
      builder: (context) =>
          const _NameDialog(title: 'New tag', initial: '', note: false),
    );
    if (name == null || !mounted) return;
    await _write(createName: name);
  }

  Future<void> _write({String? createName}) async {
    final snapshot = _tags;
    if (snapshot == null || _busy || _error != null) return;
    final selection = _selected.toSet();
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      final result = createName == null
          ? await widget.workspace.setTags(
              widget.entry,
              snapshot,
              selection.toList(),
            )
          : await widget.workspace.createTag(
              widget.entry,
              snapshot,
              createName,
            );
      if (!mounted) return;
      if (result == null) {
        setState(() {
          _tags = null;
          _error = 'The tag snapshot is no longer current. Reload tags before saving.';
        });
        return;
      }
      if (createName == null && result.applied && result.refreshError == null) {
        Navigator.pop(context, true);
        return;
      }
      setState(() {
        _tags = result.tags;
        if (result.tags != null) {
          _selected = createName == null
              ? result.tags!.assigned.toSet()
              : selection;
          if (createName != null && result.applied) _selected.add(createName);
        }
        _message = result.applied
            ? result.refreshError == null
                  ? 'Tag created. Select assignments and Save to apply them to this note.'
                  : '${createName == null ? 'Tags saved' : 'Tag created'}, but tags could not be refreshed. The change was not rolled back.'
            : null;
        final errors = [
          if (result.error != null) 'Change failed: ${result.error}',
          if (result.refreshError != null)
            'Refresh failed: ${result.refreshError}',
        ];
        _error = errors.isEmpty ? null : errors.join('\n');
      });
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _tags = null;
          _error = NotebookWorkspace.describeError(error);
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(
    BuildContext context,
  ) => ValueListenableBuilder<NotebookWorkspaceState>(
    valueListenable: widget.workspace,
    builder: (context, state, _) {
      final tags = _tags;
      final definitions = {
        for (final tag in tags?.tags ?? <CoreTag>[]) tag.name: tag,
      };
      final names = {
        ...definitions.keys,
        ...?tags?.assigned,
        ..._selected,
      }.toList()..sort();
      final canSave =
          !_busy && tags != null && _error == null && state.canMutate;
      return PopScope<Object?>(
        canPop: !_busy,
        child: AlertDialog(
          title: Text('Tags for “${widget.entry.name}”'),
          content: SizedBox(
            width: 420,
            height: 360,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_busy) const LinearProgressIndicator(),
                if (_message != null || _error != null)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 140),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        [_message, _error].whereType<String>().join('\n'),
                      ),
                    ),
                  ),
                Wrap(
                  children: [
                    TextButton(
                      onPressed: canSave ? _create : null,
                      child: const Text('Create tag'),
                    ),
                    TextButton(
                      onPressed: !_busy && state.canMutate ? _load : null,
                      child: const Text('Reload tags'),
                    ),
                  ],
                ),
                Expanded(
                  child: tags == null
                      ? Text(
                          _busy
                              ? 'Loading tags…'
                              : 'Complete tag data is required before saving.',
                        )
                      : names.isEmpty
                      ? const Text('No tags yet. Create a tag to get started.')
                      : ListView.builder(
                          itemCount: names.length,
                          itemBuilder: (context, index) {
                            final name = names[index];
                            final definition = definitions[name];
                            return CheckboxListTile(
                              title: Text(name),
                              subtitle: definition == null
                                  ? const Text(
                                      'Existing assignment without a definition; kept unless unchecked.',
                                    )
                                  : definition.parent.isNotEmpty
                                  ? Text('Parent: ${definition.parent}')
                                  : null,
                              value: _selected.contains(name),
                              onChanged: canSave
                                  ? (selected) {
                                      setState(() {
                                        if (selected!) {
                                          _selected.add(name);
                                        } else {
                                          _selected.remove(name);
                                        }
                                      });
                                    }
                                  : null,
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: _busy ? null : () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: canSave ? () => _write() : null,
              child: const Text('Save'),
            ),
          ],
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
    this.notebook = false,
  });

  final String title;
  final String initial;
  final bool note;
  final bool notebook;

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
          helperMaxLines: widget.notebook ? 3 : null,
          helperText: widget.note
              ? 'Include .md (Markdown) or .txt (plain text).'
              : widget.notebook
              ? 'Display name only. The notebook folder is not renamed.'
              : null,
        ),
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
