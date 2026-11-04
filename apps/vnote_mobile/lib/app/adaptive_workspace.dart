// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:math' as math;

import 'package:flutter/material.dart';

const double workspaceWideBreakpoint = 1000;

/// The context pane must be informational when a note is open. The live catalog
/// and note are mutually exclusive owners; this layout never creates either.
class AdaptiveWorkspace extends StatelessWidget {
  const AdaptiveWorkspace({
    required this.contextPane,
    required this.child,
    super.key,
  });

  final Widget contextPane;
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= workspaceWideBreakpoint;
      // Fixed ancestors and sibling slots: resizing cannot reparent a platform
      // view. Small windows scroll rather than compress controls below 320px.
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: math.max(constraints.maxWidth, 320.0),
          height: constraints.maxHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Offstage(
                offstage: !wide,
                child: ExcludeFocus(
                  excluding: !wide,
                  child: ExcludeSemantics(
                    excluding: !wide,
                    child: SizedBox(
                      width: 320,
                      child: Material(
                        child: SafeArea(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(16),
                            child: contextPane,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(child: child),
            ],
          ),
        ),
      );
    },
  );
}

/// Source and preview keep the same Stack slots in phone and tablet layouts.
/// Keep passing the same preview child while it exists, even when hidden.
class AdaptiveEditorPanes extends StatelessWidget {
  const AdaptiveEditorPanes({
    required this.source,
    required this.preview,
    required this.showPreview,
    super.key,
  });

  final Widget source;
  final Widget preview;
  final bool showPreview;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = math.max(constraints.maxWidth, 320.0);
      final split = showPreview && constraints.maxWidth >= workspaceWideBreakpoint;
      final sourceHidden = showPreview && !split;
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: width,
          height: constraints.maxHeight,
          child: Stack(
            children: [
              Positioned(
                top: 0,
                bottom: 0,
                left: 0,
                width: split ? width / 2 : width,
                child: Offstage(
                  offstage: sourceHidden,
                  child: ExcludeFocus(
                    excluding: sourceHidden,
                    child: ExcludeSemantics(excluding: sourceHidden, child: source),
                  ),
                ),
              ),
              Positioned(
                top: 0,
                bottom: 0,
                left: split ? width / 2 : 0,
                width: split ? width / 2 : width,
                child: Offstage(
                  offstage: !showPreview,
                  child: ExcludeFocus(
                    excluding: !showPreview,
                    child: ExcludeSemantics(excluding: !showPreview, child: preview),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
