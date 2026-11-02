// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:vxcore_bridge/vxcore_bridge.dart';

import '../../services/editor_session.dart';
import '../../services/notebook_library.dart';
import '../../services/notebook_session.dart';
import '../../services/notebook_workspace.dart';
import '../../services/resource_transfer.dart';

/// The core supplies an unencoded, validated note-relative path. Encode each
/// segment exactly once; source is never interpolated into HTML or JavaScript.
String resourceMarkdownLink({
  required String name,
  required String relativeUrl,
  bool image = false,
}) {
  final segments = relativeUrl.split('/');
  if (relativeUrl.isEmpty ||
      relativeUrl.startsWith('/') ||
      relativeUrl.contains('\\') ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(relativeUrl) ||
      segments.any(
        (segment) => segment.isEmpty || segment == '.' || segment == '..',
      ) ||
      segments.first.contains(':')) {
    throw StateError('The resource did not provide a safe note-relative URL.');
  }
  final url = segments
      .map(
        (segment) => Uri.encodeComponent(segment).replaceAllMapped(
          RegExp(r"[!'()*]"),
          (match) =>
              '%${match[0]!.codeUnitAt(0).toRadixString(16).toUpperCase()}',
        ),
      )
      .join('/');
  final label = StringBuffer();
  for (final rune in name.runes) {
    if (rune < 32 || rune == 127) {
      label.write(' ');
    } else {
      if ((rune >= 33 && rune <= 47) ||
          (rune >= 58 && rune <= 64) ||
          (rune >= 91 && rune <= 96) ||
          (rune >= 123 && rune <= 126)) {
        label.write('\\');
      }
      label.writeCharCode(rune);
    }
  }
  return '${image ? '!' : ''}[$label]($url)';
}

class ResourcePanel extends StatefulWidget {
  const ResourcePanel({
    required this.library,
    required this.workspace,
    required this.session,
    required this.editor,
    required this.send,
    super.key,
  });
  final NotebookLibrary library;
  final NotebookWorkspace workspace;
  final NotebookSession session;
  final EditorSession editor;
  final EditorSend send;

  @override
  State<ResourcePanel> createState() => _ResourcePanelState();
}

class _ResourcePanelState extends State<ResourcePanel> {
  bool _inserting = false;
  String? _message;
  bool get _current =>
      mounted &&
      identical(widget.library.value.workspace, widget.workspace) &&
      identical(widget.workspace.value.session, widget.session) &&
      identical(widget.session.value.editor, widget.editor) &&
      !widget.session.value.closed;
  bool get _markdown =>
      widget.session.value.note?.editorType == CoreEditorType.markdown;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_current) unawaited(_refresh());
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (!_current) return;
    try {
      await action();
    } on Object catch (error) {
      if (_current) {
        setState(() => _message = NotebookWorkspace.describeError(error));
      }
    }
  }

  Future<void> _refresh() => _run(
    () => widget.library.refreshResources(widget.workspace, widget.session),
  );

  bool _entryCurrent(CoreResourceListing listing, CoreResourceEntry entry) =>
      _current &&
      identical(widget.library.value.resourceState.listing, listing) &&
      listing.entries.any((item) => identical(item, entry));

  Future<String?> _name(String title, String initial) => showDialog<String>(
    context: context,
    builder: (context) => _ResourceNameDialog(title: title, initial: initial),
  );

  Future<void> _add({required bool image}) async {
    final editor = widget.session.value.editor;
    final name = await _name(
      image ? 'Add image asset' : 'Add attachment',
      image ? 'image.png' : 'attachment.bin',
    );
    if (name == null ||
        !_current ||
        !identical(editor, widget.session.value.editor)) {
      return;
    }
    await _run(
      () => widget.library.changeResource(
        widget.workspace,
        widget.session,
        image ? ResourceOperation.image : ResourceOperation.add,
        name,
      ),
    );
    if (_current) {
      setState(
        () => _message = 'File and editor source are separate. If the file committed, use Insert link or Insert image below. Write is still required to save source.',
      );
    }
  }

  Future<void> _entryAction(
    CoreResourceListing listing,
    CoreResourceEntry entry,
    String action,
  ) async {
    if (!_entryCurrent(listing, entry)) return;
    if (action == 'link' || action == 'image') {
      await _insert(entry, image: action == 'image');
      return;
    }
    String? newName;
    if (action == 'rename') {
      newName = await _name('Rename attachment', entry.name);
      if (newName == null || !_entryCurrent(listing, entry)) return;
    }
    if (action == 'remove') {
      final confirmed = await _confirm(
        'Remove “${entry.name}”?',
        'Existing links may break. The core tries to recycle the file, but may permanently delete it if recycling fails. '
            'No note source is rewritten and this app does not provide restore.',
        'Remove',
      );
      if (!confirmed || !_entryCurrent(listing, entry)) return;
    }
    final operation = switch (action) {
      'track' => ResourceOperation.track,
      'untrack' => ResourceOperation.untrack,
      'rename' => ResourceOperation.rename,
      'remove' => ResourceOperation.remove,
      'export' => ResourceOperation.export,
      _ => throw StateError('Unknown resource action.'),
    };
    await _run(
      () => widget.library.changeResource(
        widget.workspace,
        widget.session,
        operation,
        entry.name,
        newName: newName,
      ),
    );
  }

  Future<void> _insert(CoreResourceEntry entry, {required bool image}) async {
    if (!_current || _inserting || !entry.exists || (image && !_markdown)) {
      return;
    }
    setState(() {
      _inserting = true;
      _message = null;
    });
    try {
      final source = resourceMarkdownLink(
        name: entry.name,
        relativeUrl: entry.relativeUrl,
        image: image,
      );
      await widget.editor.insertText(widget.send, source);
      if (_current) {
        setState(
          () => _message = 'Link inserted into volatile editor source. Use Write to save it to disk.',
        );
      }
    } on Object catch (error) {
      if (_current) {
        setState(
          () => _message =
              'The file is retained; no additional copy was made. '
              'Link insertion failed: ${NotebookWorkspace.describeError(error)} '
              'Choose the intended cursor and explicitly use Insert link again.',
        );
      }
    } finally {
      if (mounted) setState(() => _inserting = false);
    }
  }

  Future<bool> _confirm(String title, String detail, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(detail),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ==
      true;

  Future<void> _resolve(
    ResourceAttempt attempt, {
    bool discard = false,
    bool abandon = false,
  }) async {
    if (discard) {
      final confirmed = await _confirm(
        abandon
            ? 'Abandon private recovery records?'
            : 'Discard private staging?',
        abandon
            ? 'The live outcome is ambiguous. Inspect the resource listing first. This abandons only the private source and recovery records; every live file, including an unexpected suffix copy, is preserved. No file is recopied and no link is inserted. Existing links may need manual repair.'
            : 'Only private transfer staging is discarded. A committed attachment or image is not removed and note source is not changed.',
        abandon ? 'Abandon private staging' : 'Discard staging',
      );
      if (!confirmed) return;
    }
    if (!_current ||
        !widget.library.value.resourceState.attempts.any(
          (item) => identical(item, attempt),
        )) {
      return;
    }
    await _run(
      () => widget.library.resolveSessionResource(
        widget.workspace,
        widget.session,
        attempt,
        discard: discard,
        abandon: abandon,
      ),
    );
  }

  @override
  Widget build(
    BuildContext context,
  ) => ValueListenableBuilder<NotebookLibraryState>(
    valueListenable: widget.library,
    builder: (context, library, _) {
      final state = library.resourceState;
      final note = widget.session.value.note;
      final listing = state.listing;
      final matches =
          listing != null &&
          listing.notebookId == note?.notebookId &&
          listing.nodeId == note?.nodeId;
      final attempts = state.attempts
          .where(
            (attempt) =>
                attempt.target.notebookId == note?.notebookId &&
                attempt.target.nodeId == note?.nodeId,
          )
          .toList();
      final busy =
          state.busy || widget.session.value.resourcesBusy || _inserting;
      final canStart = _current && !busy && !library.transferReserved;
      return PopScope<Object?>(
        canPop: !busy,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              title: const Text('Attachments and images'),
              subtitle: const Text(
                'File changes are durable separately. Inserted source stays unsaved until Write.',
              ),
              trailing: IconButton(
                tooltip: 'Close resources',
                onPressed: busy ? null : () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ),
            if (busy) const LinearProgressIndicator(),
            Expanded(
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Wrap(
                            spacing: 8,
                            children: [
                              TextButton.icon(
                                onPressed: canStart
                                    ? () => _add(image: false)
                                    : null,
                                icon: const Icon(Icons.attach_file),
                                label: const Text('Add attachment'),
                              ),
                              if (_markdown)
                                TextButton.icon(
                                  onPressed: canStart
                                      ? () => _add(image: true)
                                      : null,
                                  icon: const Icon(
                                    Icons.add_photo_alternate_outlined,
                                  ),
                                  label: const Text('Add image'),
                                ),
                              TextButton(
                                onPressed: !busy ? _refresh : null,
                                child: const Text('Inspect / refresh'),
                              ),
                              if (state.busy)
                                TextButton(
                                  onPressed: widget.library.cancelResource,
                                  child: const Text('Cancel transfer'),
                                ),
                            ],
                          ),
                        ),
                        if (state.error != null ||
                            state.message != null ||
                            _message != null ||
                            library.error != null)
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: SelectableText(
                              [
                                if (state.error != null) state.error!,
                                if (state.message != null) state.message!,
                                if (library.error != null) library.error!,
                                ?_message,
                              ].join('\n'),
                            ),
                          ),
                        for (final attempt in attempts)
                          Card(
                            margin: const EdgeInsets.all(12),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${attempt.operation.name}: ${attempt.name} · ${attempt.stage.name}',
                                  ),
                                  const Text(
                                    'Finish or discard this private transaction before starting another file change.',
                                  ),
                                  Wrap(
                                    spacing: 8,
                                    children: [
                                      if (attempt.stage !=
                                          TransferStage.committed)
                                        TextButton(
                                          onPressed: busy
                                              ? null
                                              : () => _resolve(attempt),
                                          child: Text(
                                            attempt.stage ==
                                                    TransferStage.exportReady
                                                ? 'Save As again'
                                                : 'Retry / recover',
                                          ),
                                        ),
                                      TextButton(
                                        onPressed: busy
                                            ? null
                                            : () => _resolve(
                                                attempt,
                                                discard: true,
                                              ),
                                        child: const Text('Discard staging'),
                                      ),
                                      if (attempt.stage ==
                                              TransferStage.intent ||
                                          attempt.stage ==
                                              TransferStage.quarantined)
                                        TextButton(
                                          onPressed: busy
                                              ? null
                                              : () => _resolve(
                                                  attempt,
                                                  discard: true,
                                                  abandon: true,
                                                ),
                                          child: const Text(
                                            'Abandon private staging',
                                          ),
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        if (state.externalMayBeIncomplete)
                          const Padding(
                            padding: EdgeInsets.all(16),
                            child: Text(
                              'A provider destination may be incomplete, or a previous Save As may already exist. Verify the destination before saving again.',
                            ),
                          ),
                        if (!matches)
                          const Padding(
                            padding: EdgeInsets.all(24),
                            child: Text(
                              'No current resource listing. Use Inspect / refresh.',
                            ),
                          )
                        else if (listing.entries.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(24),
                            child: Text(
                              'No tracked attachments or unindexed assets.',
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (matches)
                    SliverList.builder(
                      itemCount: listing.entries.length,
                      itemBuilder: (context, index) {
                        final entry = listing.entries[index];
                        return ListTile(
                          key: ValueKey(entry.name),
                          leading: Icon(
                            !entry.exists
                                ? Icons.broken_image_outlined
                                : entry.tracked
                                ? Icons.attach_file
                                : Icons.image_outlined,
                          ),
                          title: Text(entry.name),
                          subtitle: Text(
                            '${entry.tracked ? 'Tracked attachment' : 'Unindexed asset'}${entry.exists ? ' · ${entry.bytes} bytes' : ' · Missing file'}',
                          ),
                          trailing: PopupMenuButton<String>(
                            enabled: !busy && _current,
                            tooltip: 'Resource actions for ${entry.name}',
                            onSelected: (action) =>
                                _entryAction(listing, entry, action),
                            itemBuilder: (_) => [
                              if (entry.exists &&
                                  attempts.every(
                                    (attempt) =>
                                        attempt.stage != TransferStage.intent &&
                                        attempt.stage !=
                                            TransferStage.quarantined,
                                  )) ...[
                                const PopupMenuItem(
                                  value: 'link',
                                  child: Text('Insert link'),
                                ),
                                if (_markdown)
                                  const PopupMenuItem(
                                    value: 'image',
                                    child: Text('Insert image'),
                                  ),
                              ],
                              if (canStart) ...[
                                if (entry.exists)
                                  const PopupMenuItem(
                                    value: 'export',
                                    child: Text('Save As'),
                                  ),
                                if (!entry.tracked && entry.exists)
                                  const PopupMenuItem(
                                    value: 'track',
                                    child: Text('Track attachment'),
                                  ),
                                if (entry.tracked)
                                  const PopupMenuItem(
                                    value: 'untrack',
                                    child: Text('Untrack (keep file)'),
                                  ),
                                if (entry.tracked && entry.exists)
                                  const PopupMenuItem(
                                    value: 'rename',
                                    child: Text('Rename attachment'),
                                  ),
                                if (entry.exists)
                                  const PopupMenuItem(
                                    value: 'remove',
                                    child: Text('Remove file'),
                                  ),
                              ],
                            ],
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _ResourceNameDialog extends StatefulWidget {
  const _ResourceNameDialog({required this.title, required this.initial});
  final String title;
  final String initial;
  @override
  State<_ResourceNameDialog> createState() => _ResourceNameDialogState();
}

class _ResourceNameDialogState extends State<_ResourceNameDialog> {
  late final _name = TextEditingController(text: widget.initial);
  final _form = GlobalKey<FormState>();
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    if (_form.currentState!.validate()) Navigator.pop(context, _name.text);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: Form(
      key: _form,
      child: TextFormField(
        controller: _name,
        autofocus: true,
        autocorrect: false,
        decoration: const InputDecoration(
          labelText: 'Exact destination filename',
          helperText: 'Keep an appropriate extension. Bytes are copied unchanged; existing files are never overwritten.',
          helperMaxLines: 3,
        ),
        validator: (value) =>
            value == null ||
                value.isEmpty ||
                value == '.' ||
                value == '..' ||
                utf8.encode(value).length > 255 ||
                RegExp(r'[\\/:*?"<>|\x00-\x1f\x7f]').hasMatch(value) ||
                value.endsWith('.') ||
                value.endsWith(' ')
            ? 'Enter a portable filename (at most 255 UTF-8 bytes).'
            : null,
        onFieldSubmitted: (_) => _submit(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Continue')),
    ],
  );
}
