// SPDX-License-Identifier: LGPL-3.0-only
import CoreFoundation
import CryptoKit
import Darwin
import Flutter
import UIKit
import ImageIO
import WebKit
import webview_flutter_wkwebview

private enum SurfaceError: Error { case invalid, unavailable, output }

private enum SurfacePolicy {
  static let editorOrigin = "https://editor.vnote.invalid"
  static let renderOrigin = "vnote-render://render.vnote.invalid"
  static let previewOrigin = "vnote-preview://preview.vnote.invalid"
  static let sourceLimit = 4 * 1024 * 1024
  static let outputLimit = 16 * 1024 * 1024
  static let imageBudget = 64 * 1024 * 1024

  static func id(_ value: Any?) throws -> String {
    guard let value = value as? String, value.utf8.count == 32,
          value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { throw SurfaceError.invalid }
    return value
  }

  static func object(_ value: Any?, keys: Set<String>) throws -> [String: Any] {
    guard let value = value as? [String: Any], Set(value.keys) == keys
    else { throw SurfaceError.invalid }
    return value
  }

  static func integer(_ value: Any?, maximum: Int) throws -> Int {
    guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
          value.doubleValue.isFinite, value.doubleValue >= 0,
          value.doubleValue <= Double(maximum), value.doubleValue.rounded() == value.doubleValue
    else { throw SurfaceError.invalid }
    return value.intValue
  }

  static func preferences(_ value: Any?) throws -> [String: Any] {
    let value = try object(value, keys: ["dark", "highContrast", "fontScale", "reducedMotion"])
    for key in ["dark", "highContrast", "reducedMotion"] {
      guard let boolean = value[key] as? NSNumber, CFGetTypeID(boolean) == CFBooleanGetTypeID()
      else { throw SurfaceError.invalid }
    }
    guard let scale = value["fontScale"] as? NSNumber,
          CFGetTypeID(scale) != CFBooleanGetTypeID(), scale.doubleValue.isFinite,
          (0.75...3).contains(scale.doubleValue) else { throw SurfaceError.invalid }
    return value
  }

  static func json(_ value: Any, maximumBytes: Int = 8192) throws -> String {
    let bytes = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    guard bytes.count <= maximumBytes, let text = String(data: bytes, encoding: .utf8)
    else { throw SurfaceError.invalid }
    let encoded = text.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
      .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    guard encoded.utf8.count <= maximumBytes else { throw SurfaceError.invalid }
    return encoded
  }

  static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func csp(origin: String, nonce: String, editor: Bool) -> String {
    "default-src 'none'; base-uri 'none'; object-src 'none'; frame-src 'none'; "
      + "child-src 'none'; worker-src 'none'; connect-src 'none'; media-src 'none'; "
      + "form-action 'none'; script-src 'nonce-\(nonce)'; script-src-attr 'none'; "
      + "style-src \(editor ? "'nonce-\(nonce)'" : origin + " 'unsafe-inline'"); "
      + "style-src-elem 'nonce-\(nonce)'; style-src-attr \(editor ? "'none'" : "'unsafe-inline'"); "
      + "img-src \(editor ? "'none'" : origin); font-src \(editor ? "'none'" : origin)"
  }

  // URL-load/WebSocket rules are independent of page CSP, not a general socket
  // firewall. Public WK APIs do not establish native RTC/ICE denial.
  static func rules(origin: String?, completion: @escaping (WKContentRuleList?) -> Void) {
    var rules: [[String: Any]] = [["trigger": ["url-filter": ".*"], "action": ["type": "block"]]]
    if let origin = origin {
      let escaped = NSRegularExpression.escapedPattern(for: origin)
      rules.append(["trigger": ["url-filter": "^" + escaped + "/"],
                    "action": ["type": "ignore-previous-rules"]])
    }
    guard let json = try? SurfacePolicy.json(rules) else { completion(nil); return }
    let key = origin == renderOrigin ? "vnote-render-v1" : origin == previewOrigin ? "vnote-preview-v1" : "vnote-editor-v1"
    WKContentRuleListStore.default().compileContentRuleList(forIdentifier: key,
      encodedContentRuleList: json) { list, _ in
        DispatchQueue.main.async { completion(list) }
      }
  }
}

/// The manifest is build-owned; neither source text nor a request supplies asset paths.
private final class SurfaceAssets {
  private let registrar: FlutterPluginRegistrar
  private var manifests: [String: [String: String]] = [:]
  private let manifestLock = NSLock()
  init(_ registrar: FlutterPluginRegistrar) { self.registrar = registrar }

  private func bundled(_ path: String, limit: Int) throws -> Data {
    let key = registrar.lookupKey(forAsset: path)
    guard let url = Bundle.main.url(forResource: key, withExtension: nil),
          let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
          size >= 0, size <= limit else { throw SurfaceError.unavailable }
    let bytes = try Data(contentsOf: url)
    guard bytes.count == size else { throw SurfaceError.unavailable }
    return bytes
  }

  private func manifest(_ group: String) throws -> [String: String] {
    manifestLock.lock(); defer { manifestLock.unlock() }
    if let manifest = manifests[group] { return manifest }
    let data = try bundled("assets/\(group)/manifest.json", limit: 1024 * 1024)
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          try SurfacePolicy.integer(json["version"], maximum: 2) == 2,
          let outputs = json["outputs"] as? [String: String], outputs.count <= 256
    else { throw SurfaceError.unavailable }
    let prefix = "apps/vnote_mobile/assets/\(group)/"
    var manifest: [String: String] = [:]
    for (path, hash) in outputs where path.hasPrefix(prefix) {
      let name = String(path.dropFirst(prefix.count))
      guard !name.isEmpty, !name.contains(".."), !name.contains("\\"),
            !name.hasPrefix("/"), hash.utf8.count == 64,
            hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
      else { throw SurfaceError.unavailable }
      manifest[name] = hash
    }
    if group == "preview" {
      guard let fonts = json["fonts"] as? [[String: Any]], fonts.count <= 128 else { throw SurfaceError.unavailable }
      for font in fonts {
        guard let path = font["path"] as? String, path.hasPrefix("fonts/"), path.hasSuffix(".woff2"),
              font["mime"] as? String == "font/woff2", let hash = font["sha256"] as? String,
              manifest[path] == hash else { throw SurfaceError.unavailable }
        _ = try SurfacePolicy.integer(font["bytes"], maximum: SurfacePolicy.outputLimit)
      }
    }
    manifests[group] = manifest
    return manifest
  }

  func asset(group: String, name: String) throws -> Data {
    guard let expected = try manifest(group)[name] else { throw SurfaceError.unavailable }
    let data = try bundled("assets/\(group)/\(name)", limit: SurfacePolicy.outputLimit)
    guard SurfacePolicy.digest(data) == expected else { throw SurfaceError.unavailable }
    return data
  }

  func shell(kind: String, nonce: String, renderId: String? = nil) throws -> Data {
    let editor = kind == "editor"
    let group = editor ? "editor" : "preview"
    let html = editor ? "index.html" : "\(kind).html"
    let origin = editor ? SurfacePolicy.editorOrigin : kind == "render" ? SurfacePolicy.renderOrigin : SurfacePolicy.previewOrigin
    guard var shell = String(data: try asset(group: group, name: html), encoding: .utf8),
          let script = String(data: try asset(group: group, name: "\(kind).js"), encoding: .utf8),
          let style = String(data: try asset(group: group, name: editor ? "editor.css" : "preview.css"), encoding: .utf8),
          !script.lowercased().contains("</script"), !style.lowercased().contains("</style"),
          shell.contains("__VNOTE_NONCE__"), shell.contains("__VNOTE_SCRIPT__"), shell.contains("__VNOTE_STYLE__"),
          shell.contains("<head>") else { throw SurfaceError.unavailable }
    shell = shell.replacingOccurrences(of: "__VNOTE_NONCE__", with: nonce)
      .replacingOccurrences(of: "__VNOTE_ASSET_ORIGIN__", with: origin)
      .replacingOccurrences(of: "<head>", with: "<head><meta http-equiv=\"Content-Security-Policy\" content=\"\(SurfacePolicy.csp(origin: origin, nonce: nonce, editor: editor))\">")
    let replacements = ["__VNOTE_SCRIPT__": script, "__VNOTE_STYLE__": style]
    if kind == "preview" {
      guard let renderId = renderId, (try? SurfacePolicy.id(renderId)) != nil,
            shell.contains("__VNOTE_RENDER_ID__")
      else { throw SurfaceError.output }
      shell = shell.replacingOccurrences(of: "__VNOTE_RENDER_ID__", with: renderId)
    }
    // Expand only the trusted shell. Note-derived output is never embedded here;
    // the bounded viewer install protocol runs after document policy admission.
    let template = shell as NSString
    let ranges = try replacements.map { marker, value -> (NSRange, String) in
      let range = template.range(of: marker)
      guard range.location != NSNotFound,
            template.range(of: marker, options: [], range: NSRange(location: NSMaxRange(range), length: template.length - NSMaxRange(range))).location == NSNotFound
      else { throw SurfaceError.unavailable }
      return (range, value)
    }.sorted { $0.0.location < $1.0.location }
    var data = Data()
    data.reserveCapacity(shell.utf8.count + script.utf8.count + style.utf8.count)
    var offset = 0
    for (range, value) in ranges {
      data.append(contentsOf: template.substring(with: NSRange(location: offset, length: range.location - offset)).utf8)
      data.append(contentsOf: value.utf8)
      offset = NSMaxRange(range)
    }
    data.append(contentsOf: template.substring(from: offset).utf8)
    return data
  }
}

/// A pinned regular-file descriptor cannot turn into a symlink after admission.
private final class SurfaceFile {
  let descriptor: Int32
  let size: Int
  private let identity: stat
  init(parent: Int32, name: String, maximum: Int, url: URL) throws {
    guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), name != ".", name != ".."
    else { throw SurfaceError.invalid }
    let fd = name.withCString { Darwin.openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
    guard fd >= 0 else { throw SurfaceError.unavailable }
    var value = stat()
    do {
      guard fstat(fd, &value) == 0, value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            value.st_nlink == 1, value.st_size >= 0, value.st_size <= Int64(maximum)
      else { throw SurfaceError.unavailable }
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      guard attributes[.protectionKey] as? FileProtectionType == .completeUntilFirstUserAuthentication
      else { throw SurfaceError.unavailable }
      var named = stat()
      guard lstat(url.path, &named) == 0, named.st_dev == value.st_dev, named.st_ino == value.st_ino
      else { throw SurfaceError.unavailable }
    } catch { Darwin.close(fd); throw error }
    descriptor = fd
    identity = value
    size = Int(value.st_size)
  }
  deinit { Darwin.close(descriptor) }

  func read(hash: String? = nil) throws -> Data {
    guard UIApplication.shared.isProtectedDataAvailable else { throw SurfaceError.unavailable }
    var data = Data(count: size)
    try data.withUnsafeMutableBytes { raw in
      var offset = 0
      while offset < size {
        let count = pread(descriptor, raw.baseAddress!.advanced(by: offset), size - offset, off_t(offset))
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw SurfaceError.unavailable }
        offset += count
      }
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0, after.st_dev == identity.st_dev,
          after.st_ino == identity.st_ino, after.st_size == identity.st_size,
          after.st_mtimespec.tv_sec == identity.st_mtimespec.tv_sec,
          after.st_mtimespec.tv_nsec == identity.st_mtimespec.tv_nsec,
          after.st_ctimespec.tv_sec == identity.st_ctimespec.tv_sec,
          after.st_ctimespec.tv_nsec == identity.st_ctimespec.tv_nsec,
          hash == nil || SurfacePolicy.digest(data) == hash else { throw SurfaceError.unavailable }
    return data
  }
}

private func openSurfaceDirectory(parent: Int32, name: String) throws -> Int32 {
  let fd = name.withCString { Darwin.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
  guard fd >= 0 else { throw SurfaceError.unavailable }
  var metadata = stat()
  guard fstat(fd, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
  else { Darwin.close(fd); throw SurfaceError.unavailable }
  return fd
}

/// Denies public UI/media permission callbacks independently of page policy.
private final class SurfaceUIDelegate: NSObject, WKUIDelegate {
  weak var forwarded: WKUIDelegate?
  init(forwarded: WKUIDelegate? = nil) { self.forwarded = forwarded }
  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
               for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
  func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
               initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) { completionHandler() }
  func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
               initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) { completionHandler(false) }
  func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
               defaultText: String?, initiatedByFrame frame: WKFrameInfo,
               completionHandler: @escaping (String?) -> Void) { completionHandler(nil) }
  @available(iOS 15.0, *)
  func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
               initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
               decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
  @available(iOS 15.0, *)
  func webView(_ webView: WKWebView, requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
               initiatedByFrame frame: WKFrameInfo,
               decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
  // Public from iOS 27; earlier systems have no public per-view location delegate.
  @available(iOS 27.0, *)
  @objc(webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:)
  func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin,
               initiatedByFrame frame: WKFrameInfo,
               decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
  @available(iOS 18.4, *)
  func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
               initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) { completionHandler(nil) }
  func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
               completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) { completionHandler(nil) }
  override func responds(to selector: Selector!) -> Bool {
    super.responds(to: selector) || forwarded?.responds(to: selector) == true
  }
  override func forwardingTarget(for selector: Selector!) -> Any? {
    forwarded?.responds(to: selector) == true ? forwarded : super.forwardingTarget(for: selector)
  }
}

private final class SurfaceNavigation: NSObject, WKNavigationDelegate {
  weak var forwarded: WKNavigationDelegate?
  let origin: String
  var permitEntry = true
  var didLoad: (() -> Void)?
  var lost: (() -> Void)?
  var failed: (() -> Void)?
  var navigation: ((URL, Bool) -> Void)?
  init(origin: String, forwarded: WKNavigationDelegate? = nil) {
    self.origin = origin; self.forwarded = forwarded
  }
  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
               preferences: WKWebpagePreferences,
               decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
    self.webView(webView, decidePolicyFor: action) { policy in decisionHandler(policy, preferences) }
  }
  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
               decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let url = action.request.url, action.targetFrame?.isMainFrame == true,
          !action.shouldPerformDownload else { decisionHandler(.cancel); return }
    let entry = origin + "/"
    let allowedEntry = permitEntry && url.absoluteString == entry
    let fragment = url.absoluteString.hasPrefix(entry + "#") && webView.url?.absoluteString.components(separatedBy: "#").first == entry
    guard allowedEntry || fragment else {
      if action.navigationType == .linkActivated { navigation?(url, true) }
      decisionHandler(.cancel)
      return
    }
    if allowedEntry { permitEntry = false }
    let boundedDecision: (WKNavigationActionPolicy) -> Void = { decisionHandler($0 == .allow ? .allow : .cancel) }
    if let _ = forwarded?.webView?(webView, decidePolicyFor: action, decisionHandler: boundedDecision) {
      return
    }
    decisionHandler(.allow)
  }
  func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
               decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
    guard response.isForMainFrame, response.canShowMIMEType,
          response.response.mimeType == "text/html" else { decisionHandler(.cancel); return }
    let boundedDecision: (WKNavigationResponsePolicy) -> Void = { decisionHandler($0 == .allow ? .allow : .cancel) }
    if let _ = forwarded?.webView?(webView, decidePolicyFor: response, decisionHandler: boundedDecision) {
      return
    }
    decisionHandler(.allow)
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    forwarded?.webView?(webView, didFinish: navigation)
    didLoad?()
  }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    forwarded?.webView?(webView, didFail: navigation, withError: error)
    failed?()
  }
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    forwarded?.webView?(webView, didFailProvisionalNavigation: navigation, withError: error)
    failed?()
  }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    forwarded?.webViewWebContentProcessDidTerminate?(webView)
    lost?()
  }
  override func responds(to selector: Selector!) -> Bool {
    super.responds(to: selector) || forwarded?.responds(to: selector) == true
  }
  override func forwardingTarget(for selector: Selector!) -> Any? {
    forwarded?.responds(to: selector) == true ? forwarded : super.forwardingTarget(for: selector)
  }
}

private struct SurfaceImage {
  let file: SurfaceFile
  let mime: String
  let hash: String
  let width: Int
  let height: Int
  var decodedBytes: Int { width * height * 4 }
}

private final class SurfaceSnapshot {
  let previewId: String
  let renderId: String
  let directory: Int32
  let url: URL
  var source: String?
  let imageMap: [[String: Any]]
  let navigationMap: [[String: Any]]
  let navigationHandles: Set<String>
  let images: [String: SurfaceImage]
  var output: SurfaceFile?
  var outputHash: String?

  init(previewId: String, renderId: String) throws {
    guard UIApplication.shared.isProtectedDataAvailable,
          let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
    else { throw SurfaceError.unavailable }
    self.previewId = previewId; self.renderId = renderId
    let anchor = library.resolvingSymlinksInPath().standardizedFileURL
    let libraryFD = Darwin.open(anchor.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard libraryFD >= 0 else { throw SurfaceError.unavailable }
    defer { Darwin.close(libraryFD) }
    let support = try openSurfaceDirectory(parent: libraryFD, name: "Application Support")
    defer { Darwin.close(support) }
    let root = try openSurfaceDirectory(parent: support, name: "previews")
    defer { Darwin.close(root) }
    let rootURL = anchor.appendingPathComponent("Application Support/previews", isDirectory: true)
    let rootAttributes = try FileManager.default.attributesOfItem(atPath: rootURL.path)
    let rootValues = try rootURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
    guard rootAttributes[.protectionKey] as? FileProtectionType == .completeUntilFirstUserAuthentication,
          rootValues.isExcludedFromBackup == true else { throw SurfaceError.unavailable }
    let owner = try openSurfaceDirectory(parent: root, name: previewId)
    defer { Darwin.close(owner) }
    let fd = try openSurfaceDirectory(parent: owner, name: renderId)
    let url = rootURL.appendingPathComponent(previewId, isDirectory: true)
      .appendingPathComponent(renderId, isDirectory: true)
    do {
      var revoked = stat()
      guard fstatat(fd, "revoked.json", &revoked, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT
      else { throw SurfaceError.unavailable }
      let manifestFile = try SurfaceFile(parent: fd, name: "manifest.json", maximum: 16 * 1024 * 1024,
                                         url: url.appendingPathComponent("manifest.json"))
      let sealFile = try SurfaceFile(parent: fd, name: "manifest.sha256", maximum: 64,
                                     url: url.appendingPathComponent("manifest.sha256"))
      guard let seal = String(data: try sealFile.read(), encoding: .utf8), seal.utf8.count == 64
      else { throw SurfaceError.unavailable }
      let manifestData = try manifestFile.read(hash: seal)
      let manifest = try SurfacePolicy.object(try JSONSerialization.jsonObject(with: manifestData), keys:
        ["version", "previewId", "renderId", "sourceRevision", "sourceHash", "sourceBytes", "notebookId", "nodeId", "images", "files", "navigation", "encodedBytes"])
      guard try SurfacePolicy.integer(manifest["version"], maximum: 1) == 1,
            manifest["previewId"] as? String == previewId, manifest["renderId"] as? String == renderId,
            let sourceHash = manifest["sourceHash"] as? String,
            let rawImages = manifest["images"] as? [[String: Any]], rawImages.count <= 200,
            let files = manifest["files"] as? [[String: Any]], files.count <= 200,
            let navigation = manifest["navigation"] as? [[String: Any]], navigation.count <= 100000
      else { throw SurfaceError.unavailable }
      _ = try SurfacePolicy.integer(manifest["sourceRevision"], maximum: 9007199254740991)
      let sourceFile = try SurfaceFile(parent: fd, name: "source.md", maximum: SurfacePolicy.sourceLimit,
                                       url: url.appendingPathComponent("source.md"))
      guard sourceFile.size == (try SurfacePolicy.integer(manifest["sourceBytes"], maximum: SurfacePolicy.sourceLimit)),
            let source = String(data: try sourceFile.read(hash: sourceHash), encoding: .utf8),
            !source.utf8.contains(0) else { throw SurfaceError.unavailable }
      self.source = source
      let filesFD = try openSurfaceDirectory(parent: fd, name: "files")
      defer { Darwin.close(filesFD) }
      var fileRecords: [String: [String: Any]] = [:]
      var totalBytes = 0
      for record in files {
        _ = try SurfacePolicy.object(record, keys: ["handle", "name", "mime", "bytes", "sha256"])
        let handle = try SurfacePolicy.id(record["handle"])
        guard fileRecords[handle] == nil else { throw SurfaceError.unavailable }
        totalBytes += try SurfacePolicy.integer(record["bytes"], maximum: SurfacePolicy.outputLimit)
        guard totalBytes <= SurfacePolicy.imageBudget else { throw SurfaceError.unavailable }
        fileRecords[handle] = record
      }
      guard totalBytes == (try SurfacePolicy.integer(manifest["encodedBytes"], maximum: SurfacePolicy.imageBudget))
      else { throw SurfaceError.unavailable }
      var images: [String: SurfaceImage] = [:]
      var imageMap: [[String: Any]] = []
      var imageSources = Set<String>()
      for record in rawImages {
        _ = try SurfacePolicy.object(record, keys: ["source", "handle", "mime", "width", "height", "bytes", "sha256"])
        let handle = try SurfacePolicy.id(record["handle"])
        let width = try SurfacePolicy.integer(record["width"], maximum: 16000000)
        let height = try SurfacePolicy.integer(record["height"], maximum: 16000000)
        let size = try SurfacePolicy.integer(record["bytes"], maximum: SurfacePolicy.outputLimit)
        guard let destination = record["source"] as? String, destination.utf8.count <= 8192,
              imageSources.insert(destination).inserted, width > 0, height > 0, width * height <= 16000000,
              let mime = record["mime"] as? String, ["image/png", "image/jpeg", "image/webp"].contains(mime),
              let hash = record["sha256"] as? String, let fileRecord = fileRecords[handle],
              fileRecord["sha256"] as? String == hash, fileRecord["mime"] as? String == mime,
              try SurfacePolicy.integer(fileRecord["bytes"], maximum: SurfacePolicy.outputLimit) == size
        else { throw SurfaceError.unavailable }
        if images[handle] == nil {
          let file = try SurfaceFile(parent: filesFD, name: handle, maximum: SurfacePolicy.outputLimit,
                                      url: url.appendingPathComponent("files/" + handle))
          guard file.size == size else { throw SurfaceError.unavailable }
          images[handle] = SurfaceImage(file: file, mime: mime, hash: hash, width: width, height: height)
        } else if images[handle]?.width != width || images[handle]?.height != height {
          throw SurfaceError.unavailable
        }
        imageMap.append(["source": destination, "handle": handle, "width": width, "height": height])
      }
      var navigationMap: [[String: Any]] = []
      var navigationHandles = Set<String>()
      var navigationSources = Set<String>()
      for record in navigation {
        let handle = try SurfacePolicy.id(record["handle"])
        guard let destination = record["source"] as? String, destination.utf8.count <= 8192,
              navigationSources.insert(destination).inserted,
              let kind = record["kind"] as? String, ["note", "external", "export"].contains(kind)
        else { throw SurfaceError.unavailable }
        navigationHandles.insert(handle)
        navigationMap.append(["source": destination, "handle": handle])
      }
      self.images = images; self.imageMap = imageMap
      self.navigationMap = navigationMap; self.navigationHandles = navigationHandles
    } catch { Darwin.close(fd); throw error }
    directory = fd; self.url = url
  }
  deinit { Darwin.close(directory) }

  func request(preferences: [String: Any]) throws -> [String: Any] {
    guard let source = source else { throw SurfaceError.unavailable }
    let base = SurfacePolicy.previewOrigin + "/g/" + renderId
    return ["version": 1, "renderId": renderId, "source": source, "images": imageMap,
            "navigation": navigationMap, "mediaBase": base + "/media/", "navBase": base + "/nav/",
            "preferences": preferences]
  }

  func saveOutput(_ data: Data) throws {
    guard data.count <= SurfacePolicy.outputLimit, UIApplication.shared.isProtectedDataAvailable
    else { throw SurfaceError.output }
    let name = "output.html"
    let fd = Darwin.openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw SurfaceError.unavailable }
    var succeeded = false
    defer { Darwin.close(fd); if !succeeded { unlinkat(directory, name, 0) } }
    let attributes = try FileManager.default.attributesOfItem(atPath: url.appendingPathComponent(name).path)
    guard attributes[.protectionKey] as? FileProtectionType == .completeUntilFirstUserAuthentication
    else { throw SurfaceError.unavailable }
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < data.count {
        let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw SurfaceError.unavailable }
        offset += count
      }
    }
    guard fsync(fd) == 0 else { throw SurfaceError.unavailable }
    output = try SurfaceFile(parent: directory, name: name, maximum: SurfacePolicy.outputLimit,
                             url: url.appendingPathComponent(name))
    outputHash = SurfacePolicy.digest(data)
    succeeded = true
  }
}

private final class SurfaceSchemeHandler: NSObject, WKURLSchemeHandler {
  let origin: String
  let nonce: String
  let shell: Data
  let assets: SurfaceAssets
  let snapshot: SurfaceSnapshot
  private let reader = DispatchQueue(label: "vnote.preview-reader", qos: .userInitiated)
  private var tasks: [ObjectIdentifier: WKURLSchemeTask] = [:]
  private var active = true
  private var imageReads = 0
  private var admitted = Set<String>()
  private var admittedBytes = 0
  private var admissionVersion: UInt64 = 0

  init(origin: String, nonce: String, shell: Data, assets: SurfaceAssets, snapshot: SurfaceSnapshot) {
    self.origin = origin; self.nonce = nonce; self.shell = shell
    self.assets = assets; self.snapshot = snapshot
  }

  func pollAdmissions(_ webView: WKWebView, completion: @escaping () -> Void) {
    let version = admissionVersion
    webView.evaluateJavaScript("window.vnotePreview.status()") { [weak self] value, error in
      defer { completion() }
      guard let self = self, self.active, error == nil,
            let status = try? SurfacePolicy.object(value, keys: ["version", "renderId", "images"]),
            (try? SurfacePolicy.integer(status["version"], maximum: 1)) == 1,
            status["renderId"] as? String == self.snapshot.renderId,
            let handles = status["images"] as? [String], handles.count <= 200
      else { return }
      let current = Set(handles)
      guard current.allSatisfy({ self.snapshot.images[$0] != nil }),
            current.reduce(0, { $0 + self.snapshot.images[$1]!.decodedBytes }) <= SurfacePolicy.imageBudget
      else { return }
      // A stale poll cannot release an admission made while its JS callback was pending.
      if version == self.admissionVersion {
        self.admitted.formIntersection(current)
        self.admittedBytes = self.admitted.reduce(0) { $0 + self.snapshot.images[$1]!.decodedBytes }
      }
    }
  }

  func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
    guard active, tasks.count < 8, let url = task.request.url, url.absoluteString.utf8.count <= 1024,
          task.request.httpMethod == nil || task.request.httpMethod == "GET",
          url.query == nil, url.fragment == nil, url.user == nil, url.password == nil, url.port == nil,
          url.absoluteString.hasPrefix(origin + "/"), !url.absoluteString.contains("%"),
          !url.path.contains(".."), !url.path.contains("\\") else {
      task.didFailWithError(NSError(domain: "VNoteSurface", code: 1)); return
    }
    let key = ObjectIdentifier(task)
    let path = url.path
    var image: SurfaceImage?
    var mime = "text/html"
    var assetName: String?
    if path == "/" {
      mime = "text/html"
    } else if path.hasPrefix("/fonts/"), path.hasSuffix(".woff2") {
      assetName = String(path.dropFirst()); mime = "font/woff2"
    } else if path.hasPrefix("/bundle/") {
      let name = String(path.dropFirst("/bundle/".count))
      // Renderer code is never executable in the visible view, or vice versa.
      let allowed = origin == SurfacePolicy.renderOrigin ? ["render.js", "preview.css"] : ["preview.js", "preview.css"]
      guard allowed.contains(name) else { task.didFailWithError(NSError(domain: "VNoteSurface", code: 1)); return }
      assetName = name; mime = name.hasSuffix(".js") ? "text/javascript" : "text/css"
    } else if origin == SurfacePolicy.previewOrigin,
              path.hasPrefix("/g/\(snapshot.renderId)/media/") {
      let handle = String(path.dropFirst("/g/\(snapshot.renderId)/media/".count))
      guard let value = snapshot.images[handle], imageReads < 4,
            admitted.contains(handle) || admittedBytes + value.decodedBytes <= SurfacePolicy.imageBudget
      else { task.didFailWithError(NSError(domain: "VNoteSurface", code: 1)); return }
      if admitted.insert(handle).inserted { admittedBytes += value.decodedBytes }
      admissionVersion &+= 1
      image = value; mime = value.mime; imageReads += 1
    } else { task.didFailWithError(NSError(domain: "VNoteSurface", code: 1)); return }
    tasks[key] = task
    let isImage = image != nil
    let selectedImage = image
    let selectedAsset = assetName
    let selectedMIME = mime
    reader.async { [self] in
      let result: Result<Data, Error>
      do {
        let data: Data
        if let image = selectedImage {
          data = try image.file.read(hash: image.hash)
          guard Self.validImage(data, image: image) else { throw SurfaceError.unavailable }
        } else if let asset = selectedAsset { data = try assets.asset(group: "preview", name: asset) }
        else { data = shell }
        result = .success(data)
      } catch { result = .failure(error) }
      DispatchQueue.main.async { [self] in
        if isImage { imageReads -= 1 }
        guard active, let current = tasks.removeValue(forKey: key) else { return }
        switch result {
        case .success(let data):
          let headers = ["Content-Type": selectedMIME, "Content-Length": String(data.count),
            "X-Content-Type-Options": "nosniff", "Cache-Control": "no-store",
            "Permissions-Policy": "geolocation=(), camera=(), microphone=(), accelerometer=(), gyroscope=(), magnetometer=(), usb=(), payment=()",
            "Content-Security-Policy": SurfacePolicy.csp(origin: origin, nonce: nonce, editor: false)]
          guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)
          else { current.didFailWithError(NSError(domain: "VNoteSurface", code: 1)); return }
          current.didReceive(response); current.didReceive(data); current.didFinish()
        case .failure: current.didFailWithError(NSError(domain: "VNoteSurface", code: 1))
        }
      }
    }
  }

  private static func validImage(_ data: Data, image: SurfaceImage) -> Bool {
    let signature: Bool
    switch image.mime {
    case "image/png": signature = data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
    case "image/jpeg": signature = data.starts(with: [255, 216, 255])
    case "image/webp": signature = data.count >= 12 && data.prefix(4) == Data("RIFF".utf8) && data[8..<12] == Data("WEBP".utf8)
    default: return false
    }
    guard signature, let source = CGImageSourceCreateWithData(data as CFData,
      [kCGImageSourceShouldCache: false] as CFDictionary), CGImageSourceGetCount(source) == 1,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0,
        [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { return false }
    return width == image.width && height == image.height && width * height <= 16000000
  }

  func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
    tasks.removeValue(forKey: ObjectIdentifier(task))
  }

  func retire(_ completion: @escaping () -> Void) {
    active = false
    for task in tasks.values { task.didFailWithError(NSError(domain: "VNoteSurface", code: 2)) }
    tasks.removeAll()
    // Both queued file reads and their main-thread callbacks finish before releasing the lease.
    reader.async { DispatchQueue.main.async(execute: completion) }
  }
}

private final class SurfaceContext {
  let webView: WKWebView
  let handler: SurfaceSchemeHandler
  let navigation: SurfaceNavigation
  private let ui = SurfaceUIDelegate()
  init(origin: String, shell: Data, nonce: String, snapshot: SurfaceSnapshot,
       assets: SurfaceAssets, rules: WKContentRuleList) {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.userContentController = WKUserContentController()
    configuration.userContentController.add(rules)
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    configuration.allowsInlineMediaPlayback = false
    configuration.mediaTypesRequiringUserActionForPlayback = .all
    handler = SurfaceSchemeHandler(origin: origin, nonce: nonce, shell: shell, assets: assets, snapshot: snapshot)
    // Scheme handlers are immutable configuration: set BEFORE constructing this WKWebView.
    configuration.setURLSchemeHandler(handler, forURLScheme: URL(string: origin)!.scheme!)
    webView = WKWebView(frame: .zero, configuration: configuration)
    navigation = SurfaceNavigation(origin: origin)
    webView.navigationDelegate = navigation
    webView.uiDelegate = ui
    webView.allowsBackForwardNavigationGestures = false
    webView.allowsLinkPreview = false
    webView.isOpaque = false
    webView.backgroundColor = .clear
    if #available(iOS 16.4, *) { webView.isInspectable = false }
  }
  func load() { webView.load(URLRequest(url: URL(string: handler.origin + "/")!)) }
  func retire(_ completion: @escaping () -> Void) {
    navigation.didLoad = nil; navigation.failed = nil; navigation.lost = nil; navigation.navigation = nil
    webView.stopLoading()
    webView.navigationDelegate = nil; webView.uiDelegate = nil
    webView.removeFromSuperview()
    webView.configuration.userContentController.removeAllUserScripts()
    handler.retire(completion)
    // Public teardown is not a claim that WebKit forcibly kills its shared content process.
  }
}

private final class SurfaceRender {
  let snapshot: SurfaceSnapshot
  private let assets: SurfaceAssets
  private let preferences: [String: Any]
  private weak var container: UIView?
  private var context: SurfaceContext?
  private var completion: ((String?) -> Void)?
  private var timer: DispatchWorkItem?
  private var deadline: UInt64 = 0
  private var jobDeadline: UInt64 = 0
  private var startup = true
  private var retiring = false
  private let gate = NSLock()
  private var expired = false
  private var watchdogGeneration: UInt64 = 0
  private var outputData = Data()
  private var outputUnits = 0
  private var expectedUnits = 0
  private var expectedBytes = 0
  private var writePending = false
  private var joined: [() -> Void] = []
  private let writer = DispatchQueue(label: "vnote.preview-output", qos: .userInitiated)

  init(snapshot: SurfaceSnapshot, assets: SurfaceAssets, preferences: [String: Any], container: UIView,
       completion: @escaping (String?) -> Void) {
    self.snapshot = snapshot; self.assets = assets; self.preferences = preferences
    self.container = container; self.completion = completion
  }

  func start() {
    armDeadline(seconds: 10, job: false)
    SurfacePolicy.rules(origin: SurfacePolicy.renderOrigin) { [weak self] rules in
      guard let self = self, self.live else { return }
      guard let rules = rules else { self.finish("renderer_unavailable"); return }
      do {
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let shell = try self.assets.shell(kind: "render", nonce: nonce)
        let context = SurfaceContext(origin: SurfacePolicy.renderOrigin, shell: shell, nonce: nonce,
          snapshot: self.snapshot, assets: self.assets, rules: rules)
        self.context = context
        context.webView.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        context.webView.alpha = 0
        context.webView.isUserInteractionEnabled = false
        context.webView.accessibilityElementsHidden = true
        self.container?.addSubview(context.webView)
        context.navigation.didLoad = { [weak self] in self?.prepare() }
        context.navigation.failed = { [weak self] in self?.finish("renderer_failed") }
        context.navigation.lost = { [weak self] in self?.finish("renderer_failed") }
        context.load()
      } catch { self.finish("renderer_unavailable") }
    }
  }

  private var live: Bool {
    gate.lock(); let permitted = !expired; gate.unlock()
    return !retiring && permitted
  }

  private func armDeadline(seconds: UInt64, job: Bool) {
    let now = DispatchTime.now().uptimeNanoseconds
    if job { jobDeadline = now + seconds * 1_000_000_000 }
    else { deadline = now + seconds * 1_000_000_000; jobDeadline = 0 }
    scheduleWatchdog()
  }

  private func scheduleWatchdog() {
    timer?.cancel()
    let due = jobDeadline == 0 ? deadline : min(deadline, jobDeadline)
    gate.lock(); watchdogGeneration &+= 1; let generation = watchdogGeneration; gate.unlock()
    let item = DispatchWorkItem { [weak self] in
      guard let self = self else { return }
      self.gate.lock()
      let current = self.watchdogGeneration == generation
      if current { self.expired = true }
      self.gate.unlock()
      if current { DispatchQueue.main.async { self.finish("renderer_timeout") } }
    }
    timer = item
    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: DispatchTime(uptimeNanoseconds: due), execute: item)
  }

  private func prepare() {
    guard live, startup else { return }
    startup = false
    armDeadline(seconds: 5, job: false)
    do {
      let request = try SurfacePolicy.json(snapshot.request(preferences: preferences), maximumBytes: 48 * 1024 * 1024)
      snapshot.source = nil
      evaluate("window.vnoteRender.prepare(\(request))") { [weak self] value in self?.status(value) }
    } catch { finish("renderer_failed") }
  }

  private func evaluate(_ expression: String, completion: @escaping (Any?) -> Void) {
    guard live, let context = context else { return }
    context.webView.evaluateJavaScript(expression) { [weak self] value, error in
      guard let self = self, self.live else { return }
      if error != nil { self.finish("renderer_failed") } else { completion(value) }
    }
  }

  private func poll() {
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20)) { [weak self] in
      self?.evaluate("window.vnoteRender.status()") { [weak self] value in self?.status(value) }
    }
  }

  private func status(_ value: Any?) {
    guard live else { return }
    do {
      let status = try SurfacePolicy.object(value, keys:
        ["version", "renderId", "phase", "jobs", "nextJob", "activeKind", "outputUnits", "outputBytes", "error"])
      guard try SurfacePolicy.integer(status["version"], maximum: 1) == 1,
            status["renderId"] as? String == snapshot.renderId,
            let phase = status["phase"] as? String else { throw SurfaceError.output }
      let jobs = try SurfacePolicy.integer(status["jobs"], maximum: 220)
      let next = try SurfacePolicy.integer(status["nextJob"], maximum: jobs)
      let units = try SurfacePolicy.integer(status["outputUnits"], maximum: SurfacePolicy.outputLimit)
      let bytes = try SurfacePolicy.integer(status["outputBytes"], maximum: SurfacePolicy.outputLimit)
      guard status["error"] is NSNull,
            status["activeKind"] is NSNull || ["math", "diagram"].contains(status["activeKind"] as? String ?? "")
      else { throw SurfaceError.output }
      switch phase {
      case "prepared":
        guard next < jobs else { throw SurfaceError.output }
        jobDeadline = 0
        armDeadline(seconds: 2, job: true)
        evaluate("void window.vnoteRender.runJob(\(next))") { [weak self] _ in self?.poll() }
      case "running": poll()
      case "ready":
        guard next == jobs else { throw SurfaceError.output }
        jobDeadline = 0; scheduleWatchdog()
        evaluate("window.vnoteRender.finish()") { [weak self] value in self?.status(value) }
      case "complete":
        guard next == jobs else { throw SurfaceError.output }
        expectedUnits = units; expectedBytes = bytes
        outputData.reserveCapacity(bytes)
        readOutput()
      default: throw SurfaceError.output
      }
    } catch { finish("output_invalid") }
  }

  private func readOutput() {
    guard live else { return }
    if outputUnits == expectedUnits {
      let data = outputData
      outputData = Data()
      guard data.count == expectedBytes, data.count <= SurfacePolicy.outputLimit else { finish("output_invalid"); return }
      writePending = true
      writer.async { [self] in
        let error: String?
        do { try snapshot.saveOutput(data); error = nil } catch { error = "output_invalid" }
        DispatchQueue.main.async { [self] in
          writePending = false
          if retiring { completeRetirement() } else { finish(error) }
        }
      }
      return
    }
    let count = min(32768, expectedUnits - outputUnits)
    evaluate("window.vnoteRender.readOutput(\(outputUnits),\(count))") { [weak self] value in
      guard let self = self, let text = value as? String,
            text.utf16.count > 0, text.utf16.count <= count,
            text.utf16.count >= count - 1
      else { self?.finish("output_invalid"); return }
      guard self.outputData.count + text.utf8.count <= self.expectedBytes else { self.finish("output_invalid"); return }
      self.outputUnits += text.utf16.count
      self.outputData.append(contentsOf: text.utf8)
      self.readOutput()
    }
  }

  func cancel(_ completion: @escaping () -> Void) {
    joined.append(completion)
    finish("cancelled")
  }

  private func finish(_ category: String?) {
    guard !retiring else { if !writePending && context == nil { completeRetirement() }; return }
    retiring = true
    gate.lock()
    let outcome = expired && category != "cancelled" ? "renderer_timeout" : category
    watchdogGeneration &+= 1
    gate.unlock()
    timer?.cancel(); timer = nil
    snapshot.source = nil
    outputData = Data()
    let callback = completion; completion = nil
    joined.insert({ callback?(outcome) }, at: 0)
    if let context = context {
      context.retire { [self] in self.context = nil; if !writePending { completeRetirement() } }
    } else if !writePending { completeRetirement() }
  }

  private func completeRetirement() {
    guard context == nil, !writePending else { return }
    let callbacks = joined; joined.removeAll()
    for callback in callbacks { callback() }
  }
}

private final class HardenedEditor {
  let webView: WKWebView
  let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
  let navigation: SurfaceNavigation
  let ui: SurfaceUIDelegate
  var configured = false
  init(_ webView: WKWebView) {
    self.webView = webView
    navigation = SurfaceNavigation(origin: SurfacePolicy.editorOrigin, forwarded: webView.navigationDelegate)
    ui = SurfaceUIDelegate(forwarded: webView.uiDelegate)
    webView.stopLoading()
    webView.navigationDelegate = navigation; webView.uiDelegate = ui
    webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    webView.allowsLinkPreview = false; webView.allowsBackForwardNavigationGestures = false
    if #available(iOS 16.4, *) { webView.isInspectable = false }
  }
  func retire() {
    configured = false
    webView.stopLoading()
    navigation.lost = nil
    if webView.navigationDelegate === navigation { webView.navigationDelegate = navigation.forwarded }
    if webView.uiDelegate === ui { webView.uiDelegate = ui.forwarded }
  }
}

private final class NativePreviewView: NSObject, FlutterPlatformView {
  let container: UIView
  let surfaceId: String
  weak var plugin: WebSurfacePlugin?
  var renderer: SurfaceRender?
  var completed: SurfaceSnapshot?
  var displayed: SurfaceSnapshot?
  var context: SurfaceContext?
  var pendingRenderId: String?
  var preferences: [String: Any] = ["dark": false, "highContrast": false, "fontScale": 1.0, "reducedMotion": false]
  var closing = false
  var displayEpoch = UUID()
  var showResult: FlutterResult?
  var showTimeout: DispatchWorkItem?
  var retiringDisplay = false
  var retiringRenderId: String?
  var displayJoined: [() -> Void] = []
  var installingOutput: NSString?
  init(frame: CGRect, surfaceId: String, plugin: WebSurfacePlugin) {
    container = UIView(frame: frame); self.surfaceId = surfaceId; self.plugin = plugin
    super.init()
    container.accessibilityLabel = "Note preview"
  }
  func view() -> UIView { container }
  deinit {
    let renderer = renderer; let context = context
    DispatchQueue.main.async { renderer?.cancel {}; context?.retire {} }
  }
}

private final class DeniedPreviewView: NSObject, FlutterPlatformView {
  private let label = UILabel()
  override init() {
    super.init(); label.text = "Preview unavailable"; label.numberOfLines = 0
    label.font = .preferredFont(forTextStyle: .body); label.adjustsFontForContentSizeCategory = true
    label.accessibilityLabel = "Preview unavailable. Source remains available."
  }
  func view() -> UIView { label }
}

private final class SurfaceViewFactory: NSObject, FlutterPlatformViewFactory {
  weak var plugin: WebSurfacePlugin?
  init(_ plugin: WebSurfacePlugin) { self.plugin = plugin }
  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol { FlutterStandardMessageCodec.sharedInstance() }
  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    guard let plugin = plugin,
          let object = try? SurfacePolicy.object(args, keys: ["surfaceId"]),
          let surfaceId = try? SurfacePolicy.id(object["surfaceId"]),
          plugin.views[surfaceId]?.value == nil, plugin.views.values.filter({ $0.value != nil }).count < 4
    else { return DeniedPreviewView() }
    let view = NativePreviewView(frame: frame, surfaceId: surfaceId, plugin: plugin)
    plugin.views[surfaceId] = WeakPreviewView(view)
    return view
  }
}

private final class WeakPreviewView {
  weak var value: NativePreviewView?
  init(_ value: NativePreviewView) { self.value = value }
}

final class WebSurfacePlugin: NSObject, FlutterPlugin {
  private let registrar: FlutterPluginRegistrar
  private let channel: FlutterMethodChannel
  private let assets: SurfaceAssets
  private var editors: [String: HardenedEditor] = [:]
  fileprivate var views: [String: WeakPreviewView] = [:]
  private var attached = true
  private var activeRender: SurfaceRender?
  private var pendingRender: (surface: NativePreviewView, previewId: String, renderId: String, preferences: [String: Any], result: FlutterResult)?

  private init(registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
    channel = FlutterMethodChannel(name: "vnote.mobile/web_surface", binaryMessenger: registrar.messenger())
    assets = SurfaceAssets(registrar)
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = WebSurfacePlugin(registrar: registrar)
    registrar.addMethodCallDelegate(instance, channel: instance.channel)
    registrar.register(SurfaceViewFactory(instance), withId: "vnote.mobile/preview")
    registrar.publish(instance)
  }

  private func failure(_ result: FlutterResult, code: String = "surface_unavailable") {
    result(FlutterError(code: code, message: "The private web surface is unavailable.", details: nil))
  }

  private func event(_ value: [String: Any]) { if attached { channel.invokeMethod("event", arguments: value) } }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard attached else { failure(result); return }
    // WKContentRuleList is not an all-protocol firewall: public WK currently
    // supplies no proven native RTC/ICE policy, and loadHTMLString cannot carry
    // a response Connection-Allowlist. Refuse BEFORE loading even an editor
    // shell, reading a source snapshot, or installing any note-derived markup.
    // The isolated implementation below does not authorize bypassing this gate;
    // admitting an engine requires a real native policy and per-document proof.
    switch call.method {
    case "configureEditor", "loadEditor", "render", "show":
      result(FlutterError(code: "offline_policy_unavailable",
                          message: "This iOS WebKit cannot enforce the required offline network policy. Private source and drafts remain available for recovery and export.",
                          details: nil))
      return
    default: break
    }
    do {
      switch call.method {
      case "configureEditor":
        let args = try SurfacePolicy.object(call.arguments, keys: ["surfaceId", "webViewIdentifier"])
        let id = try SurfacePolicy.id(args["surfaceId"])
        let identifier = try SurfacePolicy.integer(args["webViewIdentifier"], maximum: 9007199254740991)
        guard editors[id] == nil, editors.count < 4,
              let webView = FWFWebViewFlutterWKWebViewExternalAPI.webView(forIdentifier: Int64(identifier), withPluginRegistrar: registrar),
              !editors.values.contains(where: { $0.webView === webView }),
              webView.url == nil || webView.url?.absoluteString == "about:blank"
        else { throw SurfaceError.unavailable }
        let editor = HardenedEditor(webView)
        editors[id] = editor
        editor.navigation.lost = { [weak self] in self?.event(["type": "editorLost", "surfaceId": id]) }
        SurfacePolicy.rules(origin: nil) { [weak self, weak editor] rules in
          guard let self = self, let editor = editor, self.attached, self.editors[id] === editor else {
            result(FlutterError(code: "surface_retired", message: "The web surface was retired.", details: nil)); return
          }
          guard let rules = rules else { self.editors.removeValue(forKey: id)?.retire(); self.failure(result); return }
          editor.webView.configuration.userContentController.add(rules)
          editor.configured = true
          result(["entryUrl": SurfacePolicy.editorOrigin + "/", "nonce": editor.nonce])
        }
      case "loadEditor":
        let args = try SurfacePolicy.object(call.arguments, keys: ["surfaceId"])
        let id = try SurfacePolicy.id(args["surfaceId"])
        guard let editor = editors[id], editor.configured,
              let html = String(data: try assets.shell(kind: "editor", nonce: editor.nonce), encoding: .utf8)
        else { throw SurfaceError.unavailable }
        editor.navigation.permitEntry = true
        editor.webView.loadHTMLString(html, baseURL: URL(string: SurfacePolicy.editorOrigin + "/"))
        result(nil)
      case "disposeEditor":
        let args = try SurfacePolicy.object(call.arguments, keys: ["surfaceId"])
        editors.removeValue(forKey: try SurfacePolicy.id(args["surfaceId"]))?.retire()
        result(nil)
      case "render":
        let args = try SurfacePolicy.object(call.arguments, keys: ["surfaceId", "previewId", "renderId", "preferences"])
        let id = try SurfacePolicy.id(args["surfaceId"])
        let previewId = try SurfacePolicy.id(args["previewId"])
        let renderId = try SurfacePolicy.id(args["renderId"])
        let preferences = try SurfacePolicy.preferences(args["preferences"])
        guard let view = views[id]?.value, !view.closing,
              view.renderer?.snapshot.renderId != renderId, view.completed?.renderId != renderId,
              view.pendingRenderId != renderId else { throw SurfaceError.unavailable }
        if let pending = pendingRender {
          pending.surface.pendingRenderId = nil
          pending.result(["status": "superseded", "renderId": pending.renderId])
        }
        pendingRender = (view, previewId, renderId, preferences, result)
        view.pendingRenderId = renderId
        if let active = activeRender { active.cancel {} } else { startPending() }
      case "show":
        let args = try SurfacePolicy.object(call.arguments, keys: ["surfaceId", "previewId", "renderId"])
        let id = try SurfacePolicy.id(args["surfaceId"])
        let previewId = try SurfacePolicy.id(args["previewId"])
        let renderId = try SurfacePolicy.id(args["renderId"])
        guard let view = views[id]?.value, !view.closing, let snapshot = view.completed,
              snapshot.previewId == previewId, snapshot.renderId == renderId,
              view.renderer == nil, view.pendingRenderId == nil else { throw SurfaceError.unavailable }
        show(snapshot, in: view, result: result)
      case "fragment":
        let args = try SurfacePolicy.object(call.arguments, keys: ["surfaceId", "renderId", "fragment"])
        let id = try SurfacePolicy.id(args["surfaceId"])
        let renderId = try SurfacePolicy.id(args["renderId"])
        guard let slug = args["fragment"] as? String, slug.utf16.count <= 8192,
              !slug.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              let view = views[id]?.value, !view.closing, let context = view.context,
              view.displayed?.renderId == renderId, view.showResult == nil
        else { throw SurfaceError.unavailable }
        let epoch = view.displayEpoch
        context.webView.evaluateJavaScript("window.vnotePreview.fragment(\(try SurfacePolicy.json(slug)))") { [weak self, weak view] _, error in
          guard let self = self, let view = view, view.displayEpoch == epoch,
                view.displayed?.renderId == renderId, !view.closing, error == nil
          else { result(FlutterError(code: "surface_retired", message: "The web surface was retired.", details: nil)); return }
          result(nil)
        }
      case "preferences":
        let args = try SurfacePolicy.object(call.arguments, keys: ["surfaceId", "preferences"])
        let id = try SurfacePolicy.id(args["surfaceId"])
        guard let view = views[id]?.value, !view.closing else { throw SurfaceError.unavailable }
        view.preferences = try SurfacePolicy.preferences(args["preferences"])
        if let context = view.context {
          let script = "window.vnotePreview.preferences(\(try SurfacePolicy.json(view.preferences)))"
          context.webView.evaluateJavaScript(script) { [weak self] _, error in
            if error == nil { result(nil) } else { self?.failure(result) }
          }
        } else { result(nil) }
      case "cancel":
        let args = try SurfacePolicy.object(call.arguments, keys: ["surfaceId", "renderId"])
        let id = try SurfacePolicy.id(args["surfaceId"])
        let renderId = try SurfacePolicy.id(args["renderId"])
        if let pending = pendingRender, pending.surface.surfaceId == id, pending.renderId == renderId {
          pendingRender = nil; pending.surface.pendingRenderId = nil
          pending.result(["status": "superseded", "renderId": renderId])
        }
        guard let view = views[id]?.value else { result(nil); return }
        if view.completed?.renderId == renderId { view.completed = nil }
        let group = DispatchGroup()
        if let renderer = view.renderer, renderer.snapshot.renderId == renderId {
          group.enter(); renderer.cancel { group.leave() }
        }
        if view.displayed?.renderId == renderId || view.retiringRenderId == renderId {
          group.enter(); retireDisplay(view) { group.leave() }
        }
        group.notify(queue: .main) { result(nil) }
      case "close":
        let args = try SurfacePolicy.object(call.arguments, keys: ["surfaceId"])
        let id = try SurfacePolicy.id(args["surfaceId"])
        guard let view = views[id]?.value else { result(nil); return }
        close(view) { result(nil) }
      case "openExternal":
        let args = try SurfacePolicy.object(call.arguments, keys: ["url"])
        guard let text = args["url"] as? String, text.utf8.count <= 8192,
              !text.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }),
              let decoded = text.removingPercentEncoding,
              !decoded.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }),
              !decoded.contains("\\"), let components = URLComponents(string: text),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.user == nil, components.password == nil, let host = components.host, !host.isEmpty,
              let url = components.url else { throw SurfaceError.invalid }
        UIApplication.shared.open(url, options: [:]) { [weak self] opened in
          if opened { result(nil) } else { self?.failure(result) }
        }
      default: result(FlutterMethodNotImplemented)
      }
    } catch { failure(result, code: error is SurfaceError ? "surface_rejected" : "surface_unavailable") }
  }

  private func startPending() {
    guard activeRender == nil, let pending = pendingRender else { return }
    pendingRender = nil; pending.surface.pendingRenderId = nil
    guard attached, !pending.surface.closing else {
      pending.result(["status": "superseded", "renderId": pending.renderId]); return
    }
    do {
      let snapshot = try SurfaceSnapshot(previewId: pending.previewId, renderId: pending.renderId)
      let view = pending.surface
      let renderResult = pending.result
      view.completed = nil
      view.preferences = pending.preferences
      let renderer = SurfaceRender(snapshot: snapshot, assets: assets, preferences: pending.preferences,
        container: view.container) { [weak self, weak view] category in
          guard let self = self else { return }
          self.activeRender = nil
          view?.renderer = nil
          if category == nil, let view = view, !view.closing {
            view.completed = snapshot
            renderResult(["status": "ready", "renderId": snapshot.renderId])
          } else if category == "cancelled" || view == nil || view?.closing == true {
            renderResult(["status": "superseded", "renderId": snapshot.renderId])
          } else {
            self.event(["type": "failure", "surfaceId": view!.surfaceId,
                        "renderId": snapshot.renderId, "category": category ?? "renderer_failed"])
            self.failure(renderResult)
          }
          self.startPending()
        }
      view.renderer = renderer; activeRender = renderer
      renderer.start()
    } catch {
      failure(pending.result)
      event(["type": "failure", "surfaceId": pending.surface.surfaceId,
             "renderId": pending.renderId, "category": "renderer_unavailable"])
      startPending()
    }
  }

  private func show(_ snapshot: SurfaceSnapshot, in view: NativePreviewView, result: @escaping FlutterResult) {
    retireDisplay(view) { [weak self, weak view] in
      guard let self = self, let view = view, self.attached, !view.closing,
            view.completed === snapshot else { result(FlutterError(code: "surface_retired", message: "The web surface was retired.", details: nil)); return }
      let epoch = UUID(); view.displayEpoch = epoch; view.showResult = result
      let timeout = DispatchWorkItem { [weak self, weak view] in
        guard let self = self, let view = view, view.displayEpoch == epoch else { return }
        self.failDisplay(view, snapshot: snapshot, category: "view_lost")
      }
      view.showTimeout = timeout
      DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(10), execute: timeout)
      SurfacePolicy.rules(origin: SurfacePolicy.previewOrigin) { [weak self, weak view] rules in
        guard let self = self, let view = view, view.displayEpoch == epoch, !view.closing else { return }
        do {
          guard let rules = rules else { throw SurfaceError.unavailable }
          let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
          let shell = try self.assets.shell(kind: "preview", nonce: nonce, renderId: snapshot.renderId)
          let context = SurfaceContext(origin: SurfacePolicy.previewOrigin, shell: shell, nonce: nonce,
            snapshot: snapshot, assets: self.assets, rules: rules)
          view.context = context; view.displayed = snapshot
          context.webView.frame = view.container.bounds
          context.webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
          view.container.addSubview(context.webView)
          context.navigation.didLoad = { [weak self, weak view, weak context] in
            guard let self = self, let view = view, let context = context, view.context === context else { return }
            context.navigation.didLoad = nil
            self.beginOutputInstall(snapshot, in: view, context: context, epoch: epoch)
          }
          context.navigation.navigation = { [weak self, weak view] url, gesture in
            guard let self = self, let view = view, view.displayEpoch == epoch,
                  url.query == nil, url.fragment == nil,
                  url.absoluteString.hasPrefix(SurfacePolicy.previewOrigin + "/g/\(snapshot.renderId)/nav/")
            else { return }
            let handle = String(url.path.split(separator: "/").last ?? "")
            guard snapshot.navigationHandles.contains(handle),
                  url.absoluteString == SurfacePolicy.previewOrigin + "/g/\(snapshot.renderId)/nav/" + handle
            else { return }
            self.event(["type": "navigation", "surfaceId": view.surfaceId, "renderId": snapshot.renderId,
                        "handle": handle, "hasGesture": gesture])
          }
          context.navigation.failed = { [weak self, weak view] in
            if let view = view { self?.failDisplay(view, snapshot: snapshot, category: "view_lost") }
          }
          context.navigation.lost = context.navigation.failed
          context.load()
        } catch { self.failDisplay(view, snapshot: snapshot, category: "output_invalid") }
      }
    }
  }

  private func beginOutputInstall(_ snapshot: SurfaceSnapshot, in view: NativePreviewView,
                                  context: SurfaceContext, epoch: UUID) {
    guard attached, !view.closing, view.displayEpoch == epoch, view.context === context,
          view.displayed === snapshot else { return }
    do {
      guard let output = snapshot.output, let hash = snapshot.outputHash,
            let text = String(data: try output.read(hash: hash), encoding: .utf8),
            text.utf16.count <= SurfacePolicy.outputLimit else { throw SurfaceError.output }
      view.installingOutput = text as NSString
      let request: [String: Any] = ["version": 1, "renderId": snapshot.renderId,
        "outputUnits": text.utf16.count, "outputBytes": output.size]
      let script = "window.vnotePreview.begin(\(try SurfacePolicy.json(request)))"
      context.webView.evaluateJavaScript(script) { [weak self, weak view, weak context] value, error in
        guard let self = self, let view = view, let context = context,
              view.displayEpoch == epoch, view.context === context else { return }
        guard error == nil, let accepted = value as? NSNumber,
              CFGetTypeID(accepted) == CFBooleanGetTypeID(), accepted.boolValue
        else { self.failDisplay(view, snapshot: snapshot, category: "output_invalid"); return }
        self.appendOutput(snapshot, in: view, context: context, epoch: epoch, offset: 0)
      }
    } catch { failDisplay(view, snapshot: snapshot, category: "output_invalid") }
  }

  private func appendOutput(_ snapshot: SurfaceSnapshot, in view: NativePreviewView,
                            context: SurfaceContext, epoch: UUID, offset: Int) {
    guard attached, !view.closing, view.displayEpoch == epoch, view.context === context,
          view.displayed === snapshot, let text = view.installingOutput else { return }
    do {
      let complete = offset == text.length
      var count = min(32768, text.length - offset)
      let script: String
      if complete { script = "window.vnotePreview.finish()" }
      else {
        // Keep a surrogate pair in one Swift string; the wire still uses UTF16 offsets.
        if offset + count < text.length {
          let last = text.character(at: offset + count - 1)
          if (0xd800...0xdbff).contains(last) { count -= 1 }
        }
        guard count > 0 else { throw SurfaceError.output }
        let chunk = text.substring(with: NSRange(location: offset, length: count))
        let encoded = try SurfacePolicy.json(chunk, maximumBytes: 256 * 1024)
        script = "window.vnotePreview.append(\(offset),\(encoded))"
      }
      let next = offset + count
      context.webView.evaluateJavaScript(script) { [weak self, weak view, weak context] value, error in
        guard let self = self, let view = view, let context = context,
              view.displayEpoch == epoch, view.context === context else { return }
        guard error == nil, let accepted = value as? NSNumber,
              CFGetTypeID(accepted) == CFBooleanGetTypeID(), accepted.boolValue
        else { self.failDisplay(view, snapshot: snapshot, category: "output_invalid"); return }
        if complete {
          view.installingOutput = nil
          self.finishOutputInstall(snapshot, in: view, context: context, epoch: epoch)
        } else { self.appendOutput(snapshot, in: view, context: context, epoch: epoch, offset: next) }
      }
    } catch { failDisplay(view, snapshot: snapshot, category: "output_invalid") }
  }

  private func finishOutputInstall(_ snapshot: SurfaceSnapshot, in view: NativePreviewView,
                                   context: SurfaceContext, epoch: UUID) {
    do {
      let script = "window.vnotePreview.preferences(\(try SurfacePolicy.json(view.preferences)))"
      context.webView.evaluateJavaScript(script) { [weak self, weak view, weak context] _, error in
        guard let self = self, let view = view, let context = context,
              view.displayEpoch == epoch, view.context === context else { return }
        guard error == nil else { self.failDisplay(view, snapshot: snapshot, category: "view_lost"); return }
        view.showTimeout?.cancel(); view.showTimeout = nil
        let result = view.showResult; view.showResult = nil; result?(nil)
        self.pollImages(view, epoch: epoch)
      }
    } catch { failDisplay(view, snapshot: snapshot, category: "view_lost") }
  }

  private func pollImages(_ view: NativePreviewView, epoch: UUID) {
    guard view.displayEpoch == epoch, let context = view.context else { return }
    context.handler.pollAdmissions(context.webView) { [weak self, weak view] in
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self, weak view] in
        if let view = view { self?.pollImages(view, epoch: epoch) }
      }
    }
  }

  private func failDisplay(_ view: NativePreviewView, snapshot: SurfaceSnapshot, category: String) {
    event(["type": "failure", "surfaceId": view.surfaceId, "renderId": snapshot.renderId, "category": category])
    retireDisplay(view) {}
  }

  private func retireDisplay(_ view: NativePreviewView, completion: @escaping () -> Void) {
    view.displayJoined.append(completion)
    guard !view.retiringDisplay else { return }
    view.retiringDisplay = true
    view.retiringRenderId = view.displayed?.renderId
    view.displayEpoch = UUID()
    view.showTimeout?.cancel(); view.showTimeout = nil
    let result = view.showResult; view.showResult = nil
    view.displayed = nil
    view.installingOutput = nil
    let joined = {
      view.retiringDisplay = false; view.retiringRenderId = nil
      if let result = result { self.failure(result) }
      let callbacks = view.displayJoined; view.displayJoined.removeAll()
      for callback in callbacks { callback() }
    }
    if let context = view.context { view.context = nil; context.retire(joined) }
    else { joined() }
  }

  private func close(_ view: NativePreviewView, completion: @escaping () -> Void) {
    view.closing = true
    if let pending = pendingRender, pending.surface === view {
      pendingRender = nil; view.pendingRenderId = nil
      pending.result(["status": "superseded", "renderId": pending.renderId])
    }
    view.completed = nil
    let group = DispatchGroup()
    if let renderer = view.renderer { group.enter(); renderer.cancel { group.leave() } }
    group.enter(); retireDisplay(view) { group.leave() }
    group.notify(queue: .main, execute: completion)
  }

  func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    attached = false
    channel.setMethodCallHandler(nil)
    for editor in editors.values { editor.retire() }; editors.removeAll()
    for view in views.values { if let view = view.value { close(view) {} } }
    views.removeAll()
  }
}
