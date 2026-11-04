// SPDX-License-Identifier: LGPL-3.0-only
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_strings.dart';

/// Private native settings are shared with stopped-app receivers. This never
/// writes notebook metadata and does not depend on inbox/App Group availability.
class LocaleSettings extends ChangeNotifier {
  LocaleSettings({this._channel = const MethodChannel('vnote.mobile/share_inbox')});

  final MethodChannel _channel;
  String _choice = 'system';
  bool _busy = false;
  bool _disposed = false;
  String? _error;
  Future<void>? _initialization;

  String get choice => _choice;
  bool get busy => _busy;
  String? get error => _error;
  Locale? get locale => switch (_choice) {
    'en' => const Locale('en'),
    'zh' => const Locale('zh', 'CN'),
    _ => null,
  };

  Future<void> initialize() => _initialization ??= _load();

  Future<void> _load() async {
    _busy = true;
    try {
      final value = await _channel.invokeMethod<Object?>('getLocale');
      if (value != 'system' && value != 'en' && value != 'zh') {
        throw const FormatException('Invalid locale preference reply.');
      }
      _choice = value! as String;
      _error = null;
    } on Object catch (error) {
      _error = _describe(error);
    } finally {
      _busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Apply only after native persistence succeeds, so UI and receiver agree.
  Future<void> setChoice(String choice) async {
    if (choice != 'system' && choice != 'en' && choice != 'zh') {
      throw ArgumentError.value(choice, 'choice');
    }
    await initialize();
    if (_busy || _disposed || choice == _choice && _error == null) return;
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      final result = await _channel.invokeMethod<Object?>('setLocale', {'locale': choice});
      if (result != null) throw const FormatException('Invalid locale preference reply.');
      _choice = choice;
    } on Object catch (error) {
      _error = _describe(error);
    } finally {
      _busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  static String _describe(Object error) => switch (error) {
    PlatformException() => '${error.code}: ${error.message ?? ''}',
    MissingPluginException() => 'Native language settings are unavailable.',
    FormatException() => error.message,
    StateError() => error.message.toString(),
    _ => error.toString(),
  };

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class LocaleSettingsScope extends InheritedNotifier<LocaleSettings> {
  const LocaleSettingsScope({required LocaleSettings settings, required super.child, super.key})
      : super(notifier: settings);

  static LocaleSettings? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LocaleSettingsScope>()?.notifier;
}

/// Shared app-bar control; never changes the editor's identity or source.
class LanguageMenu extends StatelessWidget {
  const LanguageMenu({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = LocaleSettingsScope.maybeOf(context);
    if (settings == null) return const SizedBox.shrink();
    final strings = AppStrings.of(context);
    return PopupMenuButton<String>(
      tooltip: strings.text('Language'),
      enabled: !settings.busy,
      icon: const Icon(Icons.language),
      onSelected: (choice) async {
        await settings.setChoice(choice);
        if (!context.mounted || settings.error == null) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
          AppStrings.of(context).text('Language preference could not be saved: {detail}',
            {'detail': AppStrings.of(context).message(settings.error)}))));
      },
      itemBuilder: (context) => [
        for (final option in const {
          'system': 'System language', 'en': 'English', 'zh': 'Simplified Chinese',
        }.entries)
          CheckedPopupMenuItem<String>(
            value: option.key,
            checked: settings.choice == option.key,
            child: Text(strings.text(option.value)),
          ),
        if (settings.error != null)
          PopupMenuItem<String>(enabled: false, child: Text(strings.text(
            'Language preference could not be loaded: {detail}',
            {'detail': strings.message(settings.error)}))),
      ],
    );
  }
}
