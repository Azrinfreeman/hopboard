import Flutter
import UIKit
import Security

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var privacyCovers: [UIView] = []
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
      guard let self = self else { return }
      self.privacyCovers.forEach { $0.removeFromSuperview() }
      self.privacyCovers = []
      let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
      for window in windows where window.isKeyWindow {
        let cover = UIView(frame: window.bounds)
        cover.backgroundColor = .systemBackground
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let label = UILabel(frame: cover.bounds)
        label.text = "LocalClipboard"
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 22, weight: .semibold)
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.addSubview(label)
        window.addSubview(cover)
        self.privacyCovers.append(cover)
      }
    }
    NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
      self?.privacyCovers.forEach { $0.removeFromSuperview() }
      self?.privacyCovers = []
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "LocalClipboardNative")!
    let channel = FlutterMethodChannel(name: "dev.localclipboard/native", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "secureDelete":
        guard let args = call.arguments as? [String: Any], let key = args["key"] as? String,
              ["identity.v1", "trust.v1"].contains(key) else {
          result(FlutterError(code: "storage", message: "Invalid storage key.", details: nil)); return
        }
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword,
          kSecAttrService as String: "dev.localclipboard.v1", kSecAttrAccount as String: key] as CFDictionary)
        result(status == errSecSuccess || status == errSecItemNotFound ? nil
          : FlutterError(code: "storage", message: "Could not remove private storage.", details: nil))
      case "secureRead", "secureWrite":
        guard let args = call.arguments as? [String: Any], let key = args["key"] as? String,
              ["identity.v1", "trust.v1"].contains(key) else {
          result(FlutterError(code: "storage", message: "Invalid storage key.", details: nil)); return
        }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
          kSecAttrService as String: "dev.localclipboard.v1", kSecAttrAccount as String: key]
        if call.method == "secureRead" {
          var readQuery = query
          readQuery[kSecReturnData as String] = true
          readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
          var item: CFTypeRef?
          let status = SecItemCopyMatching(readQuery as CFDictionary, &item)
          if status == errSecItemNotFound { result(nil) }
          else if status == errSecSuccess, let data = item as? Data,
                  let value = String(data: data, encoding: .utf8) { result(value) }
          else { result(FlutterError(code: "storage", message: "Private storage is unavailable.", details: nil)) }
        } else {
          guard let value = args["value"] as? String, value.utf8.count <= 262144 else {
            result(FlutterError(code: "storage", message: "Invalid storage value.", details: nil)); return
          }
          let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
          var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
          if status == errSecItemNotFound {
            var addQuery = query
            attributes.forEach { addQuery[$0.key] = $0.value }
            status = SecItemAdd(addQuery as CFDictionary, nil)
          }
          result(status == errSecSuccess ? nil : FlutterError(code: "storage", message: "Could not save private storage.", details: nil))
        }
      case "initialize": result(nil)
      case "keepAwake":
        UIApplication.shared.isIdleTimerDisabled = call.arguments as? Bool ?? false
        result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
    registrar.register(LocalPasteFactory(channel: channel), withId: "dev.localclipboard/paste")
  }
}

class LocalPasteFactory: NSObject, FlutterPlatformViewFactory {
  let channel: FlutterMethodChannel
  init(channel: FlutterMethodChannel) { self.channel = channel; super.init() }
  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    LocalPasteView(frame: frame, channel: channel)
  }
}

class LocalPasteTarget: UITextView {
  var channel: FlutterMethodChannel?
  override func paste(itemProviders: [NSItemProvider]) {
    guard let provider = itemProviders.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return }
    provider.loadObject(ofClass: NSString.self) { [weak self] object, _ in
      guard let text = object as? String, text.utf8.count <= 65536 else { return }
      DispatchQueue.main.async { self?.channel?.invokeMethod("pasted", arguments: text) }
    }
  }
}

class LocalPasteView: NSObject, FlutterPlatformView {
  private let container: UIView
  private let target = LocalPasteTarget()
  init(frame: CGRect, channel: FlutterMethodChannel) {
    container = UIView(frame: frame)
    super.init()
    target.channel = channel
    target.pasteConfiguration = UIPasteConfiguration(forAccepting: NSString.self)
    target.isEditable = true
    target.frame = .zero
    container.addSubview(target)
    if #available(iOS 16.0, *) {
      let configuration = UIPasteControl.Configuration()
      configuration.displayMode = .iconAndLabel
      configuration.baseBackgroundColor = UIColor(red: 0.39, green: 0.36, blue: 0.91, alpha: 1)
      configuration.cornerStyle = .capsule
      let paste = UIPasteControl(configuration: configuration)
      paste.target = target
      paste.frame = container.bounds
      paste.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      container.addSubview(paste)
    }
  }
  func view() -> UIView { container }
}
