import Darwin
import Flutter
import UIKit

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
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DocumentExportPlugin") {
      DocumentExportPlugin.register(with: registrar)
    }
  }
}

/// The picker owns a lease on one immutable ZIP, not on a notebook or core owner.
private final class DocumentExportPlugin: NSObject, FlutterPlugin,
  FlutterSceneLifeCycleDelegate, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate
{
  private enum ExportError: Error { case unavailable }
  private static let maximumArchiveBytes: Int64 = 4 * 1024 * 1024 * 1024
  private var channel: FlutterMethodChannel?
  private var attached = true
  private var active: Operation?
  // The registrar can release us on engine detach while UIKit still reads the
  // source. Break this self-retention only at delegate/dismissal completion.
  private var leaseOwner: DocumentExportPlugin?

  private final class Operation {
    let id: String
    let source: URL
    let picker: UIDocumentPickerViewController
    weak var scene: UIScene?
    var result: FlutterResult?
    var descriptor: Int32
    var presentationStarted = false
    var presenting = false
    var dismissing = false
    var stopStatus: String?

    init(id: String, source: URL, descriptor: Int32,
         picker: UIDocumentPickerViewController, scene: UIScene,
         result: @escaping FlutterResult) {
      self.id = id
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
    let instance = DocumentExportPlugin()
    let channel = FlutterMethodChannel(
      name: "vnote.mobile/document_export", binaryMessenger: registrar.messenger())
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
    case "cancelExport":
      guard let args = call.arguments as? [String: Any],
            let id = args["operationId"] as? String, Self.validID(id) else {
        result(FlutterError(code: "invalid_request", message: "Invalid export request.", details: nil))
        return
      }
      if let operation = active, operation.id == id {
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
  }

  func sceneDidDisconnect(_ scene: UIScene) {
    if let operation = active, operation.scene === scene {
      // Disconnect is never successful export, even if a provider was copying.
      requestStop(operation, status: "cancelled")
    }
  }

  private func save(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard attached, active == nil else {
      reply(result, status: "unavailable", incomplete: false)
      return
    }
    guard let args = call.arguments as? [String: Any],
          let id = args["operationId"] as? String,
          let path = args["path"] as? String,
          let name = args["suggestedName"] as? String,
          Self.validID(id), Self.validName(name) else {
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
      (source, descriptor) = try openSource(root: root, id: id, path: path)
    } catch {
      reply(result, status: "failed", incomplete: false)
      return
    }
    // UIKit derives its initial name from the source URL (notebook.zip); it has
    // no suggested-name setter. Never rename or alias the immutable ready ZIP.
    let picker = UIDocumentPickerViewController(forExporting: [source], asCopy: true)
    picker.delegate = self
    picker.modalPresentationStyle = .formSheet
    picker.shouldShowFileExtensions = true
    let operation = Operation(id: id, source: source, descriptor: descriptor,
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
    guard let operation = active, operation.picker === controller else { return }
    // System/provider completion, not a claim of remote durable synchronization.
    // The returned external URLs are neither retained nor logged.
    finish(operation, status: urls.isEmpty ? "failed" : "saved")
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    guard let operation = active, operation.picker === controller else { return }
    finish(operation, status: "cancelled")
  }

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
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
    for name in ["core", "notebooks", "exports"] {
      try prepareExcludedDirectory(root.appendingPathComponent(name, isDirectory: true))
    }
    return root
  }

  private func prepareExcludedDirectory(_ directory: URL) throws {
    var metadata = stat()
    let exists = directory.withUnsafeFileSystemRepresentation { pointer -> Int32 in
      guard let pointer = pointer else { return -1 }
      return Darwin.lstat(pointer, &metadata)
    }
    if exists != 0 {
      guard errno == ENOENT else { throw ExportError.unavailable }
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
    }
    let before = try requireDirectory(directory)
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

  private func openSource(root: URL, id: String, path: String) throws -> (URL, Int32) {
    guard path.utf8.count <= 16384, !path.utf8.contains(0) else { throw ExportError.unavailable }
    let exports = root.appendingPathComponent("exports", isDirectory: true)
    let transaction = exports.appendingPathComponent(id, isDirectory: true)
    let source = transaction.appendingPathComponent("notebook.zip", isDirectory: false)
    guard path == source.path else { throw ExportError.unavailable }
    try requireDirectory(root)
    try requireDirectory(exports)
    try requireDirectory(transaction)
    let before = try metadata(source)
    try requireRegularFile(before)
    guard source.resolvingSymlinksInPath().standardizedFileURL.path == path
    else { throw ExportError.unavailable }
    let descriptor = source.withUnsafeFileSystemRepresentation { pointer -> Int32 in
      guard let pointer = pointer else { return -1 }
      return Darwin.open(pointer, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard descriptor >= 0 else { throw ExportError.unavailable }
    do {
      var opened = stat()
      guard Darwin.fstat(descriptor, &opened) == 0 else { throw ExportError.unavailable }
      try requireRegularFile(opened)
      try requireDirectory(root)
      try requireDirectory(exports)
      try requireDirectory(transaction)
      let after = try metadata(source)
      guard opened.st_dev == before.st_dev, opened.st_ino == before.st_ino,
            opened.st_dev == after.st_dev, opened.st_ino == after.st_ino,
            opened.st_size == before.st_size, opened.st_size == after.st_size,
            opened.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
            opened.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
      else { throw ExportError.unavailable }
      return (source, descriptor)
    } catch {
      Darwin.close(descriptor)
      throw ExportError.unavailable
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
