// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import 'document_transfer_platform.dart';

class ManagedNotebookPaths {
  const ManagedNotebookPaths({
    required this.app,
    required this.local,
    required this.notebook,
  });
  final String app;
  final String local;
  final String notebook;
}

class ManagedNotebookCandidate {
  const ManagedNotebookCandidate({
    required this.paths,
    required this.label,
    this.error,
  });
  final ManagedNotebookPaths paths;
  final String label;
  final String? error;
}

/// Owns support namespaces, never notebook metadata or notebook content.
class ManagedNotebookStorage {
  const ManagedNotebookStorage({
    required this.app,
    required this.local,
    required this.root,
  });
  final String app;
  final String local;
  final String root;
  static const maxNotebooks = 1000;

  static Future<ManagedNotebookStorage> obtain() async {
    await MethodChannelDocumentTransferPlatform().prepareStorage();
    final support = await getApplicationSupportDirectory();
    final excluded = [
      await getTemporaryDirectory(),
      await getApplicationCacheDirectory(),
      Directory.systemTemp,
    ];
    final root = await _canonical(support);
    for (final directory in excluded) {
      if (_within(root, await _canonical(directory))) {
        throw StateError(
          'Application Support resolves to temporary/cache storage.',
        );
      }
    }
    await Directory(root).create(recursive: true);
    if (_key(await support.resolveSymbolicLinks()) != _key(root)) {
      throw StateError('Application Support changed during initialization.');
    }
    Future<String> child(String relative) async {
      final expected = Directory.fromUri(Directory(root).uri.resolve(relative));
      final canonical = await _canonical(expected);
      if (!_within(canonical, root) || _key(canonical) != _key(expected.path)) {
        throw StateError(
          'Managed storage escapes its persistent support root.',
        );
      }
      await expected.create(recursive: true);
      if (_key(await expected.resolveSymbolicLinks()) != _key(canonical)) {
        throw StateError('Managed storage changed during initialization.');
      }
      return canonical;
    }

    await child('core/');
    final app = await child('core/app/');
    final local = await child('core/local/');
    final notebooks = await child('notebooks/');
    return ManagedNotebookStorage(app: app, local: local, root: notebooks);
  }

  Future<String> obtainExportRoot() => _obtainTransferRoot('exports');
  Future<String> obtainImportRoot() => _obtainTransferRoot('imports');
  Future<String> obtainCohortRoot() => _obtainTransferRoot('cohorts');
  Future<String> obtainResourceRoot() => _obtainTransferRoot('resources');
  Future<String> obtainDraftRoot() => _obtainTransferRoot('drafts');
  Future<String> obtainPreviewRoot() => _obtainTransferRoot('previews');

  Future<String> _obtainTransferRoot(String name) async {
    await _validateParent();
    final support = Directory(root).parent;
    final expected = Directory.fromUri(support.uri.resolve('$name/'));
    final canonical = await _canonical(expected);
    if (!_within(canonical, support.path) ||
        _key(canonical) != _key(expected.path)) {
      throw StateError('Transfer storage escapes its persistent support root.');
    }
    await expected.create(recursive: true);
    if (_key(await expected.resolveSymbolicLinks()) != _key(canonical)) {
      throw StateError('Transfer storage changed during initialization.');
    }
    return p.normalize(canonical);
  }

  Future<void> _validateParent() async {
    try {
      if (_key(Directory(root).absolute.path) != _key(root) ||
          await FileSystemEntity.type(root, followLinks: false) !=
              FileSystemEntityType.directory ||
          _key(await Directory(root).resolveSymbolicLinks()) != _key(root)) {
        throw StateError('Managed notebooks parent is unavailable or linked.');
      }
    } on FileSystemException {
      throw StateError('Managed notebooks parent is inaccessible.');
    }
  }

  ManagedNotebookPaths _paths(String location) {
    final directory = Directory(location);
    if (_key(directory.parent.path) != _key(root) ||
        _key(directory.absolute.path) != _key(location) ||
        utf8.encode(location).length > 16384) {
      throw StateError('Notebook location is not a direct managed child.');
    }
    final label = directory.uri.pathSegments
        .where((part) => part.isNotEmpty)
        .last;
    if (label == '.' ||
        label == '..' ||
        label.contains('\\') ||
        label.contains(':') ||
        label.contains('\u0000')) {
      throw StateError('Notebook location is not a supported managed child.');
    }
    return ManagedNotebookPaths(app: app, local: local, notebook: location);
  }

  Future<List<ManagedNotebookCandidate>> candidates() async {
    await _validateParent();
    final result = <ManagedNotebookCandidate>[];
    try {
      await for (final entity in Directory(root).list(followLinks: false)) {
        if (entity is! Directory && entity is! Link) continue;
        if (result.length == maxNotebooks) {
          throw StateError(
            'Managed library exceeds the $maxNotebooks-notebook limit.',
          );
        }
        final label = entity.uri.pathSegments
            .where((part) => part.isNotEmpty)
            .last;
        final fallback = ManagedNotebookPaths(
          app: app,
          local: local,
          notebook: entity.path,
        );
        try {
          final paths = _paths(entity.path);
          final type = await FileSystemEntity.type(
            entity.path,
            followLinks: false,
          );
          result.add(
            ManagedNotebookCandidate(
              paths: paths,
              label: label,
              error: type == FileSystemEntityType.directory
                  ? null
                  : 'Notebook location is linked or unavailable.',
            ),
          );
        } on StateError catch (error) {
          result.add(
            ManagedNotebookCandidate(
              paths: fallback,
              label: label,
              error: error.message.toString(),
            ),
          );
        } on FileSystemException {
          result.add(
            ManagedNotebookCandidate(
              paths: fallback,
              label: label,
              error: 'Notebook location is inaccessible.',
            ),
          );
        }
      }
    } on FileSystemException {
      throw StateError('Managed notebooks could not be enumerated.');
    }
    return result;
  }

  Future<ManagedNotebookPaths> existing(String location) async {
    await _validateParent();
    final paths = _paths(location);
    if (await FileSystemEntity.type(location, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw StateError(
        'Notebook location is linked or missing. Refresh the library.',
      );
    }
    // Native no_link rejects Windows reparse aliases before metadata access too.
    return paths;
  }

  Future<ManagedNotebookPaths> allocate() async {
    await _validateParent();
    final random = Random.secure();
    final token = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final location = Directory.fromUri(
      Directory(root).uri.resolve('nb-$token/'),
    ).path;
    final paths = _paths(location);
    if (await FileSystemEntity.type(location, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw StateError(
        'The new notebook location already exists. Nothing was replaced.',
      );
    }
    return paths;
  }

  static String _key(String path) {
    final normalized = path
        .replaceAll('\\', '/')
        .replaceFirst(RegExp(r'/+$'), '');
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  static bool _within(String path, String parent) =>
      _key(path) == _key(parent) || _key(path).startsWith('${_key(parent)}/');

  static Future<String> _canonical(Directory directory) async {
    final suffix = <String>[];
    var current = directory.absolute;
    while (!await current.exists()) {
      if (await FileSystemEntity.type(current.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw StateError(
          'A managed storage ancestor is not an accessible directory.',
        );
      }
      final parent = current.parent;
      if (parent.path == current.path) {
        throw StateError('Persistent storage has no accessible ancestor.');
      }
      suffix.insert(
        0,
        current.uri.pathSegments.where((part) => part.isNotEmpty).last,
      );
      current = parent;
    }
    final canonical = Directory(await current.resolveSymbolicLinks());
    return p.normalize(Directory.fromUri(
      canonical.uri.resolve(
        suffix.isEmpty ? '' : '${suffix.map(Uri.encodeComponent).join('/')}/',
      ),
    ).path);
  }
}
