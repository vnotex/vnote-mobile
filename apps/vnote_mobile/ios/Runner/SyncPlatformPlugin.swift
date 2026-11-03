import CryptoKit
import Flutter
import Foundation
import Security

/// App-private Keychain storage; this channel is never exposed to WebView content.
final class SyncPlatformPlugin: NSObject, FlutterPlugin {
  private static let worker = DispatchQueue(label: "vnote.sync-security", qos: .userInitiated)
  private var channel: FlutterMethodChannel?
  private var attached = true  // Main queue only.

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = SyncPlatformPlugin()
    let channel = FlutterMethodChannel(
      name: "vnote.mobile/sync_security", binaryMessenger: registrar.messenger())
    instance.channel = channel
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.publish(instance)
  }

  func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    attached = false
    channel?.setMethodCallHandler(nil)
    channel = nil
    // Do not discard serialized in-flight Keychain commits on engine detach.
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let methods = ["vaultList", "vaultRead", "vaultWrite", "vaultDelete", "trustStatus"]
    guard methods.contains(call.method) else {
      result(FlutterMethodNotImplemented)
      return
    }
    Self.worker.async {
      let reply: Any?
      do {
        guard let args = call.arguments as? [String: Any] else { throw VaultFailure.invalid }
        if call.method == "trustStatus" {
          try Vault.requireFields(args, [])
          // Same public Security capability used by sync_tls_apple.mm; no
          // reachability probe and no trust evaluation on Flutter's UI thread.
          if #available(iOS 12.0, *) {
            let policy = SecPolicyCreateSSL(true, nil)
            reply = ["available": CFGetTypeID(policy) == SecPolicyGetTypeID()]
          } else {
            reply = ["available": false]
          }
        } else {
          reply = try Vault().handle(call.method, args)
        }
      } catch let failure as VaultFailure {
        reply = FlutterError(code: failure.code,
          message: "Secure sync storage is not available for this request.",
          details: failure.revision.map { ["revision": $0] })
      } catch {
        reply = FlutterError(code: "vault_unavailable",
          message: "Secure sync storage is not available for this request.", details: nil)
      }
      DispatchQueue.main.async { if self.attached { result(reply) } }
    }
  }
}

private enum VaultFailure: Error {
  case locked, unavailable, corrupt(String?), changed, invalid, limit

  var code: String {
    switch self {
    case .locked: return "vault_locked"
    case .unavailable: return "vault_unavailable"
    case .corrupt: return "vault_corrupt"
    case .changed: return "vault_changed"
    case .invalid: return "vault_invalid"
    case .limit: return "vault_limit"
    }
  }

  var revision: String? {
    if case .corrupt(let revision) = self { return revision }
    return nil
  }
}

private struct Vault {
  private static let maximumRecords = 1000
  private static let maximumPlaintext = 64 * 1024
  private static let magic = Data([0x56, 0x4e, 0x53, 0x56, 0, 0, 0, 1])
  private static let randomBytes = 32
  private static let scopeBytes = 64
  private static let headerBytes = magic.count + randomBytes + scopeBytes
  private let service: String

  init() throws {
    guard let bundle = Bundle.main.bundleIdentifier, !bundle.isEmpty else {
      throw VaultFailure.unavailable
    }
    service = bundle + ".sync-vault.v1"
  }

  static func requireFields(_ args: [String: Any], _ fields: Set<String>) throws {
    guard Set(args.keys) == fields else { throw VaultFailure.invalid }
  }

  private static func validFingerprint(_ value: String) -> Bool {
    let bytes = value.utf8
    return bytes.count == 64 && bytes.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  private static func fingerprint(_ data: Data) -> String {
    let digits = Array("0123456789abcdef".utf8)
    var result = [UInt8]()
    result.reserveCapacity(64)
    for value in SHA256.hash(data: data) {
      result.append(digits[Int(value >> 4)])
      result.append(digits[Int(value & 15)])
    }
    return String(decoding: result, as: UTF8.self)
  }

  func handle(_ method: String, _ args: [String: Any]) throws -> Any? {
    let fields: Set<String>
    switch method {
    case "vaultList": fields = []
    case "vaultRead": fields = ["key"]
    case "vaultWrite": fields = ["key", "expectedRevision", "data"]
    case "vaultDelete": fields = ["key", "expectedRevision"]
    default: throw VaultFailure.invalid
    }
    try Self.requireFields(args, fields)
    if method == "vaultList" { return ["keys": try list()] }
    guard let key = args["key"] as? String, Self.validFingerprint(key) else {
      throw VaultFailure.invalid
    }
    var expected: String?
    if method == "vaultWrite" || method == "vaultDelete" {
      if let revision = args["expectedRevision"] as? String, Self.validFingerprint(revision) {
        expected = revision
      } else if method != "vaultWrite" || !(args["expectedRevision"] is NSNull) {
        throw VaultFailure.invalid
      }
    }
    let data: Data?
    if method == "vaultWrite" {
      guard let typed = args["data"] as? FlutterStandardTypedData, typed.type == .uint8 else {
        throw VaultFailure.invalid
      }
      guard typed.data.count <= Self.maximumPlaintext else { throw VaultFailure.limit }
      data = typed.data
    } else {
      data = nil
    }
    let current = try read(key)
    if method == "vaultRead" {
      guard let current else { return ["present": false] }
      let plaintext = try decode(current, key: key)
      return ["present": true, "revision": current.revision,
              "data": FlutterStandardTypedData(bytes: plaintext)]
    }
    if method == "vaultDelete" {
      guard let current else { return nil }
      guard current.revision == expected else { throw VaultFailure.changed }
      // A caller can explicitly authorize deletion of a corrupt envelope only
      // by the fingerprint obtained from that very generation, never by scope alone.
      let status = SecItemDelete(query(key) as CFDictionary)
      if status != errSecSuccess && status != errSecItemNotFound { throw failure(status) }
      return nil
    }
    guard current?.revision == expected else { throw VaultFailure.changed }
    if let current {
      _ = try decode(current, key: key)
    } else if try list().count >= Self.maximumRecords {
      throw VaultFailure.limit
    }
    guard let data else { throw VaultFailure.invalid }
    let envelope = try encode(data, key: key)
    let revision = Self.fingerprint(envelope)
    if current == nil {
      var attributes = query(key)
      attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      attributes[kSecValueData as String] = envelope
      let status = SecItemAdd(attributes as CFDictionary, nil)
      if status == errSecDuplicateItem { throw VaultFailure.changed }
      guard status == errSecSuccess else { throw failure(status) }
    } else {
      let attributes: [String: Any] = [
        kSecValueData as String: envelope,
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        kSecAttrSynchronizable as String: false,
      ]
      let status = SecItemUpdate(query(key) as CFDictionary, attributes as CFDictionary)
      if status == errSecItemNotFound { throw VaultFailure.changed }
      guard status == errSecSuccess else { throw failure(status) }
    }
    // SecItemAdd/Update synchronously commits the protected Keychain database;
    // there is no separate plaintext file or deferred application-side flush.
    return ["revision": revision]
  }

  private func query(_ key: String? = nil) -> [String: Any] {
    var value: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrSynchronizable as String: false,
      kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
    ]
    if let key { value[kSecAttrAccount as String] = key }
    // No access group, cloud synchronization, user prompt, or fallback store.
    return value
  }

  private func list() throws -> [String] {
    var request = query()
    request[kSecReturnAttributes as String] = true
    request[kSecMatchLimit as String] = NSNumber(value: Self.maximumRecords + 1)
    var value: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &value)
    if status == errSecItemNotFound { return [] }
    guard status == errSecSuccess else { throw failure(status) }
    guard let items = value as? [[String: Any]] else { throw VaultFailure.corrupt(nil) }
    guard items.count <= Self.maximumRecords else { throw VaultFailure.limit }
    var keys = [String]()
    keys.reserveCapacity(items.count)
    for attributes in items {
      guard let key = attributes[kSecAttrAccount as String] as? String,
            Self.validFingerprint(key), validProtection(attributes) else {
        throw VaultFailure.corrupt(nil)
      }
      keys.append(key)
    }
    guard Set(keys).count == keys.count else { throw VaultFailure.corrupt(nil) }
    return keys.sorted()
  }

  private struct Record {
    let bytes: Data
    let revision: String
    let protected: Bool
  }

  private func read(_ key: String) throws -> Record? {
    var request = query(key)
    request[kSecReturnAttributes as String] = true
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var value: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &value)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw failure(status) }
    guard let attributes = value as? [String: Any],
          let bytes = attributes[kSecValueData as String] as? Data else {
      throw VaultFailure.corrupt(nil)
    }
    guard bytes.count <= Self.maximumPlaintext + Self.headerBytes else {
      throw VaultFailure.corrupt(nil)
    }
    return Record(bytes: bytes, revision: Self.fingerprint(bytes), protected: validProtection(attributes))
  }

  private func validProtection(_ attributes: [String: Any]) -> Bool {
    guard let protection = attributes[kSecAttrAccessible as String] as? String,
          protection == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String) else { return false }
    // Nonsynchronizable queries exclude cloud items; missing false attributes
    // are permitted by SecItem's documented optional attribute result behavior.
    if let sync = attributes[kSecAttrSynchronizable as String] as? NSNumber, sync.boolValue { return false }
    return true
  }

  private func encode(_ data: Data, key: String) throws -> Data {
    var random = [UInt8](repeating: 0, count: Self.randomBytes)
    let status = random.withUnsafeMutableBytes {
      SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
    }
    guard status == errSecSuccess else { throw VaultFailure.unavailable }
    var envelope = Data()
    envelope.reserveCapacity(Self.headerBytes + data.count)
    envelope.append(Self.magic)
    envelope.append(contentsOf: random)
    envelope.append(contentsOf: key.utf8)
    envelope.append(data)
    return envelope
  }

  private func decode(_ record: Record, key: String) throws -> Data {
    let bytes = record.bytes
    guard record.protected, bytes.count >= Self.headerBytes,
          bytes.prefix(Self.magic.count) == Self.magic,
          bytes.subdata(in: (Self.magic.count + Self.randomBytes)..<Self.headerBytes) == Data(key.utf8) else {
      throw VaultFailure.corrupt(record.revision)
    }
    // Keychain authenticates encrypted data and its app-private service/account
    // metadata. The embedded identity additionally rejects a relocated record.
    return bytes.subdata(in: Self.headerBytes..<bytes.count)
  }

  private func failure(_ status: OSStatus) -> VaultFailure {
    switch status {
    case errSecInteractionNotAllowed, errSecAuthFailed: return .locked
    case errSecDecode: return .corrupt(nil)
    default: return .unavailable
    }
  }
}
