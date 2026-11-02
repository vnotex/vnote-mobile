// SPDX-License-Identifier: LGPL-3.0-only

final class CoreCohortBuildResult {
  const CoreCohortBuildResult({
    required this.privateNotebookId,
    required this.cohortId,
  });

  final String privateNotebookId;
  final String cohortId;
}

enum CoreCohortStatus { committed, absent }

final class CoreCohortOutcome {
  const CoreCohortOutcome({
    required this.status,
    required this.cohortId,
    this.path,
  });

  final CoreCohortStatus status;
  final String cohortId;
  final String? path;
  bool get committed => status == CoreCohortStatus.committed;
}

final class CoreResourceEntry {
  const CoreResourceEntry({
    required this.name,
    required this.tracked,
    required this.exists,
    required this.bytes,
    required this.relativeUrl,
  });

  final String name;
  final bool tracked;
  final bool exists;
  final int bytes;
  final String relativeUrl;
}

final class CoreResourceListing {
  CoreResourceListing({
    required this.notebookId,
    required this.nodeId,
    required this.notePath,
    required List<CoreResourceEntry> entries,
  }) : entries = List.unmodifiable(entries);

  final String notebookId;
  final String nodeId;
  final String notePath;
  final List<CoreResourceEntry> entries;
}

final class CoreResourceResult {
  const CoreResourceResult({
    required this.committed,
    this.name,
    this.relativeUrl,
  });

  final bool committed;
  final String? name;
  final String? relativeUrl;
}

final class CoreResourceExport {
  const CoreResourceExport({
    required this.name,
    required this.path,
    required this.bytes,
    required this.sha256,
  });

  final String name;
  final String path;
  final int bytes;
  final String sha256;
}

/// Resource operations run on the existing note owner, or a metadata-only owner.
/// A failed mutation may have effects: recover its retained transaction, never
/// infer rollback or repeat a copy from an error code. Close joins every request.
abstract interface class ResourceCore {
  Future<CoreResourceListing> listResources();
  Future<CoreResourceResult> applyResource(String transactionRoot);
  Future<CoreResourceResult> recoverResource(String transactionRoot);
  Future<CoreResourceExport> exportResource(
    String name,
    String transactionRoot,
  );
  void cancelResourceRead();
  Future<void> close();
}

/// Creates IDs only in the native-validated private transaction workbook.
/// Join [close] before moving or sealing any builder output.
abstract interface class CohortBuilderCore {
  Future<CoreCohortBuildResult> build();
  void cancel();
  Future<void> close();
}
