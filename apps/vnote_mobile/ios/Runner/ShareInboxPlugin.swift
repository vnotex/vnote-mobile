import CoreFoundation
import Darwin
import Flutter
import UIKit

final class ShareInboxPlugin: NSObject, FlutterPlugin, FlutterSceneLifeCycleDelegate,
  UIAdaptivePresentationControllerDelegate {
  private let worker = DispatchQueue(label: "vnote.share.inbox", qos: .userInitiated)
  private let storage = DocumentTransferPlugin()
  private var attached = true
  private var channel: FlutterMethodChannel?
  private var active: Presentation?
  private var leaseOwner: ShareInboxPlugin?
  // Pin the real bundled host for process lifetime, just as the Dart FFI owner
  // does. The extension never compiles this file or loads this library.
  private static var host: UnsafeMutableRawPointer?
  private static let hostLock = NSLock()
  private typealias Activate = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32
  private typealias Prove = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32
  private typealias ExportCheck = @convention(c) (UnsafePointer<CChar>, UInt64) -> Int32

  private final class Presentation {
    let controller: UIActivityViewController
    weak var scene: UIScene?
    var result: FlutterResult?
    var descriptors: [Int32]
    let snapshot: ShareInbox.Snapshot
    var presenting = true
    var stopping: String?
    var dismissing = false
    init(controller: UIActivityViewController, scene: UIScene,
         result: @escaping FlutterResult, descriptors: [Int32], snapshot: ShareInbox.Snapshot) {
      self.controller = controller; self.scene = scene; self.result = result
      self.descriptors = descriptors; self.snapshot = snapshot
    }
    deinit { for descriptor in descriptors { Darwin.close(descriptor) } }
  }
  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = ShareInboxPlugin()
    let channel = FlutterMethodChannel(name: "vnote.mobile/share_inbox", binaryMessenger: registrar.messenger())
    instance.channel = channel
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.addSceneDelegate(instance); registrar.publish(instance)
  }
  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard attached else { return }
    if call.method == "export" || call.method == "shareExport" {
      share(call, result: result); return
    }
    let cleaning = call.method == "cleanupExports"
    if cleaning {
      guard active == nil, !preparingShare else {
        result(FlutterError(code: "inbox_busy", message: "A system share is still active.", details: nil)); return
      }
      preparingShare = true
    }
    worker.async {
      do {
        let reply = try self.execute(call)
        DispatchQueue.main.async {
          if cleaning { self.preparingShare = false }
          if self.attached { result(reply) }
        }
      } catch {
        let code: String
        switch error {
        case ShareInboxError.unavailable, ShareInboxError.inactive: code = "inbox_unavailable"
        case ShareInboxError.capacity: code = "inbox_capacity"
        case ShareInboxError.busy: code = "inbox_busy"
        case ShareInboxError.missingPayload: code = "payload_unavailable"
        case ShareInboxError.proofRequired: code = "inbox_proof_required"
        case ShareInboxError.invalid: code = "invalid_request"
        default: code = "inbox_corrupt"
        }
        DispatchQueue.main.async {
          if cleaning { self.preparingShare = false }
          if self.attached { result(FlutterError(code: code, message: "The share operation could not complete safely.", details: nil)) }
        }
      }
    }
  }
  private func arguments(_ call: FlutterMethodCall, keys: Set<String>) throws -> [String: Any] {
    if keys.isEmpty {
      guard call.arguments == nil || (call.arguments as? [String: Any])?.isEmpty == true else { throw ShareInboxError.invalid }
      return [:]
    }
    guard let args = call.arguments as? [String: Any], Set(args.keys) == keys else { throw ShareInboxError.invalid }
    return args
  }
  private func identifier(_ args: [String: Any], _ key: String) throws -> String {
    guard let id = args[key] as? String, ShareInbox.validHex(id, count: 32) else { throw ShareInboxError.invalid }
    return id
  }
  private func execute(_ call: FlutterMethodCall) throws -> Any? {
    switch call.method {
    case "getLocale":
      _ = try arguments(call, keys: [])
      let locale = try getLocale(); try? mirrorLocale(locale); return locale
    case "setLocale":
      let args = try arguments(call, keys: ["locale"])
      guard let locale = args["locale"] as? String, ["system", "en", "zh"].contains(locale) else { throw ShareInboxError.invalid }
      let support = try storage.prepareStorage()
      try ShareInbox.atomic(Data(locale.utf8), to: support.appendingPathComponent("share-locale"))
      try? mirrorLocale(locale); return nil
    case "list":
      _ = try arguments(call, keys: [])
      guard ShareInbox.configuredGroup != nil else { return ["available": false, "records": []] }
      do { return ["available": true, "records": try ShareInbox.configured().records()] }
      catch ShareInboxError.unavailable { return ["available": false, "records": []] }
    case "activate":
      _ = try arguments(call, keys: [])
      let inbox = try ShareInbox.configured(); let support = try storage.prepareStorage()
      try mirrorLocale(getLocale())
      let symbol: Activate = unsafeBitCast(try Self.symbol("vxm_share_inbox_activate"), to: Activate.self)
      try inbox.locked { _ in
        let code = support.path.withCString { root in inbox.root.path.withCString { symbol(root, $0) } }
        guard code == 0 else { throw ShareInboxError.proofRequired }
        try ShareInbox.protect(inbox.root.appendingPathComponent("activation.json"))
      }
      return nil
    case "claim":
      let args = try arguments(call, keys: ["id", "operationId", "target"])
      guard let target = args["target"] as? [String: Any] else { throw ShareInboxError.invalid }
      return try ShareInbox.configured().claim(id: identifier(args, "id"), operation: identifier(args, "operationId"),
        target: ShareInbox.validateTarget(target)).wire
    case "stage":
      let args = try arguments(call, keys: ["id", "operationId"])
      return try stage(id: identifier(args, "id"), operation: identifier(args, "operationId"))
    case "consume":
      let args = try arguments(call, keys: ["id", "operationId", "cohortId"])
      guard let cohort = args["cohortId"] as? String, !cohort.isEmpty, cohort.utf8.count <= 128 else { throw ShareInboxError.invalid }
      let support = try storage.prepareStorage()
      try ShareInbox.configured().settle(id: identifier(args, "id"), operation: identifier(args, "operationId"),
        cohort: cohort, discard: false) { record in try self.prove(record, support: support, cohort: cohort, disposition: "consume") }
      return nil
    case "discard":
      let args = try arguments(call, keys: ["id"]); let support = try storage.prepareStorage()
      try ShareInbox.configured().settle(id: identifier(args, "id"), operation: nil, cohort: nil, discard: true) { record in
        try self.prove(record, support: support, cohort: nil, disposition: "discard")
      }
      return nil
    case "anotherCopy":
      let args = try arguments(call, keys: ["id"])
      return try ShareInbox.configured().anotherCopy(id: identifier(args, "id")).wire
    case "dismissDuplicate":
      let args = try arguments(call, keys: ["id"])
      try ShareInbox.configured().dismissDuplicate(id: identifier(args, "id")); return nil
    case "forgetHistory":
      _ = try arguments(call, keys: []); try ShareInbox.configured().forgetHistory(); return nil
    case "cleanupExports":
      _ = try arguments(call, keys: [])
      let support = try storage.prepareStorage()
      if try ShareInbox.exists(support.appendingPathComponent("outgoing-shares")) {
        try ShareInbox.outgoing(support: support).cleanupExports()
      }
      if ShareInbox.configuredGroup != nil { try ShareInbox.configured().cleanupExports() }
      return nil
    default: return FlutterMethodNotImplemented
    }
  }
  private func getLocale() throws -> String {
    let root = try storage.prepareStorage(); let file = root.appendingPathComponent("share-locale")
    guard try ShareInbox.exists(file) else { return "system" }
    guard let value = String(data: try ShareInbox.readData(file, maximum: 16), encoding: .utf8),
          ["system", "en", "zh"].contains(value) else { throw ShareInboxError.corrupt }
    return value
  }
  private func mirrorLocale(_ value: String) throws {
    guard ShareInbox.configuredGroup != nil else { return }
    let inbox = try ShareInbox.configured()
    // The protected AppGroup file, not preferences daemon timing, is the stopped
    // extension's authoritative locale. No group means private choice still works.
    try inbox.locked { _ in try ShareInbox.atomic(Data(value.utf8), to: inbox.root.appendingPathComponent("locale")) }
  }
  private static func symbol(_ name: String) throws -> UnsafeMutableRawPointer {
    hostLock.lock(); defer { hostLock.unlock() }
    if host == nil {
      // hook/build.dart emits libvnote_host.dylib; Flutter's iOS native-assets
      // frameworkUri strips lib/.dylib => vnote_host.framework/vnote_host.
      guard let frameworks = Bundle.main.privateFrameworksURL else { throw ShareInboxError.unavailable }
      let bundleRoot = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
      let binary = frameworks.resolvingSymlinksInPath().standardizedFileURL
        .appendingPathComponent("vnote_host.framework/vnote_host")
      guard binary.resolvingSymlinksInPath().path == binary.path,
            binary.path.hasPrefix(bundleRoot.path + "/") else { throw ShareInboxError.unavailable }
      let identity = try ShareInbox.metadata(binary)
      guard identity.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw ShareInboxError.unavailable }
      host = Darwin.dlopen(binary.path, RTLD_NOW | RTLD_LOCAL)
    }
    guard let library = host, let pointer = Darwin.dlsym(library, name) else { throw ShareInboxError.unavailable }
    return pointer
  }
  private func prove(_ record: ShareInbox.Record, support: URL, cohort: String?, disposition: String) throws {
    guard let operation = record.operationId, let target = record.target else { throw ShareInboxError.invalid }
    var claim: [String: Any] = ["id": record.id, "operationId": operation, "target": target.wire]
    if let cohort = cohort { claim["cohortId"] = cohort }
    let json = try JSONSerialization.data(withJSONObject: claim, options: [.sortedKeys, .withoutEscapingSlashes])
    guard let claimString = String(data: json, encoding: .utf8) else { throw ShareInboxError.invalid }
    let function: Prove = unsafeBitCast(try Self.symbol("vxm_share_inbox_prove"), to: Prove.self)
    let code = support.path.withCString { root in claimString.withCString { claim in
      disposition.withCString { function(root, claim, $0) }
    } }
    guard code == 0 else { throw ShareInboxError.proofRequired }
  }

  private func stage(id: String, operation: String) throws -> [String: Any] {
    let support = try storage.prepareStorage()
    let group = support.appendingPathComponent("cohorts"); try ShareInbox.requireDirectory(group)
    let transaction = group.appendingPathComponent(operation); try ShareInbox.requireDirectory(transaction)
    return try ShareInbox.configured().withPayload(id: id) { record, payload, text in
      guard record.state == "importing", record.operationId == operation, let target = record.target else { throw ShareInboxError.invalid }
      var pinned = target.wire; pinned["version"] = 1; pinned["id"] = operation
      let ownership = try ShareInbox.json(group.appendingPathComponent("inbox-\(operation).json"))
      let expected: [String: Any] = ["version": 1, "id": operation, "scope": "cohort", "inboxId": id, "target": pinned]
      guard NSDictionary(dictionary: ownership).isEqual(to: expected),
            NSDictionary(dictionary: try ShareInbox.json(transaction.appendingPathComponent("request.json")))
              .isEqual(to: ["version": 2, "id": operation, "scope": "cohort", "kind": "folder"]),
            NSDictionary(dictionary: try ShareInbox.json(transaction.appendingPathComponent("target.json"))).isEqual(to: pinned)
      else { throw ShareInboxError.proofRequired }
      let allowed: Set<String> = ["request.json", "target.json", "unpacked", "accepted.jsonl"]
      for child in try FileManager.default.contentsOfDirectory(at: transaction, includingPropertiesForKeys: nil) {
        guard allowed.contains(child.lastPathComponent) else { throw ShareInboxError.proofRequired }
      }
      let unpacked = transaction.appendingPathComponent("unpacked")
      let names = Set(record.files.map { $0.name } + (text.isEmpty ? [] : ["Shared text.md"]))
      if try ShareInbox.exists(unpacked) {
        try ShareInbox.requireDirectory(unpacked)
        for child in try FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil) {
          let identity = try ShareInbox.metadata(child)
          guard names.contains(child.lastPathComponent), identity.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                identity.st_nlink == 1, identity.st_size >= 0, identity.st_size <= ShareInbox.maximumFile
          else { throw ShareInboxError.proofRequired }
        }
        try FileManager.default.removeItem(at: unpacked)
      }
      let accepted = transaction.appendingPathComponent("accepted.jsonl")
      if try ShareInbox.exists(accepted) {
        _ = try ShareInbox.readData(accepted, maximum: 128 * 1024)
        try FileManager.default.removeItem(at: accepted)
      }
      try ShareInbox.prepareDirectory(unpacked)
      var inventory = Data()
      func entry(_ name: String) throws {
        inventory.append(try JSONSerialization.data(withJSONObject: ["path": name, "type": "file"], options: [.sortedKeys, .withoutEscapingSlashes]))
        inventory.append(10)
      }
      if !text.isEmpty {
        try ShareInbox.atomic(text, to: unpacked.appendingPathComponent("Shared text.md")); try entry("Shared text.md")
      }
      for (index, file) in record.files.enumerated() {
        let copied = try ShareInbox.copyFile(payload.appendingPathComponent("file-\(index)"),
          to: unpacked.appendingPathComponent(file.name), maximum: ShareInbox.maximumFile)
        guard copied.0 == file.bytes, copied.1 == file.sha256 else { throw ShareInboxError.corrupt }
        try entry(file.name)
      }
      try ShareInbox.syncDirectory(unpacked)
      try ShareInbox.atomic(inventory, to: accepted); try ShareInbox.syncDirectory(transaction)
      return ["status": "captured", "sourceName": "Shared items", "bytes": record.bytes, "entries": names.count]
    }
  }

  private func integer(_ value: Any?) throws -> Int64 {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          !["f", "d"].contains(String(cString: number.objCType)),
          number.compare(NSNumber(value: 0)) != .orderedAscending,
          number.compare(NSNumber(value: Int64.max)) != .orderedDescending else { throw ShareInboxError.corrupt }
    return number.int64Value
  }
  private func exportSnapshot(_ args: [String: Any]) throws -> ShareInbox.Snapshot {
    let id = try identifier(args, "operationId")
    guard let scope = args["scope"] as? String, ["notebook", "resource"].contains(scope),
          let path = args["path"] as? String, let name = args["suggestedName"] as? String else { throw ShareInboxError.invalid }
    let root = try storage.prepareStorage()
    let (source, descriptor) = try storage.openSource(root: root, id: id, scope: scope, name: name, path: path)
    defer { Darwin.close(descriptor) }
    let transaction = root.appendingPathComponent(scope == "notebook" ? "exports" : "resources").appendingPathComponent(id)
    let request = try ShareInbox.json(transaction.appendingPathComponent("request.json"))
    let ready = try ShareInbox.json(transaction.appendingPathComponent("ready.json"))
    let bytes = try integer(ready["bytes"])
    guard ready["id"] as? String == id, let digest = ready["sha256"] as? String,
          ShareInbox.validHex(digest, count: 64), bytes == (try ShareInbox.metadata(source)).st_size
    else { throw ShareInboxError.corrupt }
    if scope == "notebook" {
      let version = try integer(request["version"])
      let common: Set<String> = ["version", "id", "notebookId", "notebookName", "archive"]
      let format: Set<String> = version == 2 ? ["format"] : []
      guard (version == 1 || version == 2), try integer(ready["version"]) == version,
            request["id"] as? String == id, request["snapshot"] as? String == "snapshot",
            request["archive"] as? String == "notebook.zip", ready["archive"] as? String == "notebook.zip",
            Set(request.keys) == common.union(format).union(["snapshot"]),
            Set(ready.keys) == common.union(format).union(["bytes", "sha256", "sourceBytes", "files", "directories", "archiveLimit"]),
            let notebook = request["notebookId"] as? String, !notebook.isEmpty, notebook.utf8.count <= 127,
            ready["notebookId"] as? String == notebook,
            let notebookName = request["notebookName"] as? String, !notebookName.isEmpty, notebookName.utf8.count <= 16384,
            ready["notebookName"] as? String == notebookName, bytes >= 22,
            bytes <= (try integer(ready["archiveLimit"])), bytes <= 3 * 1024 * 1024 * 1024
      else { throw ShareInboxError.corrupt }
      if version == 2 {
        guard let kind = request["format"] as? String, ["notebook", "filesAndAssets"].contains(kind),
              ready["format"] as? String == kind else { throw ShareInboxError.corrupt }
      }
      _ = try integer(ready["sourceBytes"]); _ = try integer(ready["files"]); _ = try integer(ready["directories"])
    }
    // Both calls execute while Dart's library transfer reservation is held.
    // No core/import work can race the positive quota check and snapshot copy.
    let check: ExportCheck = unsafeBitCast(try Self.symbol("vxm_share_export_check"), to: ExportCheck.self)
    func admission(_ required: Int64) throws {
      guard required > 0 else { throw ShareInboxError.invalid }
      guard root.path.withCString({ check($0, UInt64(required)) }) == 0 else { throw ShareInboxError.capacity }
    }
    if try !ShareInbox.exists(root.appendingPathComponent("outgoing-shares/ledger.json")) {
      try admission(ShareInbox.metadataAllowance)
    }
    let outgoing = try ShareInbox.outgoing(support: root)
    return try outgoing.snapshot(source: source, name: name, bytes: bytes, sha256: digest, admission: admission)
  }
  private func presenter() -> (UIViewController, UIWindowScene)? {
    for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
      guard scene.activationState == .foregroundActive,
            let window = scene.windows.first(where: { $0.isKeyWindow }),
            var controller = window.rootViewController else { continue }
      while let presented = controller.presentedViewController { controller = presented }
      guard controller.viewIfLoaded?.window === window, !controller.isBeingDismissed,
            !controller.isBeingPresented, !(controller is UIAlertController) else { continue }
      return (controller, scene)
    }
    return nil
  }
  private var preparingShare = false
  private func share(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard active == nil, !preparingShare, let (_, scene) = presenter() else { result(["status": "unavailable"]); return }
    preparingShare = true
    worker.async {
      do {
        let snapshot: ShareInbox.Snapshot
        if call.method == "export" {
          let args = try self.arguments(call, keys: ["id"])
          snapshot = try ShareInbox.configured().snapshot(id: self.identifier(args, "id"))
        } else {
          snapshot = try self.exportSnapshot(self.arguments(call, keys: ["operationId", "scope", "path", "suggestedName"]))
        }
        DispatchQueue.main.async { self.preparingShare = false; self.present(snapshot, originatingScene: scene, result: result) }
      } catch {
        let status: String
        switch error {
        case ShareInboxError.unavailable, ShareInboxError.inactive: status = "unavailable"
        default: status = "failed"
        }
        DispatchQueue.main.async { self.preparingShare = false; if self.attached { result(["status": status]) } }
      }
    }
  }
  private func present(_ snapshot: ShareInbox.Snapshot, originatingScene: UIWindowScene, result: @escaping FlutterResult) {
    guard attached, active == nil, let (presenter, scene) = presenter(), scene === originatingScene else {
      if attached { result(["status": "unavailable"]) }; return
    }
    var descriptors: [Int32] = []
    for url in snapshot.urls {
      let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      guard fd >= 0 else { descriptors.forEach { Darwin.close($0) }; result(["status": "failed"]); return }
      descriptors.append(fd)
    }
    let controller = UIActivityViewController(activityItems: snapshot.urls, applicationActivities: nil)
    let operation = Presentation(controller: controller, scene: scene, result: result, descriptors: descriptors, snapshot: snapshot)
    active = operation; leaseOwner = self
    controller.completionWithItemsHandler = { [weak self, weak operation] _, completed, _, error in
      guard let self = self, let operation = operation else { return }
      self.stop(operation, status: error == nil ? (completed ? "shared" : "cancelled") : "failed")
    }
    if let popover = controller.popoverPresentationController {
      popover.sourceView = presenter.view
      popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
      popover.permittedArrowDirections = []
    }
    presenter.present(controller, animated: false) {
      operation.presenting = false; controller.presentationController?.delegate = self
      if let status = operation.stopping { self.stop(operation, status: status) }
    }
    controller.presentationController?.delegate = self
    if controller.presentingViewController == nil && !controller.isBeingPresented {
      operation.presenting = false; stop(operation, status: "failed")
    }
  }
  private func stop(_ operation: Presentation, status: String) {
    guard active === operation else { return }
    if operation.stopping == nil { operation.stopping = status }
    guard !operation.presenting, !operation.dismissing else { return }
    operation.dismissing = true
    let finish = {
      guard self.active === operation else { return }
      let result = operation.result; operation.result = nil
      operation.controller.completionWithItemsHandler = nil
      operation.controller.presentationController?.delegate = nil
      self.active = nil; self.leaseOwner = nil
      // File URLs and complete copied bytes remain durable after this callback,
      // Flutter detach, and scene disconnect. Shared is not recipient persistence.
      if self.attached { result?(["status": operation.stopping ?? "cancelled"]) }
    }
    if operation.controller.presentingViewController != nil { operation.controller.dismiss(animated: false, completion: finish) }
    else { finish() }
  }
  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    if let operation = active, presentationController.presentedViewController === operation.controller {
      stop(operation, status: "cancelled")
    }
  }
  func sceneDidDisconnect(_ scene: UIScene) {
    if let operation = active, operation.scene === scene { stop(operation, status: "cancelled") }
  }
  func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    attached = false; channel?.setMethodCallHandler(nil); channel = nil
    if let operation = active { stop(operation, status: "unavailable") }
  }
}
