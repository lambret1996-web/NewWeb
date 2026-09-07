import Flutter
import UIKit
import WebKit
import QuickLook

/// 原生能力桥：缓存管理 / 内容拦截器 / 下载管理 / 文件预览 / DNS 描述文件。
/// 事件通道（com.newweb/native_events）推送下载进度与长按菜单动作。
public class NativeBridgePlugin: NSObject, FlutterPlugin, QLPreviewControllerDataSource {
  private var eventSink: FlutterEventSink?
  private var previewURL: URL?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "com.newweb/native",
      binaryMessenger: registrar.messenger()
    )
    let events = FlutterEventChannel(
      name: "com.newweb/native_events",
      binaryMessenger: registrar.messenger()
    )
    let instance = NativeBridgePlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
    events.setStreamHandler(instance)

    ContentBlockerManager.shared.onMenuAction = { [weak instance] action, payload in
      instance?.sendEvent(action, payload)
    }
    DownloadManager.shared.onEvent = { [weak instance] event, payload in
      instance?.sendEvent("download_\(event)", payload)
    }
  }

  private func sendEvent(_ name: String, _ payload: [String: Any]) {
    var dict = payload
    dict["event"] = name
    eventSink?(dict)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any] else {
      if call.method == "getCacheSize" || call.method == "clearWebData" || call.method == "generateDNSProfile" {
        handleNoArg(call, result: result)
        return
      }
      result(FlutterMethodNotImplemented)
      return
    }
    switch call.method {
    case "injectContentBlocker":
      let rules = args["rules"] as? String ?? "[]"
      ContentBlockerManager.shared.inject(rulesJson: rules) { ok in
        result(ok)
      }
    case "startDownload":
      DownloadManager.shared.start(
        url: args["url"] as? String ?? "",
        taskId: args["taskId"] as? String ?? ""
      )
      result(true)
    case "pauseDownload":
      DownloadManager.shared.pause(taskId: args["taskId"] as? String ?? "")
      result(true)
    case "resumeDownload":
      DownloadManager.shared.resume(
        taskId: args["taskId"] as? String ?? "",
        url: args["url"] as? String ?? ""
      )
      result(true)
    case "cancelDownload":
      DownloadManager.shared.cancel(taskId: args["taskId"] as? String ?? "")
      result(true)
    case "previewFile":
      previewFile(path: args["path"] as? String ?? "")
      result(true)
    case "captureSnapshot":
      captureSnapshot(url: args["url"] as? String ?? "", result: result)
    case "shareUrl":
      shareUrl(
        url: args["url"] as? String ?? "",
        title: args["title"] as? String ?? "",
        result: result
      )
    case "hapticFeedback":
      hapticFeedback(style: args["style"] as? String ?? "medium")
      result(nil)
    case "setDarkMode":
      let dark = args["dark"] as? Bool ?? false
      setWebViewDarkMode(dark: dark)
      result(nil)
    case "clearWebDataTypes":
      let types = args["types"] as? [String] ?? []
      clearWebDataTypes(types, result: result)
    case "getWebDataRecordCount":
      getWebDataRecordCount(result: result)
    case "clearHttpCache":
      URLCache.shared.removeAllCachedResponses()
      clearCachesDirectory()
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func handleNoArg(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "clearWebData":
      clearWebData(result: result)
    case "getCacheSize":
      getCacheSize(result: result)
    case "generateDNSProfile":
      result(generateDNSProfile())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - 缓存管理

  private func clearWebData(result: @escaping FlutterResult) {
    let store = WKWebsiteDataStore.default()
    store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
      store.removeData(
        ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
        for: records
      ) {
        URLCache.shared.removeAllCachedResponses()
        self.clearCachesDirectory()
        result(true)
      }
    }
  }

  private func getCacheSize(result: @escaping FlutterResult) {
    result(cacheDirectorySize())
  }

  /// 按指定类型清空网站数据。
  private func clearWebDataTypes(
    _ types: [String],
    result: @escaping FlutterResult
  ) {
    guard !types.isEmpty else {
      result(true)
      return
    }
    let typeSet = Set(types)
    let store = WKWebsiteDataStore.default()
    store.fetchDataRecords(ofTypes: typeSet) { records in
      store.removeData(ofTypes: typeSet, for: records) {
        result(true)
      }
    }
  }

  /// 网站数据记录总数。
  private func getWebDataRecordCount(result: @escaping FlutterResult) {
    let store = WKWebsiteDataStore.default()
    store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
      result(records.count)
    }
  }

  private func cacheDirectorySize() -> Int {
    guard let caches = FileManager.default.urls(
      for: .cachesDirectory, in: .userDomainMask
    ).first else { return 0 }
    let enumerator = FileManager.default.enumerator(
      at: caches,
      includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]
    )
    var total: Int64 = 0
    while let url = enumerator?.nextObject() as? URL {
      guard let values = try? url.resourceValues(
        forKeys: [.fileSizeKey, .isDirectoryKey]
      ) else { continue }
      if values.isDirectory == true { continue }
      if let size = values.fileSize {
        total += Int64(size)
      }
    }
    return Int(total)
  }

  private func clearCachesDirectory() {
    guard let caches = FileManager.default.urls(
      for: .cachesDirectory, in: .userDomainMask
    ).first else { return }
    let enumerator = FileManager.default.enumerator(
      at: caches,
      includingPropertiesForKeys: [.isDirectoryKey]
    )
    while let url = enumerator?.nextObject() as? URL {
      guard let values = try? url.resourceValues(
        forKeys: [.isDirectoryKey]
      ) else { continue }
      if values.isDirectory == true { continue }
      try? FileManager.default.removeItem(at: url)
    }
  }

  // MARK: - 文件预览（QLPreviewController）

  private func previewFile(path: String) {
    previewURL = URL(fileURLWithPath: path)
    let preview = QLPreviewController()
    preview.dataSource = self
    topViewController()?.present(preview, animated: true)
  }

  public func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
    previewURL == nil ? 0 : 1
  }

  public func previewController(
    _ controller: QLPreviewController,
    previewItemAt index: Int
  ) -> QLPreviewItem {
    (previewURL ?? URL(fileURLWithPath: "/")) as NSURL
  }

  private func topViewController(
    base: UIViewController? = nil
  ) -> UIViewController? {
    let keyWindow = UIApplication.shared.windows.first { $0.isKeyWindow }
    let root = base ?? keyWindow?.rootViewController
    if let nav = root as? UINavigationController {
      return topViewController(base: nav.visibleViewController)
    }
    if let tab = root as? UITabBarController {
      return topViewController(base: tab.selectedViewController)
    }
    if let presented = root?.presentedViewController {
      return topViewController(base: presented)
    }
    return root
  }

  // MARK: - 分享

  private func shareUrl(url: String, title: String, result: @escaping FlutterResult) {
    guard let urlObj = URL(string: url) else {
      result(FlutterError(code: "INVALID_URL", message: "无效的链接", details: nil))
      return
    }
    var items: [Any] = [urlObj]
    if !title.isEmpty {
      items.insert(title, at: 0)
    }
    let activityVC = UIActivityViewController(activityItems: items, applicationActivities: nil)
    activityVC.completionWithItemsHandler = { _, _, _, _ in
      result(nil)
    }
    DispatchQueue.main.async {
      guard let root = self.keyWindow()?.rootViewController else {
        result(FlutterError(code: "NO_VC", message: "无法显示分享面板", details: nil))
        return
      }
      var top = root
      while let presented = top.presentedViewController {
        top = presented
      }
      if let popover = activityVC.popoverPresentationController {
        popover.sourceView = top.view
        popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY, width: 0, height: 0)
        popover.permittedArrowDirections = []
      }
      top.present(activityVC, animated: true)
    }
  }

  private func hapticFeedback(style: String) {
    DispatchQueue.main.async {
      let generator: UIImpactFeedbackGenerator
      switch style {
      case "light":
        generator = UIImpactFeedbackGenerator(style: .light)
      case "heavy":
        generator = UIImpactFeedbackGenerator(style: .heavy)
      case "success":
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        return
      case "warning":
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        return
      case "error":
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        return
      default:
        generator = UIImpactFeedbackGenerator(style: .medium)
      }
      generator.impactOccurred()
    }
  }

  /// 设置所有 WKWebView 的底色（防止深色模式加载间隙/弹性区域白闪）。
  /// 注意：不使用 overrideUserInterfaceStyle（会导致部分网页整页变黑），
  /// 网页内容深色由 Dart 层注入 CSS 完成。
  private func setWebViewDarkMode(dark: Bool) {
    DispatchQueue.main.async {
      for scene in UIApplication.shared.connectedScenes {
        guard let windowScene = scene as? UIWindowScene else { continue }
        for window in windowScene.windows {
          self.setDarkMode(in: window, dark: dark)
        }
      }
    }
  }

  private func setDarkMode(in view: UIView, dark: Bool) {
    if let wv = view as? WKWebView {
      let bg = dark ? UIColor(red: 15/255.0, green: 17/255.0, blue: 21/255.0, alpha: 1) : UIColor(red: 245/255.0, green: 246/255.0, blue: 248/255.0, alpha: 1)
      wv.isOpaque = false
      wv.backgroundColor = bg
      wv.scrollView.backgroundColor = bg
    }
    for sub in view.subviews {
      setDarkMode(in: sub, dark: dark)
    }
  }

  private func keyWindow() -> UIWindow? {
    for scene in UIApplication.shared.connectedScenes {
      guard let windowScene = scene as? UIWindowScene else { continue }
      for window in windowScene.windows where window.isKeyWindow {
        return window
      }
    }
    return nil
  }

  // MARK: - 标签快照（截取 WKWebView 快照）

  /// 截取目标标签快照：优先按 URL 匹配，其次取可见 WebView。
  /// 自带重试（最多 2 次，间隔 500ms），PNG 写入沙盒 Caches/Snapshots，返回 {path, url}。
  private func captureSnapshot(url: String, result: @escaping FlutterResult) {
    captureSnapshotWithRetry(url: url, result: result, attempts: 0)
  }

  private func captureSnapshotWithRetry(
    url: String,
    result: @escaping FlutterResult,
    attempts: Int
  ) {
    guard let webView = findWebView(for: url) else {
      if attempts < 2 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
          self?.captureSnapshotWithRetry(url: url, result: result, attempts: attempts + 1)
        }
      } else {
        result(nil)
      }
      return
    }
    webView.takeSnapshot(with: nil) { [weak self] image, error in
      guard let self = self else { return }
      // 截图失败或图片过空白（平均亮度接近白），重试
      let isBlank = image == nil || self._isBlankImage(image!)
      if (error != nil || image == nil || isBlank), attempts < 2 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
          self?.captureSnapshotWithRetry(url: url, result: result, attempts: attempts + 1)
        }
        return
      }
      guard let image = image, let data = image.pngData() else {
        result(nil)
        return
      }
      guard let dir = FileManager.default.urls(
        for: .cachesDirectory, in: .userDomainMask
      ).first?.appendingPathComponent("Snapshots", isDirectory: true) else {
        result(nil)
        return
      }
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let file = dir.appendingPathComponent("snapshot_\(Int(Date().timeIntervalSince1970)).png")
      do {
        try data.write(to: file)
        result(["path": file.path, "url": webView.url?.absoluteString ?? ""])
      } catch {
        result(nil)
      }
    }
  }

  /// 检测图片是否为空白（平均亮度 > 245 视为空白）。
  private func _isBlankImage(_ image: UIImage) -> Bool {
    guard let cgImage = image.cgImage else { return false }
    let width = 8, height = 8
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    var rawData = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
      data: &rawData,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return false }
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    var totalBrightness = 0
    for i in stride(from: 0, to: rawData.count, by: 4) {
      totalBrightness += Int(rawData[i]) + Int(rawData[i + 1]) + Int(rawData[i + 2])
    }
    let avg = Double(totalBrightness) / Double(width * height * 3)
    return avg > 245
  }

  /// 查找目标 WKWebView：URL 精确/前缀匹配优先，其次取可见 WebView。
  /// 使用 connectedScenes 找 keyWindow（兼容 iOS 15+）。
  private func findWebView(for url: String) -> WKWebView? {
    var visibleFallback: WKWebView?
    let target = url.lowercased()
    let scenes = UIApplication.shared.connectedScenes
    for scene in scenes {
      guard let windowScene = scene as? UIWindowScene else { continue }
      for window in windowScene.windows {
        if !window.isKeyWindow { continue }
        if let found = self.matchWebView(in: window, target: target, fallback: &visibleFallback) {
          return found
        }
      }
    }
    // 兜底：遍历所有 window
    if visibleFallback == nil {
      for scene in scenes {
        guard let windowScene = scene as? UIWindowScene else { continue }
        for window in windowScene.windows {
          if let found = self.matchWebView(in: window, target: target, fallback: &visibleFallback) {
            return found
          }
        }
      }
    }
    return visibleFallback
  }

  private func matchWebView(
    in view: UIView,
    target: String,
    fallback: inout WKWebView?
  ) -> WKWebView? {
    if let wv = view as? WKWebView {
      // 放宽可见性判断：只要不在隐藏层级中且有尺寸
      if !wv.isHidden && wv.frame.width > 0 && wv.frame.height > 0 {
        if fallback == nil { fallback = wv }
        if !target.isEmpty,
           let current = wv.url?.absoluteString.lowercased(),
           current == target || current.hasPrefix(target) || target.hasPrefix(current) {
          return wv
        }
      }
      return nil
    }
    for sub in view.subviews {
      if let found = matchWebView(in: sub, target: target, fallback: &fallback) {
        return found
      }
    }
    return nil
  }

  // MARK: - DNS 描述文件（AdGuard DNS）

  private func generateDNSProfile() -> String? {
    let uuid1 = UUID().uuidString
    let uuid2 = UUID().uuidString
    let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>PayloadContent</key>
      <array>
        <dict>
          <key>PayloadDescription</key>
          <string>将系统 DNS 配置为 AdGuard DNS（广告与追踪拦截）</string>
          <key>PayloadDisplayName</key>
          <string>AdGuard DNS</string>
          <key>PayloadIdentifier</key>
          <string>com.newweb.dns.adguard</string>
          <key>PayloadType</key>
          <string>com.apple.dnsSettings.managed</string>
          <key>PayloadUUID</key>
          <string>\(uuid1)</string>
          <key>PayloadVersion</key>
          <integer>1</integer>
          <key>ProxiedContentFilterRules</key>
          <array>
            <dict>
              <key>ProviderBundleIdentifier</key>
              <string>com.apple.SystemConfiguration.dns-settings</string>
            </dict>
          </array>
          <key>ServerName</key>
          <string>AdGuard DNS</string>
          <key>DNSSettings</key>
          <dict>
            <key>DNSProtocol</key>
            <string>HTTPS</string>
            <key>ServerURL</key>
            <string>https://dns.adguard-dns.com/dns-query</string>
          </dict>
        </dict>
      </array>
      <key>PayloadDisplayName</key>
      <string>AdGuard DNS 配置</string>
      <key>PayloadIdentifier</key>
      <string>com.newweb.dns</string>
      <key>PayloadType</key>
      <string>Configuration</string>
      <key>PayloadUUID</key>
      <string>\(uuid2)</string>
      <key>PayloadVersion</key>
      <integer>1</integer>
    </dict>
    </plist>
    """
    let dir = FileManager.default
      .urls(for: .documentDirectory, in: .userDomainMask).first!
      .appendingPathComponent("DNS", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("AdGuardDNS_配置.mobileconfig")
    do {
      try xml.write(to: file, atomically: true, encoding: .utf8)
      return file.path
    } catch {
      return nil
    }
  }
}

extension NativeBridgePlugin: FlutterStreamHandler {
  public func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }
}
