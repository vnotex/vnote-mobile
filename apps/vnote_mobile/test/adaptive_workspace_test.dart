// SPDX-License-Identifier: LGPL-3.0-only
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vnote_mobile/app/adaptive_workspace.dart';

class _Surface extends StatefulWidget {
  const _Surface({required this.onDispose, super.key});
  final VoidCallback onDispose;

  @override
  State<_Surface> createState() => _SurfaceState();
}

class _SurfaceState extends State<_Surface> {
  final controller = TextEditingController(text: 'Exact source 中文 😀');
  final focus = FocusNode();

  @override
  void dispose() {
    widget.onDispose();
    controller.dispose();
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    focusNode: focus,
    decoration: InputDecoration(labelText: Localizations.localeOf(context).languageCode),
  );
}

Widget _app(Widget child, {String locale = 'en', double scale = 1}) => MaterialApp(
  locale: Locale(locale),
  supportedLocales: const [Locale('en'), Locale('zh')],
  localizationsDelegates: const [
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  home: Builder(builder: (context) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: Scaffold(body: child),
  )),
);

void main() {
  testWidgets('workspace resizing and locale retain the same source element and state', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    var disposed = 0;
    Widget workspace() => AdaptiveWorkspace(
      contextPane: const Text('Read-only notebook context'),
      child: _Surface(key: const ValueKey('source'), onDispose: () => disposed++),
    );
    await tester.pumpWidget(_app(workspace()));
    final element = tester.element(find.byType(_Surface));
    final state = tester.state<_SurfaceState>(find.byType(_Surface));
    await tester.enterText(find.byType(TextField), 'Unwritten exact source\r\n中文 😀');
    state.controller.selection = const TextSelection(baseOffset: 9, extentOffset: 2);
    final value = state.controller.value;
    state.focus.requestFocus();
    await tester.pump();
    for (final width in [1000.0, 1400.0, 999.0, 600.0]) {
      tester.view.physicalSize = Size(width, 900);
      await tester.pumpWidget(_app(workspace(), locale: 'zh', scale: 2));
      expect(tester.element(find.byType(_Surface)), same(element));
      expect(tester.state<_SurfaceState>(find.byType(_Surface)), same(state));
      expect(state.controller.value, value);
      expect(state.focus.hasFocus, isTrue);
      expect(find.text('Read-only notebook context'), width >= 1000 ? findsOneWidget : findsNothing);
      expect(disposed, 0);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('source and preview stay in fixed slots through split and overlay layouts', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    var disposed = 0;
    Widget panes(bool showPreview) => AdaptiveEditorPanes(
      source: _Surface(key: const ValueKey('source'), onDispose: () => disposed++),
      preview: _Surface(key: const ValueKey('preview'), onDispose: () => disposed++),
      showPreview: showPreview,
    );
    Finder surface(String name) => find.byKey(ValueKey(name), skipOffstage: false);
    await tester.pumpWidget(_app(panes(true)));
    final sourceElement = tester.element(surface('source'));
    final previewElement = tester.element(surface('preview'));
    final source = tester.state<_SurfaceState>(surface('source'));
    final preview = tester.state<_SurfaceState>(surface('preview'));
    source.controller.value = const TextEditingValue(text: 'pending source', selection: TextSelection(baseOffset: 8, extentOffset: 2));
    preview.controller.text = 'retained preview state';
    expect(tester.getSize(surface('source')).width, 600);
    expect(tester.getSize(surface('preview')).width, 600);
    for (final width in [999.0, 1000.0, 700.0, 1400.0]) {
      tester.view.physicalSize = Size(width, 900);
      for (final showing in [true, false, true]) {
        await tester.pumpWidget(_app(panes(showing), locale: 'zh'));
        expect(tester.element(surface('source')), same(sourceElement));
        expect(tester.element(surface('preview')), same(previewElement));
        expect(source.controller.text, 'pending source');
        expect(source.controller.selection, const TextSelection(baseOffset: 8, extentOffset: 2));
        expect(preview.controller.text, 'retained preview state');
        expect(find.byKey(const ValueKey('source')), showing && width < 1000 ? findsNothing : findsOneWidget);
        expect(find.byKey(const ValueKey('preview')), showing ? findsOneWidget : findsNothing);
        expect(disposed, 0);
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets('large-text context controls scroll into reach without moving the editor', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 400);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    var tapped = false;
    await tester.pumpWidget(_app(AdaptiveWorkspace(
      contextPane: Column(children: [
        Text('Read-only context ' * 60),
        TextButton(
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: () => tapped = true,
          child: const Text('Return through disposition'),
        ),
      ]),
      child: _Surface(onDispose: () {}),
    ), scale: 2));
    final element = tester.element(find.byType(_Surface));
    final action = find.text('Return through disposition');
    await tester.ensureVisible(action);
    await tester.tap(action);
    expect(tapped, isTrue);
    expect(tester.getSize(find.byType(TextButton)).height, greaterThanOrEqualTo(48));
    expect(tester.element(find.byType(_Surface)), same(element));
    expect(tester.takeException(), isNull);
  });
}
