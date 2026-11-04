// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:vxcore_bridge/vxcore_bridge.dart';

import '../../l10n/app_strings.dart';
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
      image ? AppStrings.of(context).text('Add image asset') : AppStrings.of(context).text('Add attachment'),
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
        () => _message = 'File and editor source are separate. Insert a link or image below; source then follows draft persistence and autosave.',
      );
    }
  }

  Future<void> _entryAction(
    CoreResourceListing listing,
    CoreResourceEntry entry,
    String action,
  ) async {
    if (!_entryCurrent(listing, entry)) return;
    final strings = AppStrings.of(context);
    if (action == 'link' || action == 'image') {
      await _insert(entry, image: action == 'image');
      return;
    }
    String? newName;
    if (action == 'rename') {
      newName = await _name(AppStrings.of(context).text('Rename attachment'), entry.name);
      if (newName == null || !_entryCurrent(listing, entry)) return;
    }
    if (action == 'remove') {
      final confirmed = await _confirm(
        strings.text('Remove “{name}”?', {'name': entry.name}),
        strings.text('Existing links may break. The core tries to recycle the file, but may permanently delete it if recycling fails. No note source is rewritten and this app does not provide restore.'),
        strings.text('Remove'),
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
          () => _message = 'Link inserted. Check the editor\'s draft and saved status.',
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

  Future<void> _resolve(
    ResourceAttempt attempt, {
    bool discard = false,
    bool abandon = false,
  }) async {
    if (discard) {
      final confirmed = await _confirm(
        abandon
            ? AppStrings.of(context).text('Abandon private recovery records?')
            : AppStrings.of(context).text('Discard private staging?'),
        abandon
            ? AppStrings.of(context).text('The live outcome is ambiguous. Inspect the resource listing first. This abandons only the private source and recovery records; every live file, including an unexpected suffix copy, is preserved. No file is recopied and no link is inserted. Existing links may need manual repair.')
            : AppStrings.of(context).text('Only private transfer staging is discarded. A committed attachment or image is not removed and note source is not changed.'),
        abandon ? AppStrings.of(context).text('Abandon private staging') : AppStrings.of(context).text('Discard staging'),
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
        child: CustomScrollView(
          slivers: [
                  SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
            ListTile(
              title: Text(AppStrings.of(context).text('Attachments and images')),
              subtitle: Text(
                AppStrings.of(context).text('File changes commit separately. Inserted source uses draft recovery and autosave.'),
              ),
              trailing: IconButton(
                tooltip: AppStrings.of(context).text('Close resources'),
                onPressed: busy ? null : () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ),
            if (busy) const LinearProgressIndicator(),
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
                                label: Text(AppStrings.of(context).text('Add attachment')),
                              ),
                              if (_markdown)
                                TextButton.icon(
                                  onPressed: canStart
                                      ? () => _add(image: true)
                                      : null,
                                  icon: const Icon(
                                    Icons.add_photo_alternate_outlined,
                                  ),
                                  label: Text(AppStrings.of(context).text('Add image')),
                                ),
                              TextButton(
                                onPressed: !busy ? _refresh : null,
                                child: Text(AppStrings.of(context).text('Inspect / refresh')),
                              ),
                              if (state.busy)
                                TextButton(
                                  onPressed: widget.library.cancelResource,
                                  child: Text(AppStrings.of(context).text('Cancel transfer')),
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
                              ].map(AppStrings.of(context).message).join('\n'),
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
                                    '${AppStrings.of(context).text(attempt.operation.name)}: ${attempt.name} · ${AppStrings.of(context).text(attempt.stage.name)}',
                                  ),
                                  Text(
                                    AppStrings.of(context).text('Finish or discard this private transaction before starting another file change.'),
                                  ),
                                  Wrap(
                                    spacing: 8,
                                    children: [
                                      if (attempt.stage == TransferStage.exportReady)
                                        TextButton.icon(
                                          onPressed: busy ? null : () => widget.library.shareResource(attempt),
                                          icon: const Icon(Icons.share_outlined),
                                          label: Text(AppStrings.of(context).text('Share retained copy')),
                                        ),
                                      if (attempt.stage == TransferStage.exportUnavailable)
                                        Text(AppStrings.of(context).text('The export source is unavailable; discard only private staging.')),
                                      if (attempt.stage != TransferStage.committed &&
                                          attempt.stage != TransferStage.exportUnavailable)
                                        TextButton(
                                          onPressed: busy
                                              ? null
                                              : () => _resolve(attempt),
                                          child: Text(
                                            attempt.stage ==
                                                    TransferStage.exportReady
                                                ? AppStrings.of(context).text('Save As again')
                                                : AppStrings.of(context).text('Retry / recover'),
                                          ),
                                        ),
                                      TextButton(
                                        onPressed: busy
                                            ? null
                                            : () => _resolve(
                                                attempt,
                                                discard: true,
                                              ),
                                        child: Text(AppStrings.of(context).text('Discard staging')),
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
                                          child: Text(
                                            AppStrings.of(context).text('Abandon private staging'),
                                          ),
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        if (state.externalMayBeIncomplete)
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(
                              AppStrings.of(context).text('A provider destination may be incomplete, or a previous Save As may already exist. Verify the destination before saving again.'),
                            ),
                          ),
                        if (!matches)
                          Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              AppStrings.of(context).text('No current resource listing. Use Inspect / refresh.'),
                            ),
                          )
                        else if (listing.entries.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              AppStrings.of(context).text('No tracked attachments or unindexed assets.'),
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
                            '${entry.tracked ? AppStrings.of(context).text('Tracked attachment') : AppStrings.of(context).text('Unindexed asset')}${entry.exists ? AppStrings.of(context).text(' · {bytes} bytes', {'bytes': (entry.bytes).toString()}) : AppStrings.of(context).text(' · Missing file')}',
                          ),
                          trailing: PopupMenuButton<String>(
                            enabled: !busy && _current,
                            tooltip: AppStrings.of(context).text('Resource actions for {name}', {'name': (entry.name).toString()}),
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
                                PopupMenuItem(
                                  value: 'link',
                                  child: Text(AppStrings.of(context).text('Insert link')),
                                ),
                                if (_markdown)
                                  PopupMenuItem(
                                    value: 'image',
                                    child: Text(AppStrings.of(context).text('Insert image')),
                                  ),
                              ],
                              if (canStart) ...[
                                if (entry.exists)
                                  PopupMenuItem(
                                    value: 'export',
                                    child: Text(AppStrings.of(context).text('Save As')),
                                  ),
                                if (!entry.tracked && entry.exists)
                                  PopupMenuItem(
                                    value: 'track',
                                    child: Text(AppStrings.of(context).text('Track attachment')),
                                  ),
                                if (entry.tracked)
                                  PopupMenuItem(
                                    value: 'untrack',
                                    child: Text(AppStrings.of(context).text('Untrack (keep file)')),
                                  ),
                                if (entry.tracked && entry.exists)
                                  PopupMenuItem(
                                    value: 'rename',
                                    child: Text(AppStrings.of(context).text('Rename attachment')),
                                  ),
                                if (entry.exists)
                                  PopupMenuItem(
                                    value: 'remove',
                                    child: Text(AppStrings.of(context).text('Remove file')),
                                  ),
                              ],
                            ],
                          ),
                        );
                      },
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
  Widget build(BuildContext context) => AlertDialog(scrollable: true, 
    title: Text(widget.title),
    content: Form(
      key: _form,
      child: TextFormField(
        controller: _name,
        autofocus: true,
        autocorrect: false,
        decoration: InputDecoration(
          labelText: AppStrings.of(context).text('Exact destination filename'),
          helperText: AppStrings.of(context).text('Keep an appropriate extension. Bytes are copied unchanged; existing files are never overwritten.'),
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
            ? AppStrings.of(context).text('Enter a portable filename (at most 255 UTF-8 bytes).')
            : null,
        onFieldSubmitted: (_) => _submit(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(AppStrings.of(context).text('Cancel')),
      ),
      FilledButton(onPressed: _submit, child: Text(AppStrings.of(context).text('Continue'))),
    ],
  );
}
