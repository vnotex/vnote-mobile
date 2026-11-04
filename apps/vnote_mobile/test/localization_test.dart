// SPDX-License-Identifier: LGPL-3.0-only
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vnote_mobile/l10n/app_strings.dart';
import 'package:vnote_mobile/l10n/locale_settings.dart';

const _channel = MethodChannel('vnote.mobile/share_inbox');

class _LocalizedHarness extends StatelessWidget {
  const _LocalizedHarness({required this.settings, required this.source});
  final LocaleSettings settings;
  final TextEditingController source;

  @override
  Widget build(BuildContext context) => LocaleSettingsScope(
    settings: settings,
    child: AnimatedBuilder(animation: settings, builder: (context, _) => MaterialApp(
      locale: settings.locale,
      supportedLocales: AppStrings.supportedLocales,
      localizationsDelegates: const [AppStrings.delegate,
        GlobalMaterialLocalizations.delegate, GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate],
      localeResolutionCallback: (locale, _) => locale?.languageCode == 'zh'
        ? const Locale('zh', 'CN') : const Locale('en'),
      home: Builder(builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)),
        child: Scaffold(
          appBar: AppBar(actions: const [LanguageMenu()]),
          body: SingleChildScrollView(child: Column(children: [
            TextField(key: const ValueKey('source'), controller: source),
            FilledButton(key: const ValueKey('open-dialog'),
              onPressed: () => showDialog<void>(context: context,
                builder: (context) => AlertDialog(scrollable: true,
                  title: Text(AppStrings.of(context).text('New notebook')),
                  actions: [TextButton(key: const ValueKey('cancel-dialog'),
                    onPressed: () => Navigator.pop(context),
                    child: Text(AppStrings.of(context).text('Cancel')))])),
              child: Text(AppStrings.of(context).text('New notebook'))),
          ])),
        ),
      )),
    )),
  );
}

Future<void> _pumpLocalizedHarness(WidgetTester tester, {
  required LocaleSettings settings,
  required TextEditingController source,
}) async {
  await tester.runAsync(() async {
    // Start the real delegate in the IO zone: these ARBs exceed loadString's
    // isolate threshold, which pumpAndSettle's fake clock cannot complete.
    await tester.pumpWidget(_LocalizedHarness(settings: settings, source: source));
    for (final locale in AppStrings.supportedLocales) {
      await AppStrings.delegate.load(locale);
    }
  });
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  String persisted = 'system';
  final calls = <MethodCall>[];

  setUp(() {
    persisted = 'system';
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        if (call.method == 'getLocale') return persisted;
        if (call.method == 'setLocale') {
          persisted = (call.arguments as Map)['locale'] as String;
          return null;
        }
        throw MissingPluginException();
      });
  });
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
    .setMockMethodCallHandler(_channel, null));

  testWidgets('language control persists, survives restart, and retains exact editor state', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 720);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final settings = LocaleSettings();
    final source = TextEditingController(text: 'Cancel\r\n{name} 中文 😀');
    addTearDown(settings.dispose);
    addTearDown(source.dispose);
    await settings.initialize();
    await _pumpLocalizedHarness(tester, settings: settings, source: source);
    final sourceElement = tester.element(find.byKey(const ValueKey('source')));
    source.selection = const TextSelection(baseOffset: 6, extentOffset: 2);
    final exact = source.value;
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump();
    await tester.tap(find.byTooltip('Language'));
    await tester.pumpAndSettle();
    final chineseOption = find.byWidgetPredicate(
      (widget) => widget is PopupMenuItem<String> && widget.value == 'zh');
    await tester.ensureVisible(chineseOption);
    // Checked menu labels ignore pointers; the enclosing menu action receives
    // the tap, not its decorative Text child.
    expect(chineseOption.hitTestable(), findsOneWidget);
    await tester.tap(chineseOption);
    await tester.pumpAndSettle();
    expect(persisted, 'zh');
    expect(tester.element(find.byKey(const ValueKey('source'))), same(sourceElement));
    expect(source.value, exact);
    final context = tester.element(find.byKey(const ValueKey('open-dialog')));
    expect(Localizations.localeOf(context).languageCode, 'zh');
    expect(MaterialLocalizations.of(context).cancelButtonLabel, isNot('Cancel'));
    expect(tester.getSize(find.byType(PopupMenuButton<String>)).height,
      greaterThanOrEqualTo(48));
    await tester.tap(find.byKey(const ValueKey('open-dialog')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('cancel-dialog')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(source.value, exact);
    expect(tester.takeException(), isNull);

    final restarted = LocaleSettings();
    addTearDown(restarted.dispose);
    await restarted.initialize();
    expect(restarted.choice, 'zh');
    expect(restarted.locale, const Locale('zh', 'CN'));
  });

  testWidgets('system follows supported OS locales and unsupported OS falls back to English', (tester) async {
    final settings = LocaleSettings();
    final source = TextEditingController(text: 'English source stays exact');
    addTearDown(settings.dispose);
    addTearDown(source.dispose);
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    await settings.initialize();
    tester.binding.platformDispatcher.localesTestValue = const [Locale('zh', 'TW')];
    await _pumpLocalizedHarness(tester, settings: settings, source: source);
    BuildContext context() => tester.element(find.byKey(const ValueKey('open-dialog')));
    expect(Localizations.localeOf(context()).languageCode, 'zh');
    tester.binding.platformDispatcher.localesTestValue = const [Locale('de')];
    await tester.pumpAndSettle();
    expect(Localizations.localeOf(context()).languageCode, 'en');
    await settings.setChoice('zh');
    await tester.pumpAndSettle();
    expect(Localizations.localeOf(context()).languageCode, 'zh');
    await settings.setChoice('system');
    await tester.pumpAndSettle();
    expect(settings.locale, isNull);
    expect(persisted, 'system');
    expect(Localizations.localeOf(context()).languageCode, 'en');
    expect(source.text, 'English source stays exact');
  });

  test('failed native persistence does not diverge UI from receiver preferences', () async {
    persisted = 'en';
    final settings = LocaleSettings();
    addTearDown(settings.dispose);
    await settings.initialize();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
        if (call.method == 'setLocale') throw PlatformException(code: 'settings_locked');
        return persisted;
      });
    await settings.setChoice('zh');
    expect(settings.choice, 'en');
    expect(persisted, 'en');
    expect(settings.error, contains('settings_locked'));
    expect(settings.busy, isFalse);
  });

  test('localization preserves placeholders in user data and diagnostic evidence', () async {
    final strings = await AppStrings.delegate.load(const Locale('zh', 'CN'));
    expect(strings.text('Future feature: {name}', {'name': 'Exact {bytes} 😀'}),
      'Future feature: Exact {bytes} 😀');
    expect(strings.text('Export {name}', {'name': 'Cancel\r\n{name}'}),
      endsWith('Cancel\r\n{name}'));
    const unknown = 'unknown_native_code: exact detail 42 / safe-relative-name';
    expect(strings.message(unknown), unknown);
    final known = strings.message('Core error 42: The notebook identity changed during export.');
    expect(known, contains('42'));
    expect(known, isNot(contains('The notebook identity changed during export.')));
    final share = strings.message('Shared item error inbox_full. Retained bytes and uncertain outcomes remain protected.');
    expect(share, contains('inbox_full'));
    expect(share, isNot(contains('Retained bytes and uncertain outcomes remain protected.')));
  });
}
