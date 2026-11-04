import Foundation
import CryptoKit
import Darwin

// SDK-only: this file is compiled into both processes. Neither capture nor the
// extension opens the host library, a notebook, or any provider URL after capture.
enum ShareInboxError: Error {
  case unavailable, inactive, invalid, corrupt, capacity, busy, missingPayload, proofRequired
}

final class ShareInbox {
  static let maximumFile: Int64 = 64 * 1024 * 1024
  static let maximumDelivery: Int64 = 256 * 1024 * 1024
  static let maximumText = 1024 * 1024
  static let maximumInbox: Int64 = 1024 * 1024 * 1024
  static let headroom: Int64 = 64 * 1024 * 1024
  // Includes the text, manifests and a worst-case atomic ledger replacement.
  static let reservation: Int64 = maximumDelivery + 2 * 1024 * 1024
  static let metadataAllowance: Int64 = 16 * 1024 * 1024
  let root: URL
  private let outgoingOnly: Bool
  private var budget: Int64 { outgoingOnly ? 3 * 1024 * 1024 * 1024 : Self.maximumInbox }
  private let manager = FileManager.default

  struct Attachment: Codable {
    var name: String
    var mime: String
    var bytes: Int64
    var sha256: String
    var wire: [String: Any] { ["name": name, "mime": mime, "bytes": bytes, "sha256": sha256] }
  }
  struct Target: Codable, Equatable {
    var notebookId: String
    var parentId: String
    var notebookRelative: String
    var folderName: String
    var wire: [String: Any] {
      ["notebookId": notebookId, "parentId": parentId,
       "notebookRelative": notebookRelative, "folderName": folderName]
    }
  }
  struct Record: Codable {
    var id: String
    var fingerprint: String
    var state: String
    var bytes: Int64
    var files: [Attachment]
    var textBytes: Int
    var payload: String?
    var candidate: String?
    var operationId: String?
    var target: Target?
    var cohortId: String?
    var wire: [String: Any] {
      var value: [String: Any] = ["id": id, "fingerprint": fingerprint, "state": state,
        "bytes": bytes, "files": files.map { $0.wire }, "payloadAvailable": payload != nil,
        "duplicateAvailable": candidate != nil]
      if let operationId = operationId { value["operationId"] = operationId }
      if let target = target { value["target"] = target.wire }
      if let cohortId = cohortId { value["cohortId"] = cohortId }
      return value
    }
  }
  struct Receiving: Codable { var id: String; var started: TimeInterval }
  struct Reader: Codable { var id: String; var bytes: Int64; var names: [String] }
  struct Ledger: Codable {
    var version = 1
    var records: [Record] = []
    var receiving: [Receiving] = []
    var readers: [Reader] = []
    var reclaim: [String] = []
  }
  struct Manifest: Codable { var version = 1; var textBytes: Int; var files: [Attachment] }

  static var configuredGroup: String? {
    guard let group = Bundle.main.object(forInfoDictionaryKey: "VNoteAppGroup") as? String,
          group.hasPrefix("group."), group.utf8.count <= 255,
          !group.contains("$("), group.unicodeScalars.allSatisfy({
            CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-"
          }) else { return nil }
    return group
  }
  static func configured() throws -> ShareInbox {
    guard let group = configuredGroup,
          let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    else { throw ShareInboxError.unavailable }
    let anchor = container.resolvingSymlinksInPath().standardizedFileURL
    try requireDirectory(anchor)
    return try ShareInbox(root: anchor.appendingPathComponent("inbox", isDirectory: true))
  }
  // Main-app outgoing snapshots are NOT an incoming inbox fallback. Their bytes
  // are scanned by the native 3GiB core ledger; callers prove admission first.
  static func outgoing(support: URL) throws -> ShareInbox {
    try requireDirectory(support)
    return try ShareInbox(root: support.appendingPathComponent("outgoing-shares"), outgoingOnly: true)
  }
  private init(root: URL, outgoingOnly: Bool = false) throws {
    self.root = root; self.outgoingOnly = outgoingOnly
    try Self.prepareDirectory(root)
    for name in ["payloads", "readers"] {
      try Self.prepareDirectory(root.appendingPathComponent(name, isDirectory: true))
    }
    try locked { ledger in
      try self.reclaimPayloads(&ledger)
      if try !Self.exists(root.appendingPathComponent("ledger.json")) { try self.save(ledger) }
      try self.reapUnacknowledged(&ledger)
      try self.checkBudget(ledger, extra: 0)
    }
  }

  static func id() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
  static func validHex(_ value: String, count: Int) -> Bool {
    value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
  static func validateName(_ name: String) throws {
    let base = String(name.prefix(while: { $0 != "." })).uppercased()
    let device = (base.hasPrefix("COM") || base.hasPrefix("LPT")) && base.count == 4 &&
      "123456789¹²³".contains(base.last!)
    guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
          !name.hasSuffix("."), !name.hasSuffix(" "),
          !["CON", "PRN", "AUX", "NUL"].contains(base), !device,
          !name.unicodeScalars.contains(where: {
            $0.value < 32 || (127...159).contains($0.value) || "/\\:*?\"<>|".unicodeScalars.contains($0)
          }) else { throw ShareInboxError.invalid }
  }
  static func collisionKey(_ name: String) -> String {
    name.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
  }
  static func validateTarget(_ value: [String: Any]) throws -> Target {
    guard value.count == 4, let notebook = value["notebookId"] as? String,
          let parent = value["parentId"] as? String,
          let relative = value["notebookRelative"] as? String,
          let folder = value["folderName"] as? String,
          !notebook.isEmpty, notebook.utf8.count <= 128,
          !parent.isEmpty, parent.utf8.count <= 128,
          !relative.isEmpty, relative.utf8.count <= 1024, !relative.hasPrefix("/")
    else { throw ShareInboxError.invalid }
    try validateName(folder)
    for part in relative.split(separator: "/", omittingEmptySubsequences: false) { try validateName(String(part)) }
    return Target(notebookId: notebook, parentId: parent, notebookRelative: relative, folderName: folder)
  }

  static func metadata(_ url: URL) throws -> stat {
    var value = stat()
    guard url.withUnsafeFileSystemRepresentation({ $0.map { Darwin.lstat($0, &value) } ?? -1 }) == 0
    else { throw ShareInboxError.corrupt }
    return value
  }
  static func exists(_ url: URL) throws -> Bool {
    var value = stat()
    let result = url.withUnsafeFileSystemRepresentation { $0.map { Darwin.lstat($0, &value) } ?? -1 }
    if result == 0 { return true }
    guard errno == ENOENT else { throw ShareInboxError.corrupt }
    return false
  }
  static func requireDirectory(_ url: URL) throws {
    let value = try metadata(url)
    guard value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), value.st_uid == geteuid(),
          url.resolvingSymlinksInPath().standardizedFileURL.path == url.path
    else { throw ShareInboxError.corrupt }
  }
  static func protect(_ url: URL) throws {
    let before = try metadata(url)
    let directory = before.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    guard directory || (before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) && before.st_nlink == 1),
          before.st_uid == geteuid() else { throw ShareInboxError.corrupt }
    try FileManager.default.setAttributes([.posixPermissions: directory ? 0o700 : 0o600,
      .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
    var marked = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try marked.setResourceValues(values)
    marked.removeAllCachedResourceValues()
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard try marked.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true,
          attributes[.protectionKey] as? FileProtectionType == .completeUntilFirstUserAuthentication
    else { throw ShareInboxError.unavailable }
  }
  static func prepareDirectory(_ url: URL) throws {
    if try !exists(url) {
      do {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
      } catch {
        // Another entitled process can win mkdir before either takes ledger.lock.
        guard try exists(url) else { throw error }
      }
      try syncDirectory(url.deletingLastPathComponent())
    }
    try requireDirectory(url)
    try protect(url)
  }
  static func syncDirectory(_ url: URL) throws {
    let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw ShareInboxError.corrupt }
    defer { Darwin.close(fd) }
    guard Darwin.fsync(fd) == 0 else { throw ShareInboxError.unavailable }
  }
  static func writeAll(_ fd: Int32, _ data: UnsafeRawBufferPointer) throws {
    var offset = 0
    while offset < data.count {
      let count = Darwin.write(fd, data.baseAddress!.advanced(by: offset), data.count - offset)
      if count < 0 && errno == EINTR { continue }
      guard count > 0 else { throw ShareInboxError.unavailable }
      offset += count
    }
  }
  static func atomic(_ data: Data, to url: URL) throws {
    try requireDirectory(url.deletingLastPathComponent())
    let temp = url.deletingLastPathComponent().appendingPathComponent(".write-" + id())
    let fd = Darwin.open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw ShareInboxError.unavailable }
    defer { Darwin.close(fd); try? FileManager.default.removeItem(at: temp) }
    try protect(temp)
    try data.withUnsafeBytes { try writeAll(fd, $0) }
    guard Darwin.fsync(fd) == 0, Darwin.rename(temp.path, url.path) == 0 else { throw ShareInboxError.unavailable }
    try syncDirectory(url.deletingLastPathComponent())
  }
  static func readData(_ url: URL, maximum: Int64) throws -> Data {
    let before = try metadata(url)
    guard before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), before.st_nlink == 1,
          before.st_size >= 0, before.st_size <= maximum else { throw ShareInboxError.corrupt }
    let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw ShareInboxError.corrupt }
    defer { Darwin.close(fd) }
    var opened = stat()
    guard Darwin.fstat(fd, &opened) == 0, opened.st_ino == before.st_ino, opened.st_dev == before.st_dev
    else { throw ShareInboxError.corrupt }
    var data = Data(count: Int(before.st_size))
    try data.withUnsafeMutableBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw ShareInboxError.corrupt }
        offset += count
      }
    }
    var extra: UInt8 = 0
    guard Darwin.read(fd, &extra, 1) == 0 else { throw ShareInboxError.corrupt }
    let after = try metadata(url)
    guard after.st_ino == before.st_ino, after.st_dev == before.st_dev,
          after.st_size == before.st_size, after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
          after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else { throw ShareInboxError.corrupt }
    return data
  }
  static func json(_ url: URL) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: readData(url, maximum: metadataAllowance)) as? [String: Any]
    else { throw ShareInboxError.corrupt }
    return value
  }
  static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }

  // The host activation/proof caller holds this lock through its native call.
  // Separate open descriptors serialize threads as well as entitled processes.
  func locked<T>(_ body: (inout Ledger) throws -> T) throws -> T {
    let fd = Darwin.open(root.appendingPathComponent("ledger.lock").path,
      O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw ShareInboxError.unavailable }
    defer { Darwin.close(fd) }
    guard Darwin.flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      if errno == EWOULDBLOCK || errno == EAGAIN { throw ShareInboxError.busy }
      throw ShareInboxError.unavailable
    }
    defer { Darwin.flock(fd, LOCK_UN) }
    try Self.protect(root.appendingPathComponent("ledger.lock"))
    let path = root.appendingPathComponent("ledger.json")
    // Root atomic temporaries belong only to operations holding this lock.
    // Never touch payload temporaries here: their separate writer lease owns them.
    for child in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
      let name = child.lastPathComponent
      if name.hasPrefix(".write-"), Self.validHex(String(name.dropFirst(7)), count: 32) {
        let value = try Self.metadata(child)
        guard value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), value.st_nlink == 1,
              value.st_size >= 0, value.st_size <= Self.metadataAllowance else { throw ShareInboxError.corrupt }
        if Date().timeIntervalSince1970 - Double(value.st_mtimespec.tv_sec) > 24 * 60 * 60 {
          try manager.removeItem(at: child)
        }
      }
    }
    var ledger: Ledger
    if try Self.exists(path) {
      ledger = try JSONDecoder().decode(Ledger.self, from: Self.readData(path, maximum: Self.metadataAllowance / 2))
    } else {
      // Only a genuinely empty bootstrap may acquire a new ledger. Missing
      // history beside activation/payload/reader evidence is corruption, not an
      // invitation to forget deduplication and replay an acknowledged delivery.
      let allowed: Set<String> = ["payloads", "readers", "ledger.lock"]
      for child in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
        guard allowed.contains(child.lastPathComponent) else { throw ShareInboxError.corrupt }
      }
      for name in ["payloads", "readers"] {
        guard try manager.contentsOfDirectory(at: root.appendingPathComponent(name), includingPropertiesForKeys: nil).isEmpty
        else { throw ShareInboxError.corrupt }
      }
      ledger = Ledger()
    }
    try validate(ledger)
    return try body(&ledger)
  }
  private func validate(_ ledger: Ledger) throws {
    guard ledger.version == 1, ledger.records.count <= 10000, ledger.receiving.count <= 2,
          ledger.readers.count <= 200 else { throw ShareInboxError.corrupt }
    guard ledger.records.filter({ ["ready", "importing", "failed"].contains($0.state) || $0.candidate != nil }).count
      + ledger.receiving.count <= 200 else { throw ShareInboxError.corrupt }
    var ids = Set<String>(); var payloads = Set<String>(); var operations = Set<String>()
    for record in ledger.records {
      guard Self.validHex(record.id, count: 32), ids.insert(record.id).inserted,
            Self.validHex(record.fingerprint, count: 64),
            ["ready", "importing", "consumed", "discarded", "failed"].contains(record.state),
            record.bytes >= 0, record.bytes <= Self.maximumDelivery,
            record.textBytes >= 0, record.textBytes <= Self.maximumText, record.files.count <= 64
      else { throw ShareInboxError.corrupt }
      var names = Set<String>(); var sum = Int64(record.textBytes)
      if record.textBytes > 0 { names.insert(Self.collisionKey("Shared text.md")) }
      for file in record.files {
        try Self.validateName(file.name)
        guard names.insert(Self.collisionKey(file.name)).inserted,
              file.bytes >= 0, file.bytes <= Self.maximumFile,
              Self.validHex(file.sha256, count: 64), !file.mime.isEmpty, file.mime.utf8.count <= 255,
              !file.mime.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
        else { throw ShareInboxError.corrupt }
        sum += file.bytes
      }
      guard sum == record.bytes else { throw ShareInboxError.corrupt }
      for payload in [record.payload, record.candidate].compactMap({ $0 }) {
        guard Self.validHex(payload, count: 32), payloads.insert(payload).inserted else { throw ShareInboxError.corrupt }
      }
      if let operation = record.operationId {
        guard Self.validHex(operation, count: 32), operations.insert(operation).inserted,
              let target = record.target else { throw ShareInboxError.corrupt }
        _ = try Self.validateTarget(target.wire)
      } else if record.target != nil || record.state == "importing" { throw ShareInboxError.corrupt }
      if ["ready", "importing", "failed"].contains(record.state), record.payload == nil { throw ShareInboxError.corrupt }
    }
    for receive in ledger.receiving {
      guard Self.validHex(receive.id, count: 32), payloads.insert(receive.id).inserted,
            receive.started.isFinite, receive.started > 0 else { throw ShareInboxError.corrupt }
    }
    for payload in ledger.reclaim {
      guard Self.validHex(payload, count: 32), payloads.insert(payload).inserted else { throw ShareInboxError.corrupt }
    }
    var readers = Set<String>()
    for reader in ledger.readers {
      guard Self.validHex(reader.id, count: 32), readers.insert(reader.id).inserted,
            reader.bytes >= 0, reader.bytes <= budget, reader.names.count <= 65
      else { throw ShareInboxError.corrupt }
      var names = Set<String>()
      for name in reader.names {
        try Self.validateName(name)
        guard names.insert(Self.collisionKey(name)).inserted else { throw ShareInboxError.corrupt }
      }
    }
  }
  private func save(_ ledger: Ledger) throws {
    try validate(ledger)
    let bytes = try Self.encode(ledger)
    guard bytes.count <= Self.metadataAllowance / 2 else { throw ShareInboxError.capacity }
    try checkBudget(ledger, extra: 0)
    try Self.atomic(bytes, to: root.appendingPathComponent("ledger.json"))
  }
  private func treeBytes(_ url: URL, excluding: Set<String> = []) throws -> Int64 {
    if excluding.contains(url.path) { return 0 }
    let value = try Self.metadata(url)
    if value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) {
      guard value.st_nlink == 1, value.st_size >= 0 else { throw ShareInboxError.corrupt }
      return value.st_size
    }
    try Self.requireDirectory(url)
    var sum: Int64 = 0
    for child in try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
      sum += try treeBytes(child, excluding: excluding)
      guard sum <= budget else { throw ShareInboxError.capacity }
    }
    return sum
  }
  private func checkBudget(_ ledger: Ledger, extra: Int64) throws {
    // Receiving writers run outside ledger.lock. Charge their entire fixed
    // reservations, never subtract two racing measurements of a growing file.
    let activePaths = Set(ledger.receiving.map { payloadURL($0.id).path })
    var used = try treeBytes(root, excluding: activePaths)
    used += Int64(ledger.receiving.count) * Self.reservation
    for reader in ledger.readers {
      let url = root.appendingPathComponent("readers").appendingPathComponent(reader.id)
      let actual = try Self.exists(url) ? treeBytes(url) : 0
      used += max(reader.bytes + 128 * 1024 - actual, 0)
    }
    guard used + extra + Self.metadataAllowance <= budget else { throw ShareInboxError.capacity }
    guard extra > 0 else { return }
    var filesystem = statfs()
    guard Darwin.statfs(root.path, &filesystem) == 0, filesystem.f_bsize > 0,
          filesystem.f_bavail >= UInt64((max(extra, 0) + Self.headroom + Int64(filesystem.f_bsize) - 1) / Int64(filesystem.f_bsize))
    else { throw ShareInboxError.capacity }
  }
  private func payloadURL(_ id: String) -> URL { root.appendingPathComponent("payloads").appendingPathComponent(id) }
  private func reclaimPayloads(_ ledger: inout Ledger) throws {
    guard !ledger.reclaim.isEmpty else { return }
    for id in ledger.reclaim {
      let folder = payloadURL(id)
      if try Self.exists(folder) { try Self.requireDirectory(folder); try manager.removeItem(at: folder) }
    }
    try Self.syncDirectory(root.appendingPathComponent("payloads"))
    ledger.reclaim.removeAll(); try save(ledger)
  }
  private func reapUnacknowledged(_ ledger: inout Ledger) throws {
    var changed = false
    for receive in ledger.receiving {
      guard Date().timeIntervalSince1970 - receive.started > 24 * 60 * 60 else { continue }
      let folder = payloadURL(receive.id)
      if try !Self.exists(folder) {
        ledger.receiving.removeAll { $0.id == receive.id }; changed = true; continue
      }
      try Self.requireDirectory(folder)
      let lock = folder.appendingPathComponent("writer.lock")
      if try !Self.exists(lock) {
        guard try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).isEmpty
        else { throw ShareInboxError.corrupt }
      }
      let lease = Darwin.open(folder.appendingPathComponent("writer.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard lease >= 0 else { throw ShareInboxError.corrupt }
      defer { Darwin.flock(lease, LOCK_UN); Darwin.close(lease) }
      if Darwin.flock(lease, LOCK_EX | LOCK_NB) == 0 {
        // Only a never-acknowledged receiving entry is eligible, never a record.
        try manager.removeItem(at: folder)
        try Self.syncDirectory(folder.deletingLastPathComponent())
        ledger.receiving.removeAll { $0.id == receive.id }; changed = true
      }
    }
    if changed { try save(ledger) }
  }

  final class Capture {
    let id: String
    let folder: URL
    let lease: Int32
    var files: [Attachment] = []
    var text = Data()
    var total: Int64 = 0
    var names = Set<String>()
    var ended = false
    fileprivate init(id: String, folder: URL, lease: Int32) { self.id = id; self.folder = folder; self.lease = lease }
    deinit { Darwin.flock(lease, LOCK_UN); Darwin.close(lease) }
  }
  func beginCapture() throws -> Capture {
    guard !outgoingOnly else { throw ShareInboxError.unavailable }
    return try locked { ledger in
      guard try Self.exists(root.appendingPathComponent("activation.json")) else { throw ShareInboxError.inactive }
      let activation = try Self.json(root.appendingPathComponent("activation.json"))
      guard NSDictionary(dictionary: activation).isEqual(to: ["version": 1,
        "coreStagingBytes": Int64(3 * 1024 * 1024 * 1024), "inboxBytes": Self.maximumInbox])
      else { throw ShareInboxError.corrupt }
      try reapUnacknowledged(&ledger)
      guard ledger.receiving.count < 2 else { throw ShareInboxError.busy }
      let pending = ledger.records.filter { ["ready", "importing", "failed"].contains($0.state) || $0.candidate != nil }.count
      guard pending + ledger.receiving.count < 200, ledger.records.count < 10000 else { throw ShareInboxError.capacity }
      try checkBudget(ledger, extra: Self.reservation)
      let id = Self.id(); let folder = payloadURL(id)
      ledger.receiving.append(Receiving(id: id, started: Date().timeIntervalSince1970))
      try save(ledger) // ownership and reservation precede mkdir and provider I/O
      try Self.prepareDirectory(folder)
      let fd = Darwin.open(folder.appendingPathComponent("writer.lock").path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard fd >= 0 else { throw ShareInboxError.unavailable }
      guard Darwin.flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); throw ShareInboxError.busy }
      return Capture(id: id, folder: folder, lease: fd)
    }
  }
  func appendText(_ value: String, to capture: Capture) throws {
    guard !capture.ended else { throw ShareInboxError.invalid }
    guard value.utf8.count <= Self.maximumText else { throw ShareInboxError.capacity }
    let data = Data(value.utf8)
    if data.isEmpty { return }
    let separator = capture.text.isEmpty || data.isEmpty ? 0 : 1
    guard capture.text.count + data.count + separator <= Self.maximumText,
          capture.total + Int64(data.count + separator) <= Self.maximumDelivery,
          !capture.names.contains(Self.collisionKey("Shared text.md")) else { throw ShareInboxError.capacity }
    if separator != 0 { capture.text.append(10) }
    capture.text.append(data); capture.total += Int64(data.count + separator)
  }
  func appendFile(_ source: URL, name: String, mime: String, to capture: Capture) throws {
    guard !capture.ended, capture.files.count < 64 else { throw ShareInboxError.capacity }
    try Self.validateName(name)
    guard !mime.isEmpty, mime.utf8.count <= 255,
          !mime.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
          capture.names.insert(Self.collisionKey(name)).inserted,
          capture.text.isEmpty || Self.collisionKey(name) != Self.collisionKey("Shared text.md")
    else { throw ShareInboxError.invalid }
    // Provider URLs can be sandbox-local (scope returns false) or security-scoped.
    // In either case NSFileCoordinator and a no-follow descriptor gate the copy.
    let scoped = source.startAccessingSecurityScopedResource()
    defer { if scoped { source.stopAccessingSecurityScopedResource() } }
    let coordinator = NSFileCoordinator(filePresenter: nil)
    var coordination: NSError?; var failure: Error?; var result: (Int64, String)?
    coordinator.coordinate(readingItemAt: source, options: [], error: &coordination) { url in
      do {
        result = try Self.copyFile(url, to: capture.folder.appendingPathComponent("file-\(capture.files.count)"),
          maximum: min(Self.maximumFile, Self.maximumDelivery - capture.total))
      } catch { failure = error }
    }
    if let failure = failure { throw failure }
    guard coordination == nil, let copied = result else { throw ShareInboxError.unavailable }
    capture.files.append(Attachment(name: name, mime: mime, bytes: copied.0, sha256: copied.1))
    capture.total += copied.0
  }
  static func copyFile(_ source: URL, to destination: URL, maximum: Int64) throws -> (Int64, String) {
    let before = try metadata(source)
    guard source.isFileURL, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
          before.st_nlink == 1, before.st_size >= 0, before.st_size <= maximum
    else { throw ShareInboxError.invalid }
    let input = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard input >= 0 else { throw ShareInboxError.unavailable }
    defer { Darwin.close(input) }
    var opened = stat()
    guard Darwin.fstat(input, &opened) == 0, opened.st_ino == before.st_ino,
          opened.st_dev == before.st_dev else { throw ShareInboxError.corrupt }
    let output = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard output >= 0 else { throw ShareInboxError.unavailable }
    defer { Darwin.close(output) }
    try protect(destination)
    var hash = SHA256(); var copied: Int64 = 0
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    try buffer.withUnsafeMutableBytes { bytes in
      while true {
        let count = Darwin.read(input, bytes.baseAddress, bytes.count)
        if count < 0 && errno == EINTR { continue }
        guard count >= 0 else { throw ShareInboxError.unavailable }
        if count == 0 { break }
        copied += Int64(count)
        guard copied <= maximum, copied <= before.st_size else { throw ShareInboxError.capacity }
        let chunk = UnsafeRawBufferPointer(start: bytes.baseAddress, count: count)
        var space = statfs()
        guard Darwin.fstatfs(output, &space) == 0, space.f_bsize > 0,
              space.f_bavail >= UInt64((Int64(count) + headroom + Int64(space.f_bsize) - 1) / Int64(space.f_bsize))
        else { throw ShareInboxError.capacity }
        hash.update(bufferPointer: chunk); try writeAll(output, chunk)
      }
    }
    let after = try metadata(source)
    guard copied == before.st_size, before.st_ino == after.st_ino, before.st_dev == after.st_dev,
          before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
          before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
          Darwin.fsync(output) == 0 else { throw ShareInboxError.corrupt }
    return (copied, hash.finalize().map { String(format: "%02x", $0) }.joined())
  }
  private static func fingerprint(text: Data, files: [Attachment]) -> String {
    var hash = SHA256()
    func field(_ data: Data) {
      var size = UInt64(data.count).bigEndian
      withUnsafeBytes(of: &size) { hash.update(bufferPointer: $0) }
      hash.update(data: data)
    }
    field(Data("vnote-share-v1".utf8)); field(text); field(Data(String(files.count).utf8))
    for file in files {
      for value in [file.name, file.mime, String(file.bytes), file.sha256] { field(Data(value.utf8)) }
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
  func finishCapture(_ capture: Capture) throws -> Record {
    guard !capture.ended, !capture.files.isEmpty || !capture.text.isEmpty else { throw ShareInboxError.invalid }
    try Self.atomic(capture.text, to: capture.folder.appendingPathComponent("text.txt"))
    try Self.atomic(Self.encode(Manifest(textBytes: capture.text.count, files: capture.files)),
                    to: capture.folder.appendingPathComponent("manifest.json"))
    try Self.syncDirectory(capture.folder)
    let fingerprint = Self.fingerprint(text: capture.text, files: capture.files)
    return try locked { ledger in
      guard ledger.receiving.contains(where: { $0.id == capture.id }) else { throw ShareInboxError.corrupt }
      ledger.receiving.removeAll { $0.id == capture.id }
      var discardNew = false
      let result: Record
      if let index = ledger.records.firstIndex(where: { $0.fingerprint == fingerprint }) {
        if ledger.records[index].payload == nil && ledger.records[index].candidate == nil {
          ledger.records[index].candidate = capture.id
        } else {
          _ = try verifiedPayload(ledger.records[index], verifyFiles: true)
          discardNew = true
        }
        result = ledger.records[index]
      } else {
        let record = Record(id: capture.id, fingerprint: fingerprint, state: "ready", bytes: capture.total,
          files: capture.files, textBytes: capture.text.count, payload: capture.id)
        ledger.records.append(record); result = record
      }
      if discardNew { ledger.reclaim.append(capture.id) }
      try save(ledger) // durable receipt/candidate decision precedes acknowledgement
      capture.ended = true
      if discardNew { try reclaimPayloads(&ledger) }
      return result
    }
  }
  func abortCapture(_ capture: Capture) {
    guard !capture.ended else { return }
    try? locked { ledger in
      guard ledger.receiving.contains(where: { $0.id == capture.id }) else { return }
      // Delete before dropping the durable ownership record. Interrupted cleanup
      // stays charged and remains eligible for the inactive >24h rule.
      if try Self.exists(capture.folder) { try manager.removeItem(at: capture.folder) }
      try Self.syncDirectory(capture.folder.deletingLastPathComponent())
      ledger.receiving.removeAll { $0.id == capture.id }; try save(ledger); capture.ended = true
    }
  }

  func records() throws -> [[String: Any]] { try locked { $0.records.map { $0.wire } } }
  func claim(id: String, operation: String, target: Target) throws -> Record {
    guard Self.validHex(id, count: 32), Self.validHex(operation, count: 32) else { throw ShareInboxError.invalid }
    return try locked { ledger in
      guard let index = ledger.records.firstIndex(where: { $0.id == id }) else { throw ShareInboxError.invalid }
      let record = ledger.records[index]
      if record.state == "importing", record.operationId == operation, record.target == target { return record }
      guard record.state == "ready", !ledger.records.contains(where: { $0.operationId == operation }) else { throw ShareInboxError.invalid }
      ledger.records[index].state = "importing"; ledger.records[index].operationId = operation
      ledger.records[index].target = target; try save(ledger)
      return ledger.records[index]
    }
  }
  func withPayload<T>(id: String, _ body: (Record, URL, Data) throws -> T) throws -> T {
    try locked { ledger in
      guard let record = ledger.records.first(where: { $0.id == id }) else { throw ShareInboxError.invalid }
      let (folder, text) = try verifiedPayload(record)
      return try body(record, folder, text)
    }
  }
  private func verifiedPayload(_ record: Record, verifyFiles: Bool = false) throws -> (URL, Data) {
    guard let payload = record.payload ?? record.candidate else { throw ShareInboxError.missingPayload }
    let folder = payloadURL(payload); try Self.requireDirectory(folder)
    let manifest = try JSONDecoder().decode(Manifest.self,
      from: Self.readData(folder.appendingPathComponent("manifest.json"), maximum: 128 * 1024))
    guard manifest.version == 1, try Self.encode(manifest.files) == Self.encode(record.files),
          manifest.textBytes == record.textBytes else { throw ShareInboxError.corrupt }
    let text = try Self.readData(folder.appendingPathComponent("text.txt"), maximum: Int64(Self.maximumText))
    guard text.count == record.textBytes, String(data: text, encoding: .utf8) != nil,
          Self.fingerprint(text: text, files: record.files) == record.fingerprint else { throw ShareInboxError.corrupt }
    let allowed = Set(["writer.lock", "text.txt", "manifest.json"] + record.files.indices.map { "file-\($0)" })
    for child in try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
      guard allowed.contains(child.lastPathComponent) else { throw ShareInboxError.corrupt }
    }
    // Stage/export/anotherCopy verify every hash during their one streaming copy.
    // A duplicate-reuse acknowledgement has no copy and must hash here instead.
    if !verifyFiles { return (folder, text) }
    for (index, file) in record.files.enumerated() {
      let source = folder.appendingPathComponent("file-\(index)")
      let before = try Self.metadata(source)
      guard before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), before.st_nlink == 1, before.st_size == file.bytes
      else { throw ShareInboxError.corrupt }
      let fd = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      guard fd >= 0 else { throw ShareInboxError.corrupt }
      defer { Darwin.close(fd) }
      var opened = stat()
      guard Darwin.fstat(fd, &opened) == 0, opened.st_ino == before.st_ino, opened.st_dev == before.st_dev else { throw ShareInboxError.corrupt }
      var hash = SHA256(); var size: Int64 = 0
      var buffer = [UInt8](repeating: 0, count: 64 * 1024)
      try buffer.withUnsafeMutableBytes { bytes in
        while true {
          let count = Darwin.read(fd, bytes.baseAddress, bytes.count)
          if count < 0 && errno == EINTR { continue }
          guard count >= 0 else { throw ShareInboxError.corrupt }
          if count == 0 { break }
          size += Int64(count); guard size <= file.bytes else { throw ShareInboxError.corrupt }
          hash.update(bufferPointer: UnsafeRawBufferPointer(start: bytes.baseAddress, count: count))
        }
      }
      let after = try Self.metadata(source)
      guard size == file.bytes, after.st_ino == before.st_ino, after.st_dev == before.st_dev,
            after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
            after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
            hash.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256
      else { throw ShareInboxError.corrupt }
    }
    return (folder, text)
  }
  // The main plugin supplies a synchronous native proof while this ledger lock
  // is held. The library reservation remains held across proof + tombstone.
  func settle(id: String, operation: String?, cohort: String?, discard: Bool,
              proof: (Record) throws -> Void) throws {
    try locked { ledger in
      guard let index = ledger.records.firstIndex(where: { $0.id == id }) else { throw ShareInboxError.invalid }
      let record = ledger.records[index]
      if !discard, record.state == "consumed", record.operationId == operation, record.cohortId == cohort { return }
      if discard, record.state == "discarded" { return }
      if record.state == "importing" {
        if !discard { guard operation == record.operationId, cohort != nil else { throw ShareInboxError.invalid } }
        try proof(record)
      } else {
        guard discard, ["ready", "failed"].contains(record.state) else { throw ShareInboxError.invalid }
      }
      ledger.records[index].state = discard ? "discarded" : "consumed"
      ledger.records[index].cohortId = cohort
      ledger.records[index].payload = nil
      if let payload = record.payload { ledger.reclaim.append(payload) }
      try save(ledger) // never reclaim before the dedup tombstone is durable
      try reclaimPayloads(&ledger)
    }
  }
  func dismissDuplicate(id: String) throws {
    try locked { ledger in
      guard let index = ledger.records.firstIndex(where: { $0.id == id }) else { throw ShareInboxError.invalid }
      guard let candidate = ledger.records[index].candidate else { return }
      ledger.records[index].candidate = nil; ledger.reclaim.append(candidate); try save(ledger)
      try reclaimPayloads(&ledger)
    }
  }
  func forgetHistory() throws {
    try locked { ledger in
      ledger.records.removeAll { ["consumed", "discarded"].contains($0.state) && $0.payload == nil && $0.candidate == nil }
      try save(ledger)
    }
  }
  func anotherCopy(id: String) throws -> Record {
    // Capture's reservation protects the second physical copy; the new nonce is
    // committed directly, deliberately bypassing only fingerprint deduplication.
    let capture = try beginCapture()
    do {
      try withPayload(id: id) { record, folder, text in
        capture.text = text; capture.total = Int64(text.count)
        for (index, file) in record.files.enumerated() {
          let copied = try Self.copyFile(folder.appendingPathComponent("file-\(index)"),
            to: capture.folder.appendingPathComponent("file-\(index)"), maximum: Self.maximumFile)
          guard copied.0 == file.bytes, copied.1 == file.sha256 else { throw ShareInboxError.corrupt }
          capture.files.append(file); capture.total += file.bytes
        }
      }
      try Self.atomic(capture.text, to: capture.folder.appendingPathComponent("text.txt"))
      try Self.atomic(Self.encode(Manifest(textBytes: capture.text.count, files: capture.files)),
                      to: capture.folder.appendingPathComponent("manifest.json"))
      return try locked { ledger in
        guard ledger.receiving.contains(where: { $0.id == capture.id }) else { throw ShareInboxError.corrupt }
        let record = Record(id: capture.id, fingerprint: Self.fingerprint(text: capture.text, files: capture.files),
          state: "ready", bytes: capture.total, files: capture.files, textBytes: capture.text.count, payload: capture.id)
        ledger.receiving.removeAll { $0.id == capture.id }; ledger.records.append(record)
        try save(ledger); capture.ended = true; return record
      }
    } catch { abortCapture(capture); throw error }
  }

  // Outgoing URLs are immutable copies, not retained-core artifacts. No timeout
  // or engine/scene lifecycle event deletes them: a recipient may still read.
  // Explicit cleanup checks process reader leases and requires user confirmation.
  final class Snapshot {
    let urls: [URL]
    private let lease: Int32
    fileprivate init(urls: [URL], lease: Int32) { self.urls = urls; self.lease = lease }
    deinit { Darwin.flock(lease, LOCK_UN); Darwin.close(lease) }
  }
  func snapshot(id: String) throws -> Snapshot {
    let token = Self.id()
    return try withPayload(id: id) { record, folder, text in
      try makeReader(token: token, bytes: record.bytes,
        names: (text.isEmpty ? [] : ["Shared text.md"]) + record.files.map { $0.name }) { output in
        if !text.isEmpty { try Self.atomic(text, to: output.appendingPathComponent("Shared text.md")) }
        for (index, file) in record.files.enumerated() {
          let copied = try Self.copyFile(folder.appendingPathComponent("file-\(index)"),
            to: output.appendingPathComponent(file.name), maximum: Self.maximumFile)
          guard copied.0 == file.bytes, copied.1 == file.sha256 else { throw ShareInboxError.corrupt }
        }
      }
    }
  }
  private func makeReader(token: String, bytes: Int64, names: [String],
                          admission: ((Int64) throws -> Void)? = nil,
                          copy: (URL) throws -> Void) throws -> Snapshot {
    // Caller holds ledger.lock. Reload only to include the durable reservation.
    let path = root.appendingPathComponent("ledger.json")
    var ledger = try JSONDecoder().decode(Ledger.self, from: Self.readData(path, maximum: Self.metadataAllowance / 2))
    guard ledger.readers.count < 200 else { throw ShareInboxError.capacity }
    try checkBudget(ledger, extra: bytes + 128 * 1024)
    if outgoingOnly {
      guard let admission = admission else { throw ShareInboxError.proofRequired }
      try admission(bytes + 128 * 1024 + Self.metadataAllowance)
    }
    let output = root.appendingPathComponent("readers").appendingPathComponent(token)
    ledger.readers.append(Reader(id: token, bytes: bytes, names: names))
    try save(ledger)
    try Self.prepareDirectory(output)
    let lease = Darwin.open(output.appendingPathComponent("reader.lock").path,
      O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard lease >= 0 else { throw ShareInboxError.unavailable }
    do {
      guard Darwin.flock(lease, LOCK_EX | LOCK_NB) == 0 else { throw ShareInboxError.busy }
      let files = output.appendingPathComponent("files")
      try Self.prepareDirectory(files)
      try copy(files); try Self.syncDirectory(files); try Self.syncDirectory(output)
      return Snapshot(urls: names.map { files.appendingPathComponent($0) }, lease: lease)
    } catch { Darwin.close(lease); throw error }
  }
  func snapshot(source: URL, name: String, bytes: Int64, sha256: String?,
                admission: ((Int64) throws -> Void)? = nil) throws -> Snapshot {
    try Self.validateName(name)
    return try locked { _ in
      try makeReader(token: Self.id(), bytes: bytes, names: [name], admission: admission) { output in
        let copied = try Self.copyFile(source, to: output.appendingPathComponent(name), maximum: bytes)
        guard copied.0 == bytes, sha256 == nil || copied.1 == sha256 else { throw ShareInboxError.corrupt }
      }
    }
  }
  func cleanupExports() throws {
    try locked { ledger in
      // UIKit completion has no recipient-persistence guarantee. Keep readers
      // until an explicit user cleanup; never call this from chooser completion.
      var leases: [Int32] = []
      defer { for fd in leases { Darwin.flock(fd, LOCK_UN); Darwin.close(fd) } }
      for reader in ledger.readers {
        let folder = root.appendingPathComponent("readers").appendingPathComponent(reader.id)
        if try Self.exists(folder) {
          try Self.requireDirectory(folder)
          let lock = folder.appendingPathComponent("reader.lock")
          if try !Self.exists(lock) {
            guard try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).isEmpty
            else { throw ShareInboxError.corrupt }
          }
          let fd = Darwin.open(folder.appendingPathComponent("reader.lock").path,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
          guard fd >= 0 else { throw ShareInboxError.corrupt }
          guard Darwin.flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); throw ShareInboxError.busy }
          leases.append(fd)
        }
      }
      for reader in ledger.readers {
        let folder = root.appendingPathComponent("readers").appendingPathComponent(reader.id)
        if try Self.exists(folder) { try manager.removeItem(at: folder) }
      }
      try Self.syncDirectory(root.appendingPathComponent("readers"))
      ledger.readers.removeAll(); try save(ledger)
    }
  }
}
