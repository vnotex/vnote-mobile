import CoreFoundation
import Darwin
import Flutter
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DocumentTransferPlugin") {
      DocumentTransferPlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "WebSurfacePlugin") {
      WebSurfacePlugin.register(with: registrar)
    }
  }
}

/// Owns transfer leases only; provider URLs never become notebook storage.
private final class DocumentTransferPlugin: NSObject, FlutterPlugin,
  FlutterSceneLifeCycleDelegate, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate
{
  private enum ExportError: Error { case unavailable }
  private static let maximumArchiveBytes: Int64 = 4 * 1024 * 1024 * 1024
  private var channel: FlutterMethodChannel?
  private var attached = true
  private var active: Operation?
  private var importing: ImportOperation?
  private let importWorker = DispatchQueue(label: "vnote.document-import", qos: .userInitiated)
  // The registrar can release us on engine detach while UIKit still reads the
  // source. Break this self-retention only at delegate/dismissal completion.
  private var leaseOwner: DocumentTransferPlugin?

  private final class Operation {
    let id: String
    let scope: String
    let source: URL
    let picker: UIDocumentPickerViewController
    weak var scene: UIScene?
    var result: FlutterResult?
    var descriptor: Int32
    var presentationStarted = false
    var presenting = false
    var dismissing = false
    var stopStatus: String?

    init(id: String, scope: String, source: URL, descriptor: Int32,
         picker: UIDocumentPickerViewController, scene: UIScene,
         result: @escaping FlutterResult) {
      self.id = id
      self.scope = scope
      self.source = source
      self.descriptor = descriptor
      self.picker = picker
      self.scene = scene
      self.result = result
    }

    func closeSource() {
      if descriptor >= 0 {
        Darwin.close(descriptor)
        descriptor = -1
      }
    }

    deinit { closeSource() }
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = DocumentTransferPlugin()
    let channel = FlutterMethodChannel(
      name: "vnote.mobile/document_transfer", binaryMessenger: registrar.messenger())
    instance.channel = channel
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.addSceneDelegate(instance)
    // publish is required for FlutterPlugin.detachFromEngine(for:).
    registrar.publish(instance)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "prepareStorage":
      do {
        _ = try prepareStorage()
        result(nil)
      } catch {
        result(FlutterError(code: "storage_unavailable",
                            message: "Private storage protection is unavailable.", details: nil))
      }
    case "saveExport":
      save(call, result: result)
    case "pickImport":
      pickImport(call, result: result)
    case "cancelImport":
      guard let args = call.arguments as? [String: Any], args.count == 2,
            let id = args["operationId"] as? String, Self.validID(id),
            let scope = args["scope"] as? String, Self.validScope(scope) else {
        result(FlutterError(code: "invalid_request", message: "Invalid import request.", details: nil))
        return
      }
      if let operation = importing, operation.id == id, operation.scope == scope {
        stopImport(operation, status: "cancelled")
      }
      result(nil)
    case "cancelExport":
      guard let args = call.arguments as? [String: Any], args.count == 2,
            let id = args["operationId"] as? String, Self.validID(id),
            let scope = args["scope"] as? String, Self.validScope(scope) else {
        result(FlutterError(code: "invalid_request", message: "Invalid export request.", details: nil))
        return
      }
      if let operation = active, operation.id == id, operation.scope == scope {
        requestStop(operation, status: "cancelled")
      }
      // Acknowledges the request only; saveExport still owns the source lease.
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    attached = false
    channel?.setMethodCallHandler(nil)
    channel = nil
    if let operation = active { requestStop(operation, status: "unavailable") }
    if let operation = importing { stopImport(operation, status: "unavailable") }
  }

  func sceneDidDisconnect(_ scene: UIScene) {
    if let operation = active, operation.scene === scene {
      // Disconnect is never successful export, even if a provider was copying.
      requestStop(operation, status: "cancelled")
    }
    if let operation = importing, operation.scene === scene { stopImport(operation, status: "cancelled") }
  }

  private func save(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard attached, active == nil, importing == nil else {
      reply(result, status: "unavailable", incomplete: false)
      return
    }
    guard let args = call.arguments as? [String: Any], args.count == 4,
          let id = args["operationId"] as? String,
          let scope = args["scope"] as? String, scope == "notebook" || scope == "resource",
          let path = args["path"] as? String,
          let name = args["suggestedName"] as? String,
          Self.validID(id), scope != "notebook" || Self.validName(name) else {
      reply(result, status: "failed", incomplete: false)
      return
    }
    guard let (presenter, scene) = activePresenter() else {
      reply(result, status: "unavailable", incomplete: false)
      return
    }
    let source: URL
    let descriptor: Int32
    do {
      let root = try prepareStorage()
      (source, descriptor) = try openSource(root: root, id: id, scope: scope, name: name, path: path)
    } catch {
      reply(result, status: "failed", incomplete: false)
      return
    }
    // UIKit derives its name from the immutable source URL: notebook.zip or the
    // exact ready resource basename. Never rename or alias a retained snapshot.
    let picker = UIDocumentPickerViewController(forExporting: [source], asCopy: true)
    picker.delegate = self
    picker.modalPresentationStyle = .formSheet
    picker.shouldShowFileExtensions = true
    let operation = Operation(id: id, scope: scope, source: source, descriptor: descriptor,
                              picker: picker, scene: scene, result: result)
    active = operation
    leaseOwner = self
    operation.presentationStarted = true
    operation.presenting = true
    presenter.present(picker, animated: false) {
      guard self.active === operation else { return }
      operation.presenting = false
      picker.presentationController?.delegate = self
      if let status = operation.stopStatus { self.requestStop(operation, status: status) }
    }
    picker.presentationController?.delegate = self
    if picker.presentingViewController == nil && !picker.isBeingPresented {
      // UIKit did not establish a presentation, so no remote picker owns a read.
      operation.presenting = false
      finish(operation, status: "failed")
    }
  }

  private func activePresenter() -> (UIViewController, UIWindowScene)? {
    for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
      guard scene.activationState == .foregroundActive,
            let window = scene.windows.first(where: { $0.isKeyWindow }),
            var presenter = window.rootViewController else { continue }
      while let presented = presenter.presentedViewController { presenter = presented }
      guard presenter.viewIfLoaded?.window === window,
            !presenter.isBeingDismissed, !presenter.isBeingPresented,
            !(presenter is UIAlertController) else { continue }
      return (presenter, scene)
    }
    return nil
  }

  private func requestStop(_ operation: Operation, status: String) {
    guard active === operation else { return }
    if operation.stopStatus == nil { operation.stopStatus = status }
    // A stop during presentation is completed by its presentation callback.
    guard !operation.presenting, !operation.dismissing else { return }
    operation.dismissing = true
    operation.picker.dismiss(animated: false) {
      self.finish(operation, status: operation.stopStatus ?? "cancelled")
    }
    // Do not release on a timeout or just because the scene/engine disappeared.
    // Actual dismissal/delegate completion is the source lifetime boundary.
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    if let operation = importing, operation.picker === controller {
      receiveImport(operation, urls: urls)
      return
    }
    guard let operation = active, operation.picker === controller else { return }
    // System/provider completion, not a claim of remote durable synchronization.
    // The returned external URLs are neither retained nor logged.
    finish(operation, status: urls.isEmpty ? "failed" : "saved")
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    if let operation = importing, operation.picker === controller {
      stopImport(operation, status: "cancelled")
      return
    }
    guard let operation = active, operation.picker === controller else { return }
    finish(operation, status: "cancelled")
  }

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    if let operation = importing,
       operation.picker.presentationController === presentationController {
      if !operation.copying { stopImport(operation, status: "cancelled") }
      return
    }
    guard let operation = active,
          operation.picker.presentationController === presentationController else { return }
    finish(operation, status: "cancelled")
  }

  private func finish(_ operation: Operation, status: String) {
    guard active === operation else { return }
    let terminal = operation.stopStatus ?? status
    let result = operation.result
    operation.result = nil
    operation.picker.delegate = nil
    operation.picker.presentationController?.delegate = nil
    operation.closeSource()
    active = nil
    leaseOwner = nil
    if attached, let result = result {
      reply(result, status: terminal,
            incomplete: terminal != "saved" && operation.presentationStarted)
    }
    // Engine/process loss has no deliverable Dart result. Its ready marker is
    // intentionally retained, for explicit retry after an ambiguous outcome.
  }

  private func reply(_ result: FlutterResult, status: String, incomplete: Bool) {
    result(["status": status, "externalMayBeIncomplete": incomplete])
  }

  private enum ImportError: Error { case unavailable, cancelled }
  private static let maximumInputBytes: Int64 = 1024 * 1024 * 1024
  private static let maximumTreeBytes: Int64 = 2 * 1024 * 1024 * 1024
  private static let maximumFileBytes: Int64 = 256 * 1024 * 1024
  private static let importHeadroom: Int64 = 64 * 1024 * 1024

  private final class ImportOperation {
    let id: String
    let scope: String
    let kind: String
    let root: URL
    let transaction: URL
    let picker: UIDocumentPickerViewController
    let scene: UIScene // Retained through picker, worker and security-scope settlement.
    var result: FlutterResult?
    var presenting = false
    var dismissing = false
    var copying = false
    var stopStatus: String?
    var completedStatus: String?
    var sourceName: String?
    var bytes: Int64 = 0
    var entries = 0
    private let lock = NSLock()
    private var cancelled = false
    private var coordinator: NSFileCoordinator?

    init(id: String, scope: String, kind: String, root: URL, transaction: URL,
         picker: UIDocumentPickerViewController, scene: UIScene,
         result: @escaping FlutterResult) {
      self.id = id
      self.scope = scope
      self.kind = kind
      self.root = root
      self.transaction = transaction
      self.picker = picker
      self.scene = scene
      self.result = result
    }

    func checkCancellation() throws {
      lock.lock()
      let stopped = cancelled
      lock.unlock()
      if stopped { throw ImportError.cancelled }
    }

    func setCoordinator(_ value: NSFileCoordinator?) {
      lock.lock()
      coordinator = value
      let stopped = cancelled
      lock.unlock()
      if stopped { value?.cancel() }
    }

    func cancel() {
      lock.lock()
      cancelled = true
      let current = coordinator
      lock.unlock()
      current?.cancel()
    }
  }

  private func pickImport(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard attached, active == nil, importing == nil,
          let (presenter, scene) = activePresenter() else {
      replyImport(result, status: "unavailable")
      return
    }
    guard let args = call.arguments as? [String: Any], args.count == 3,
          let id = args["operationId"] as? String, Self.validID(id),
          let scope = args["scope"] as? String,
          let kind = args["kind"] as? String, Self.validImport(scope: scope, kind: kind) else {
      replyImport(result, status: "failed")
      return
    }
    let root: URL
    let transaction: URL
    do {
      root = try prepareStorage()
      transaction = try validateImportRequest(root: root, id: id, scope: scope, kind: kind)
    } catch {
      replyImport(result, status: "failed")
      return
    }
    let types: [UTType]
    switch kind {
    case "zip": types = [.zip]
    case "folder": types = [.folder]
    case "image": types = [.image]
    default: types = [.item]
    }
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
    picker.allowsMultipleSelection = false
    picker.delegate = self
    picker.modalPresentationStyle = .formSheet
    picker.shouldShowFileExtensions = true
    let operation = ImportOperation(id: id, scope: scope, kind: kind, root: root, transaction: transaction,
                                    picker: picker, scene: scene, result: result)
    importing = operation
    leaseOwner = self
    operation.presenting = true
    presenter.present(picker, animated: false) {
      guard self.importing === operation else { return }
      operation.presenting = false
      picker.presentationController?.delegate = self
      if let status = operation.stopStatus ?? operation.completedStatus {
        self.completeImport(operation, status: status)
      }
    }
    picker.presentationController?.delegate = self
    if picker.presentingViewController == nil && !picker.isBeingPresented {
      operation.presenting = false
      completeImport(operation, status: "failed")
    }
  }

  private func receiveImport(_ operation: ImportOperation, urls: [URL]) {
    guard importing === operation, !operation.copying, operation.completedStatus == nil else { return }
    guard operation.stopStatus == nil, urls.count == 1, let source = urls.first, source.isFileURL else {
      completeImport(operation, status: operation.stopStatus ?? "failed")
      return
    }
    // Acquire the temporary picker capability before its delegate returns.
    guard source.startAccessingSecurityScopedResource() else {
      completeImport(operation, status: "failed")
      return
    }
    operation.copying = true
    importWorker.async {
      var status = "ready"
      do {
        try self.copyCoordinatedImport(operation, source: source)
      } catch ImportError.cancelled {
        status = "cancelled"
      } catch {
        status = "failed"
      }
      // Handles, coordination and security scope have ended before this handoff.
      let settledStatus = status
      DispatchQueue.main.async {
        operation.copying = false
        self.completeImport(operation, status: settledStatus)
      }
    }
  }

  private func stopImport(_ operation: ImportOperation, status: String) {
    guard importing === operation else { return }
    if operation.stopStatus == nil { operation.stopStatus = status }
    operation.cancel()
    completeImport(operation, status: status)
  }

  private func completeImport(_ operation: ImportOperation, status: String) {
    guard importing === operation else { return }
    operation.completedStatus = status
    guard !operation.copying, !operation.presenting, !operation.dismissing else { return }
    if operation.picker.presentingViewController != nil || operation.picker.isBeingDismissed {
      operation.dismissing = true
      operation.picker.dismiss(animated: false) { self.finishImport(operation) }
    } else {
      finishImport(operation)
    }
  }

  private func finishImport(_ operation: ImportOperation) {
    guard importing === operation, !operation.copying else { return }
    let terminal = operation.stopStatus ?? operation.completedStatus ?? "failed"
    let result = operation.result
    operation.result = nil
    operation.picker.delegate = nil
    operation.picker.presentationController?.delegate = nil
    importing = nil
    leaseOwner = nil
    if attached, let result = result {
      replyImport(result, status: terminal,
                  sourceName: terminal == "ready" ? operation.sourceName : nil,
                  bytes: terminal == "ready" ? operation.bytes : 0,
                  entries: terminal == "ready" ? operation.entries : 0)
    }
  }

  private func replyImport(_ result: FlutterResult, status: String,
                           sourceName: String? = nil, bytes: Int64 = 0, entries: Int = 0) {
    result(["status": status, "sourceName": sourceName as Any? ?? NSNull(),
            "bytes": bytes, "entries": entries])
  }

  private func validateImportRequest(root: URL, id: String, scope: String, kind: String) throws -> URL {
    guard Self.validImport(scope: scope, kind: kind) else { throw ImportError.unavailable }
    try requireDirectory(root)
    let group = root.appendingPathComponent(try Self.importNamespace(scope), isDirectory: true)
    let transaction = group.appendingPathComponent(id, isDirectory: true)
    try requireDirectory(group)
    try requireDirectory(transaction)
    let request = try readMarker(transaction.appendingPathComponent("request.json"))
    let version = try Self.markerInteger(request["version"])
    let legacy = scope == "notebook" && request.count == 3 && version == 1
    let scoped = request.count == 4 && version == 2 && request["scope"] as? String == scope
    guard legacy || scoped, request["id"] as? String == id, request["kind"] as? String == kind
    else { throw ImportError.unavailable }
    return transaction
  }

  private func readMarker(_ marker: URL) throws -> [String: Any] {
    let before = try metadata(marker)
    try requireRegularFile(before)
    guard before.st_size <= 16384 else { throw ImportError.unavailable }
    let descriptor = try openImportInput(marker, expected: before)
    defer { Darwin.close(descriptor) }
    var bytes = [UInt8](repeating: 0, count: Int(before.st_size))
    try bytes.withUnsafeMutableBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let count = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw ImportError.unavailable }
        offset += count
      }
    }
    var extra: UInt8 = 0
    guard Darwin.read(descriptor, &extra, 1) == 0 else { throw ImportError.unavailable }
    try requireImportUnchanged(descriptor, url: marker, expected: before)
    let decoded = try JSONSerialization.jsonObject(with: Data(bytes))
    guard let object = decoded as? [String: Any] else { throw ImportError.unavailable }
    return object
  }

  private func copyCoordinatedImport(_ operation: ImportOperation, source: URL) throws {
    // The delegate acquired this scope; release it even on early cancellation.
    defer { source.stopAccessingSecurityScopedResource() }
    try operation.checkCancellation()
    _ = try validateImportRequest(root: operation.root, id: operation.id, scope: operation.scope, kind: operation.kind)
    let coordinator = NSFileCoordinator(filePresenter: nil)
    operation.setCoordinator(coordinator)
    defer { operation.setCoordinator(nil) }
    var coordinationError: NSError?
    var copyError: Error?
    var copied = false
    coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError) { coordinated in
      do {
        try operation.checkCancellation()
        guard coordinated.isFileURL else { throw ImportError.unavailable }
        let name = source.lastPathComponent
        guard !name.isEmpty, name.utf8.count <= 1024,
              !name.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) })
        else { throw ImportError.unavailable }
        operation.sourceName = name
        let value = try self.metadata(coordinated)
        let reserve: Int64
        if operation.kind == "folder" {
          guard (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else { throw ImportError.unavailable }
          reserve = Self.maximumTreeBytes
        } else {
          try self.requireImportFile(value, maximum: operation.kind == "zip"
            ? Self.maximumInputBytes : Self.maximumFileBytes)
          if operation.kind == "zip" {
            guard value.st_size > 0 else { throw ImportError.unavailable }
          } else {
            try self.validateImportName(name, relative: name)
          }
          reserve = value.st_size
        }
        let metadata: Int64 = 64 * 1024 + (operation.kind == "folder" ? 100000 * 8192 : 0)
        try self.requireImportSpace(operation.transaction, bytes: reserve + metadata)
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        try buffer.withUnsafeMutableBytes { buffer in
          if operation.kind == "zip" {
            try self.copyImportFile(operation, source: coordinated,
              destination: operation.transaction.appendingPathComponent("input.zip"),
              expected: value, maximum: Self.maximumInputBytes, buffer: buffer)
            operation.entries = 1
          } else {
            let destination = operation.transaction.appendingPathComponent("unpacked", isDirectory: true)
            try self.createImportDirectory(destination)
            let accepted = try self.createImportOutput(operation.transaction.appendingPathComponent("accepted.jsonl"))
            defer { Darwin.close(accepted) }
            if operation.kind == "folder" {
              var visited = Set<String>()
              try self.copyImportDirectory(operation, source: coordinated, destination: destination,
                prefix: "", depth: 0, visited: &visited, inventory: accepted, buffer: buffer)
            } else {
              try self.copyImportFile(operation, source: coordinated,
                destination: destination.appendingPathComponent(name), expected: value,
                maximum: Self.maximumFileBytes, buffer: buffer)
              var record = try JSONSerialization.data(withJSONObject: ["path": name, "type": "file"],
                options: [.sortedKeys, .withoutEscapingSlashes])
              record.append(10)
              try self.requireImportSpace(operation.transaction, bytes: Int64(record.count))
              try record.withUnsafeBytes { try self.writeImportBytes(accepted, buffer: $0) }
              operation.entries = 1
            }
            guard Darwin.fsync(accepted) == 0 else { throw ImportError.unavailable }
          }
        }
        try operation.checkCancellation()
        copied = true
      } catch { copyError = error }
    }
    if let error = copyError { throw error }
    guard coordinationError == nil, copied else { throw ImportError.unavailable }
    try operation.checkCancellation()
  }

  private func openImportInput(_ url: URL, expected: stat) throws -> Int32 {
    let descriptor = url.withUnsafeFileSystemRepresentation { pointer -> Int32 in
      guard let pointer = pointer else { return -1 }
      return Darwin.open(pointer, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard descriptor >= 0 else { throw ImportError.unavailable }
    do {
      try requireImportUnchanged(descriptor, url: url, expected: expected)
      return descriptor
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  private func requireImportUnchanged(_ descriptor: Int32, url: URL, expected: stat) throws {
    var opened = stat()
    let current = try metadata(url)
    guard Darwin.fstat(descriptor, &opened) == 0 else { throw ImportError.unavailable }
    try requireImportIdentity(opened, expected: expected)
    try requireImportIdentity(current, expected: expected)
  }

  private func requireImportIdentity(_ value: stat, expected: stat) throws {
    guard value.st_dev == expected.st_dev, value.st_ino == expected.st_ino,
          value.st_mode == expected.st_mode, value.st_nlink == expected.st_nlink,
          value.st_size == expected.st_size,
          value.st_mtimespec.tv_sec == expected.st_mtimespec.tv_sec,
          value.st_mtimespec.tv_nsec == expected.st_mtimespec.tv_nsec,
          value.st_ctimespec.tv_sec == expected.st_ctimespec.tv_sec,
          value.st_ctimespec.tv_nsec == expected.st_ctimespec.tv_nsec
    else { throw ImportError.unavailable }
  }

  private func requireImportFile(_ value: stat, maximum: Int64) throws {
    guard (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), value.st_nlink == 1,
          value.st_size >= 0, value.st_size <= maximum else { throw ImportError.unavailable }
  }

  private func createImportOutput(_ url: URL) throws -> Int32 {
    let descriptor = url.withUnsafeFileSystemRepresentation { pointer -> Int32 in
      guard let pointer = pointer else { return -1 }
      return Darwin.open(pointer, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    }
    guard descriptor >= 0 else { throw ImportError.unavailable }
    return descriptor
  }

  private func createImportDirectory(_ url: URL) throws {
    let result = url.withUnsafeFileSystemRepresentation { pointer -> Int32 in
      guard let pointer = pointer else { return -1 }
      return Darwin.mkdir(pointer, 0o700)
    }
    guard result == 0 else { throw ImportError.unavailable }
    try requireDirectory(url)
  }

  private func writeImportBytes(_ descriptor: Int32, buffer: UnsafeRawBufferPointer) throws {
    var offset = 0
    while offset < buffer.count {
      let written = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
      if written < 0 && errno == EINTR { continue }
      guard written > 0 else { throw ImportError.unavailable }
      offset += written
    }
  }

  private func requireImportSpace(_ transaction: URL, bytes: Int64) throws {
    var space = statfs()
    let result = transaction.withUnsafeFileSystemRepresentation { pointer -> Int32 in
      guard let pointer = pointer else { return -1 }
      return Darwin.statfs(pointer, &space)
    }
    guard result == 0, space.f_bsize > 0,
          space.f_bavail >= UInt64((bytes + Self.importHeadroom + Int64(space.f_bsize) - 1) / Int64(space.f_bsize))
    else { throw ImportError.unavailable }
  }

  private func copyImportFile(_ operation: ImportOperation, source: URL, destination: URL,
                              expected: stat, maximum: Int64, buffer: UnsafeMutableRawBufferPointer) throws {
    try operation.checkCancellation()
    try requireImportFile(expected, maximum: maximum)
    let input = try openImportInput(source, expected: expected)
    defer { Darwin.close(input) }
    let output = try createImportOutput(destination)
    defer { Darwin.close(output) }
    var copied: Int64 = 0
    while true {
      try operation.checkCancellation()
      let count = Darwin.read(input, buffer.baseAddress!, buffer.count)
      if count < 0 && errno == EINTR { continue }
      guard count >= 0 else { throw ImportError.unavailable }
      if count == 0 { break }
      copied += Int64(count)
      operation.bytes += Int64(count)
      guard copied <= maximum, copied <= expected.st_size, operation.bytes <= Self.maximumTreeBytes
      else { throw ImportError.unavailable }
      try requireImportSpace(operation.transaction, bytes: Int64(count))
      try writeImportBytes(output, buffer: UnsafeRawBufferPointer(start: buffer.baseAddress, count: count))
    }
    guard copied == expected.st_size else { throw ImportError.unavailable }
    try requireImportUnchanged(input, url: source, expected: expected)
    try operation.checkCancellation()
    guard Darwin.fsync(output) == 0 else { throw ImportError.unavailable }
  }

  private func copyImportDirectory(_ operation: ImportOperation, source: URL, destination: URL,
                                   prefix: String, depth: Int, visited: inout Set<String>,
                                   inventory: Int32, buffer: UnsafeMutableRawBufferPointer) throws {
    try operation.checkCancellation()
    let expected = try metadata(source)
    guard depth <= 32, (expected.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
          visited.insert("\(expected.st_dev):\(expected.st_ino)").inserted
    else { throw ImportError.unavailable }
    let descriptor = try openImportInput(source, expected: expected)
    guard let directory = Darwin.fdopendir(descriptor) else {
      Darwin.close(descriptor)
      throw ImportError.unavailable
    }
    defer { Darwin.closedir(directory) }
    while true {
      try operation.checkCancellation()
      errno = 0
      guard let entry = Darwin.readdir(directory) else {
        guard errno == 0 else { throw ImportError.unavailable }
        break
      }
      let nameCapacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
      let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: nameCapacity) {
          String(validatingUTF8: $0)
        }
      }
      guard let name = name else { throw ImportError.unavailable }
      if name == "." || name == ".." { continue }
      guard depth < 32, operation.entries < 100000 else { throw ImportError.unavailable }
      let relative = prefix.isEmpty ? name : "\(prefix)/\(name)"
      try validateImportName(name, relative: relative)
      let child = source.appendingPathComponent(name)
      let output = destination.appendingPathComponent(name)
      let value = try metadata(child)
      let isDirectory = (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
      operation.entries += 1
      if isDirectory {
        try createImportDirectory(output)
      } else {
        try copyImportFile(operation, source: child, destination: output,
                           expected: value, maximum: Self.maximumFileBytes, buffer: buffer)
      }
      var record = try JSONSerialization.data(withJSONObject: ["path": relative,
        "type": isDirectory ? "directory" : "file"], options: [.sortedKeys, .withoutEscapingSlashes])
      record.append(10)
      try requireImportSpace(operation.transaction, bytes: Int64(record.count))
      try record.withUnsafeBytes { try writeImportBytes(inventory, buffer: $0) }
      if isDirectory {
        try copyImportDirectory(operation, source: child, destination: output, prefix: relative,
                                 depth: depth + 1, visited: &visited, inventory: inventory, buffer: buffer)
      }
    }
    try requireImportUnchanged(descriptor, url: source, expected: expected)
  }

  private func validateImportName(_ name: String, relative: String) throws {
    let base = String(name.prefix(while: { $0 != "." })).uppercased()
    let numberedDevice = (base.hasPrefix("COM") || base.hasPrefix("LPT")) && base.count == 4 &&
      "123456789¹²³".contains(base.last!)
    guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
          relative.utf8.count <= 1024, !name.hasSuffix("."), !name.hasSuffix(" "),
          !name.unicodeScalars.contains(where: {
            $0.value < 32 || (127...159).contains($0.value) || "/\\:*?\"<>|".unicodeScalars.contains($0)
          }), !["CON", "PRN", "AUX", "NUL"].contains(base), !numberedDevice
    else { throw ImportError.unavailable }
  }

  private func prepareStorage() throws -> URL {
    let manager = FileManager.default
    guard let libraryURL = manager.urls(for: .libraryDirectory, in: .userDomainMask).first,
          let supportURL = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else { throw ExportError.unavailable }
    // Resolve only the OS-owned anchor; every application-owned component is
    // checked without following links and is never replaced by this adapter.
    let library = libraryURL.resolvingSymlinksInPath().standardizedFileURL
    _ = try requireDirectory(library)
    let root = library.appendingPathComponent("Application Support", isDirectory: true)
    guard supportURL.lastPathComponent == "Application Support",
          supportURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
            == library.path else { throw ExportError.unavailable }
    try prepareExcludedDirectory(root)
    for name in ["core", "notebooks", "exports", "imports", "cohorts", "resources"] {
      try prepareExcludedDirectory(root.appendingPathComponent(name, isDirectory: true))
    }
    guard UIApplication.shared.isProtectedDataAvailable else { throw ExportError.unavailable }
    for name in ["drafts", "previews"] {
      try prepareExcludedDirectory(root.appendingPathComponent(name, isDirectory: true),
                                   protection: .completeUntilFirstUserAuthentication)
    }
    return root
  }

  private func prepareExcludedDirectory(_ directory: URL,
                                        protection: FileProtectionType? = nil) throws {
    var metadata = stat()
    let exists = directory.withUnsafeFileSystemRepresentation { pointer -> Int32 in
      guard let pointer = pointer else { return -1 }
      return Darwin.lstat(pointer, &metadata)
    }
    if exists != 0 {
      guard errno == ENOENT else { throw ExportError.unavailable }
      var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
      if let protection = protection { attributes[.protectionKey] = protection }
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                              attributes: attributes)
    }
    let before = try requireDirectory(directory)
    if let protection = protection {
      try FileManager.default.setAttributes([.protectionKey: protection], ofItemAtPath: directory.path)
      let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
      guard attributes[.protectionKey] as? FileProtectionType == protection
      else { throw ExportError.unavailable }
    }
    // Apple's group-directory exclusion mechanism: these stable directories
    // remain in place when child files are replaced. This is system guidance,
    // not proof that every OS/provider backup implementation excludes the data.
    var marked = directory
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try marked.setResourceValues(values)
    marked.removeAllCachedResourceValues()
    let verified = try marked.resourceValues(forKeys: [.isExcludedFromBackupKey])
    let after = try requireDirectory(directory)
    guard verified.isExcludedFromBackup == true,
          before.st_dev == after.st_dev, before.st_ino == after.st_ino
    else { throw ExportError.unavailable }
  }

  private func metadata(_ url: URL) throws -> stat {
    var value = stat()
    let result = url.withUnsafeFileSystemRepresentation { pointer -> Int32 in
      guard let pointer = pointer else { return -1 }
      return Darwin.lstat(pointer, &value)
    }
    guard result == 0 else { throw ExportError.unavailable }
    return value
  }

  @discardableResult
  private func requireDirectory(_ url: URL) throws -> stat {
    let value = try metadata(url)
    guard (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
          url.resolvingSymlinksInPath().standardizedFileURL.path == url.path
    else { throw ExportError.unavailable }
    return value
  }

  private func requireRegularFile(_ value: stat) throws {
    guard (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), value.st_nlink == 1,
          value.st_size > 0, value.st_size <= Self.maximumArchiveBytes
    else { throw ExportError.unavailable }
  }

  private func openSource(root: URL, id: String, scope: String, name: String, path: String) throws -> (URL, Int32) {
    guard path.utf8.count <= 16384, !path.utf8.contains(0), scope == "notebook" || scope == "resource"
    else { throw ExportError.unavailable }
    try requireDirectory(root)
    let group = root.appendingPathComponent(scope == "resource" ? "resources" : "exports", isDirectory: true)
    let transaction = group.appendingPathComponent(id, isDirectory: true)
    try requireDirectory(group)
    try requireDirectory(transaction)
    let source: URL
    var readyBytes: Int64?
    if scope == "resource" {
      try validateImportName(name, relative: name)
      let request = try readMarker(transaction.appendingPathComponent("request.json"))
      guard let kind = request["kind"] as? String else { throw ExportError.unavailable }
      _ = try validateImportRequest(root: root, id: id, scope: scope, kind: kind)
      let output = transaction.appendingPathComponent("output", isDirectory: true)
      try requireDirectory(output)
      let ready = try readMarker(transaction.appendingPathComponent("ready.json"))
      let version = try Self.markerInteger(ready["version"])
      let bytes = try Self.markerInteger(ready["bytes"])
      guard ready.count == 6, version == 1, ready["id"] as? String == id,
            ready["scope"] as? String == scope, ready["name"] as? String == name,
            bytes >= 0, bytes <= Self.maximumInputBytes,
            let digest = ready["sha256"] as? String, digest.utf8.count == 64,
            digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
      else { throw ExportError.unavailable }
      readyBytes = bytes
      source = output.appendingPathComponent(name, isDirectory: false)
    } else {
      source = transaction.appendingPathComponent("notebook.zip", isDirectory: false)
    }
    guard path == source.path else { throw ExportError.unavailable }
    let before = try metadata(source)
    if let bytes = readyBytes {
      try requireImportFile(before, maximum: Self.maximumInputBytes)
      guard before.st_size == bytes else { throw ExportError.unavailable }
    } else {
      try requireRegularFile(before)
    }
    guard source.resolvingSymlinksInPath().standardizedFileURL.path == path
    else { throw ExportError.unavailable }
    let descriptor = source.withUnsafeFileSystemRepresentation { pointer -> Int32 in
      guard let pointer = pointer else { return -1 }
      return Darwin.open(pointer, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard descriptor >= 0 else { throw ExportError.unavailable }
    do {
      try requireDirectory(root)
      try requireDirectory(group)
      try requireDirectory(transaction)
      if scope == "resource" { try requireDirectory(source.deletingLastPathComponent()) }
      try requireImportUnchanged(descriptor, url: source, expected: before)
      return (source, descriptor)
    } catch {
      Darwin.close(descriptor)
      throw ExportError.unavailable
    }
  }

  private static func markerInteger(_ value: Any?) throws -> Int64 {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          !["f", "d"].contains(String(cString: number.objCType)),
          number.compare(NSNumber(value: Int64.min)) != .orderedAscending,
          number.compare(NSNumber(value: Int64.max)) != .orderedDescending
    else { throw ImportError.unavailable }
    return number.int64Value
  }

  private static func validScope(_ scope: String) -> Bool {
    ["notebook", "cohort", "resource"].contains(scope)
  }

  private static func validImport(scope: String, kind: String) -> Bool {
    switch scope {
    case "notebook": return ["zip", "folder"].contains(kind)
    case "cohort": return ["zip", "folder", "file"].contains(kind)
    case "resource": return ["file", "image"].contains(kind)
    default: return false
    }
  }

  private static func importNamespace(_ scope: String) throws -> String {
    switch scope {
    case "notebook": return "imports"
    case "cohort": return "cohorts"
    case "resource": return "resources"
    default: throw ImportError.unavailable
    }
  }

  private static func validID(_ value: String) -> Bool {
    value.utf8.count == 32 && value.utf8.allSatisfy {
      (48...57).contains($0) || (97...102).contains($0)
    }
  }

  private static func validName(_ value: String) -> Bool {
    let bytes = value.utf8
    guard bytes.count <= 100, value.hasSuffix(".zip"), !value.contains(".."),
          let first = bytes.first, isAlphanumeric(first) else { return false }
    return bytes.allSatisfy { isAlphanumeric($0) || $0 == 45 || $0 == 46 || $0 == 95 }
  }

  private static func isAlphanumeric(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
  }
}
