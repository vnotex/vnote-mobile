import UIKit
import UniformTypeIdentifiers

// No Flutter engine, core, or notebook access in this target.
final class ShareViewController: UIViewController {
  private let worker = DispatchQueue(label: "vnote.share.capture", qos: .userInitiated)
  private let label = UILabel()
  private let close = UIButton(type: .system)
  private var started = false
  private var terminalError: Error?
  private lazy var chinese: Bool = {
    var choice = "system"
    if let group = ShareInbox.configuredGroup,
       let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group),
       let data = try? ShareInbox.readData(container.resolvingSymlinksInPath()
         .appendingPathComponent("inbox/locale"), maximum: 16),
       let stored = String(data: data, encoding: .utf8), ["system", "en", "zh"].contains(stored) {
      choice = stored
    }
    return choice == "zh" || (choice == "system" && Locale.preferredLanguages.first?.hasPrefix("zh") == true)
  }()
  private func text(_ en: String, _ zh: String) -> String { chinese ? zh : en }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    label.text = text("Receiving shared items…", "正在接收分享内容…")
    label.font = .preferredFont(forTextStyle: .body)
    label.adjustsFontForContentSizeCategory = true
    label.numberOfLines = 0
    label.accessibilityTraits.insert(.updatesFrequently)
    close.setTitle(text("Close", "关闭"), for: .normal)
    close.titleLabel?.font = .preferredFont(forTextStyle: .headline)
    close.titleLabel?.adjustsFontForContentSizeCategory = true
    close.addTarget(self, action: #selector(closeFailure), for: .touchUpInside)
    close.isHidden = true
    let stack = UIStackView(arrangedSubviews: [label, close])
    stack.axis = .vertical; stack.spacing = 24; stack.translatesAutoresizingMaskIntoConstraints = false
    let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(scroll); scroll.addSubview(stack)
    NSLayoutConstraint.activate([
      scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
      scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
      stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24),
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 24),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
      stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48),
      close.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
    ])
  }
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !started else { return }; started = true
    let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
    // Preserve provider and attachment order: it is part of the fingerprint.
    let providers = items.flatMap { $0.attachments ?? [] }
    let content = items.compactMap { item -> String? in
      (item.attachments?.isEmpty ?? true) ? item.attributedContentText?.string : nil
    }
    worker.async {
      var inbox: ShareInbox?; var capture: ShareInbox.Capture?
      do {
        guard providers.count <= 64, providers.count > 0 || !content.isEmpty else { throw ShareInboxError.invalid }
        let store = try ShareInbox.configured(); inbox = store
        let incoming = try store.beginCapture(); capture = incoming
        for value in content { try store.appendText(value, to: incoming) }
        for provider in providers { try self.load(provider, inbox: store, capture: incoming) }
        _ = try store.finishCapture(incoming)
        DispatchQueue.main.async {
          self.label.text = self.text("Received. Open VNote to import these items.", "已接收。请打开 VNote 导入这些内容。")
          UIAccessibility.post(notification: .announcement, argument: self.label.text)
          // This is the only success path; every file, manifest and receipt is durable.
          self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
      } catch {
        if let store = inbox, let incoming = capture { store.abortCapture(incoming) }
        DispatchQueue.main.async { self.fail(error) }
      }
    }
  }

  private func load(_ provider: NSItemProvider, inbox: ShareInbox, capture: ShareInbox.Capture) throws {
    // Only actual text/URL providers become text. Images and opaque files are
    // always file representations; no image decoding or unbounded loadData call.
    let type: String
    let asText: Bool
    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
      type = UTType.fileURL.identifier
      asText = false
    } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
      type = UTType.url.identifier; asText = true
    } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
      type = UTType.plainText.identifier; asText = true
    } else {
      guard let identifier = provider.registeredTypeIdentifiers.first(where: {
        UTType($0)?.conforms(to: .data) == true
      }) else { throw ShareInboxError.invalid }
      type = identifier; asText = false
    }
    let done = DispatchSemaphore(value: 0)
    let resultLock = NSLock(); var failure: Error?
    func finish(_ error: Error?) { resultLock.lock(); failure = error; resultLock.unlock(); done.signal() }
    if asText {
      provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
        do {
          guard error == nil else { throw ShareInboxError.unavailable }
          let value: String
          if let url = item as? URL, type == UTType.url.identifier { value = url.absoluteString }
          else if let string = item as? String { value = string }
          else if let data = item as? Data, data.count <= ShareInbox.maximumText,
                  let string = String(data: data, encoding: .utf8) { value = string }
          else { throw ShareInboxError.invalid }
          try inbox.appendText(value, to: capture); finish(nil)
        } catch { finish(error) }
      }
    } else if type == UTType.fileURL.identifier {
      provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
        do {
          guard error == nil, let url = item as? URL, url.isFileURL else { throw ShareInboxError.unavailable }
          let name = provider.suggestedName ?? url.lastPathComponent
          let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
          try inbox.appendFile(url, name: name, mime: mime, to: capture); finish(nil)
        } catch { finish(error) }
      }
    } else {
      provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
        do {
          guard error == nil, let url = url, url.isFileURL else { throw ShareInboxError.unavailable }
          let name = provider.suggestedName ?? url.lastPathComponent
          let mime = UTType(type)?.preferredMIMEType ?? "application/octet-stream"
          // The provider owns this temporary URL only until this callback ends.
          try inbox.appendFile(url, name: name, mime: mime, to: capture); finish(nil)
        } catch { finish(error) }
      }
    }
    done.wait() // Never on the main queue; no URL escapes its provider callback.
    resultLock.lock(); let error = failure; resultLock.unlock()
    if let error = error { throw error }
  }
  private func fail(_ error: Error) {
    terminalError = error
    switch error {
    case ShareInboxError.unavailable, ShareInboxError.inactive:
      label.text = text("Sharing is unavailable. Open VNote to activate the inbox. An owner-configured App Group is required.",
                        "分享不可用。请打开 VNote 启用收件箱。此功能需要所有者配置 App Group。")
    case ShareInboxError.capacity, ShareInboxError.busy:
      label.text = text("Nothing was received. The inbox is full or busy. Open VNote to manage retained items and try again.",
                        "未接收任何内容。收件箱已满或正忙。请打开 VNote 管理保留的内容后重试。")
    default:
      label.text = text("Nothing was received. A file could not be copied safely. Keep the originals and try again.",
                        "未接收任何内容。无法安全复制文件。请保留原始文件并重试。")
    }
    close.isHidden = false
    UIAccessibility.post(notification: .announcement, argument: label.text)
  }
  @objc private func closeFailure() {
    guard terminalError != nil else { return }
    extensionContext?.cancelRequest(withError: NSError(domain: "vnote.share", code: 1,
      userInfo: [NSLocalizedDescriptionKey: text("Nothing was received.", "未接收任何内容。")]))
  }
}
