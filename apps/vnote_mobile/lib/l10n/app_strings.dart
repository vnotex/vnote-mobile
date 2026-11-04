// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Presentation-only catalog. Notebook source, names, URLs and legal bodies must
/// be passed as arguments, never looked up as translation keys.
class AppStrings {
  AppStrings._(this.locale, this._translations, this._messages, this._errorCodes);

  final Locale locale;
  final Map<String, String> _translations;
  final List<_MessageTemplate> _messages;
  final Map<String, String> _errorCodes;
  static final _fallback = AppStrings._(const Locale('en'), const {}, const [], const {});
  static const supportedLocales = [Locale('en'), Locale('zh', 'CN')];
  static const delegate = _AppStringsDelegate();

  static AppStrings of(BuildContext context) =>
      Localizations.of<AppStrings>(context, AppStrings) ?? _fallback;

  /// Unknown templates remain meaningful English. Substitution is a single pass:
  /// braces in a filename or note excerpt can never become another placeholder.
  String text(String englishTemplate,
      [Map<String, Object> arguments = const {}]) {
    final template = _translations[englishTemplate] ?? englishTemplate;
    return template.replaceAllMapped(_placeholder, (match) =>
        arguments[match[1]]?.toString() ?? match[0]!);
  }

  /// Only call for service diagnostics/status, not arbitrary notebook content.
  /// Known message templates are localized while unknown details and machine
  /// codes are retained verbatim; no blanket replacement hides a safety warning.
  String message(String? diagnostic) => _message(diagnostic ?? '', 0);

  String _message(String diagnostic, int depth) {
    if (diagnostic.isEmpty || depth > 4) return diagnostic;
    final code = _codePrefix.firstMatch(diagnostic);
    final description = code == null ? null : _errorCodes[code[1]];
    if (description != null) {
      return '${text(description)} [${code![1]}]${diagnostic.substring(code.end)}';
    }
    final exact = _translations[diagnostic];
    if (exact != null) return exact;
    for (final template in _messages) {
      final match = template.pattern.firstMatch(diagnostic);
      if (match == null) continue;
      return text(template.english, {
        for (var index = 0; index < template.names.length; index++)
          template.names[index]: _message(match[index + 1]!, depth + 1),
      });
    }
    if (diagnostic.contains('\n')) {
      return diagnostic.split('\n').map((line) => _message(line, depth + 1)).join('\n');
    }
    return diagnostic;
  }

  static final _placeholder = RegExp(r'\{([A-Za-z_]\w*)\}');
  static final _codePrefix = RegExp(r'^([a-z][a-z0-9_]+)(?=$|\s|:)');
}

class _MessageTemplate {
  _MessageTemplate(this.english) {
    final expression = StringBuffer('^');
    var offset = 0;
    for (final match in AppStrings._placeholder.allMatches(english)) {
      expression.write(RegExp.escape(english.substring(offset, match.start)));
      expression.write('([\\s\\S]*?)');
      names.add(match[1]!);
      offset = match.end;
    }
    expression.write(RegExp.escape(english.substring(offset)));
    expression.write(r'$');
    pattern = RegExp(expression.toString());
  }
  final String english;
  final List<String> names = [];
  late final RegExp pattern;
}

class _AppStringsDelegate extends LocalizationsDelegate<AppStrings> {
  const _AppStringsDelegate();

  // Immutable catalogs are cached, never a process-global selected locale.
  static final Map<String, Future<AppStrings>> _loaded = {};

  @override
  bool isSupported(Locale locale) => locale.languageCode == 'en' || locale.languageCode == 'zh';

  @override
  Future<AppStrings> load(Locale locale) => _loaded.putIfAbsent(
    locale.languageCode, () => _load(locale));

  Future<AppStrings> _load(Locale locale) async {
    final english = jsonDecode(await rootBundle.loadString('lib/l10n/app_en.arb')) as Map<String, dynamic>;
    final translated = locale.languageCode == 'zh'
        ? jsonDecode(await rootBundle.loadString('lib/l10n/app_zh.arb')) as Map<String, dynamic>
        : english;
    final translations = <String, String>{};
    final messages = <_MessageTemplate>[];
    final errorCodes = <String, String>{};
    for (final entry in english.entries) {
      if (entry.key.startsWith('@') || entry.value is! String) continue;
      final source = entry.value as String;
      translations[source] = translated[entry.key] as String? ?? source;
      final metadata = english['@${entry.key}'];
      if (metadata is Map && metadata['description'] == 'Service message template') {
        messages.add(_MessageTemplate(source));
      }
      if (metadata is Map && metadata['errorCode'] is String) {
        errorCodes[metadata['errorCode'] as String] = source;
      }
    }
    final strings = AppStrings._(locale, Map.unmodifiable(translations),
      List.unmodifiable(messages), Map.unmodifiable(errorCodes));
    // Warm loads are synchronous, just like Flutter's built-in delegates. Do
    // not retain a completed Future's async zone as part of the catalog cache.
    _loaded[locale.languageCode] = SynchronousFuture(strings);
    return strings;
  }

  @override
  bool shouldReload(covariant LocalizationsDelegate<AppStrings> old) => false;
}
