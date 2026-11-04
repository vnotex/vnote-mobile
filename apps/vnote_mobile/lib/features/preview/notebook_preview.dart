// SPDX-License-Identifier: LGPL-3.0-only
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_strings.dart';
import '../../services/preview_session.dart';
import '../../services/web_surface_platform.dart';

class NotebookPreview extends StatelessWidget {
  const NotebookPreview({
    required this.session,
    required this.onSource,
    required this.onRefresh,
    super.key,
  });

  final PreviewSession session;
  final VoidCallback onSource;
  final VoidCallback onRefresh;

  Widget _view(BuildContext context) => switch (defaultTargetPlatform) {
    TargetPlatform.android => AndroidView(
      key: ValueKey(session.surfaceId),
      viewType: WebSurfacePlatform.previewViewType,
      creationParams: {'surfaceId': session.surfaceId},
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: (_) => session.attachView(),
    ),
    TargetPlatform.iOS => UiKitView(
      key: ValueKey(session.surfaceId),
      viewType: WebSurfacePlatform.previewViewType,
      creationParams: {'surfaceId': session.surfaceId},
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: (_) => session.attachView(),
    ),
    _ => Center(
      child: Text(AppStrings.of(context).text('A supported native preview surface is required. Source remains available.')),
    ),
  };

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<PreviewSessionState>(
    valueListenable: session,
    builder: (context, state, _) => LayoutBuilder(builder: (context, constraints) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConstrainedBox(constraints: BoxConstraints(maxHeight: constraints.maxHeight * 0.5),
          child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TextButton.icon(
              onPressed: onSource,
              icon: const Icon(Icons.edit_note),
              label: Text(AppStrings.of(context).text('Return to source')),
            ),
            TextButton.icon(
              onPressed: state.busy ? null : onRefresh,
              icon: const Icon(Icons.refresh),
              label: Text(AppStrings.of(context).text('Refresh preview')),
            ),
            if (state.snapshot != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(AppStrings.of(context).text('Read-only preview · source revision {sourceRevision}', {'sourceRevision': (state.snapshot!.sourceRevision).toString()})),
              ),
          ],
        ),
        if (state.busy) LinearProgressIndicator(semanticsLabel: AppStrings.of(context).text('Preparing safe preview')),
        if (state.error != null)
          ColoredBox(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Semantics(liveRegion: true, child: Text(AppStrings.of(context).message(state.error!))),
            ),
          ),
        ]))),
        Expanded(child: Semantics(label: AppStrings.of(context).text('Read-only Markdown preview'), child: _view(context))),
      ],
    )),
  );
}
