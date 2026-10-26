import AVFoundation
import Cocoa
import FlutterMacOS
import UserNotifications

class MainFlutterWindow: NSWindow {
  // The app's sounds, each prepared once so every play starts at once.
  private var players: [String: AVAudioPlayer] = [:]

  // Where the app hears about the window: moving it, full screen.
  private var windowChannel: FlutterMethodChannel?

  // Held while a class is marked in the background: the Mac does not sleep.
  private var activity: NSObjectProtocol?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // Wide enough for the setup rail beside the results; never so small that
    // the two stop making sense.
    self.setContentSize(NSSize(width: 1280, height: 820))
    self.contentMinSize = NSSize(width: 960, height: 640)
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    // The app draws its own title bar: its content runs up under a
    // transparent one, and the window's buttons sit above the rail. The
    // app's floating bars move the window when dragged and zoom it when
    // double-clicked, through the channel below.
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    self.styleMask.insert(.fullSizeContentView)

    let window = FlutterMethodChannel(
      name: "exam_corrector/window",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    window.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      switch call.method {
      case "startDrag":
        if let event = NSApp.currentEvent {
          self.performDrag(with: event)
        }
        result(nil)
      case "isFullScreen":
        result(self.styleMask.contains(.fullScreen))
      case "zoom":
        // Double-clicking a title bar does what the teacher chose in
        // System Settings: zoom, or minimise.
        if UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") == "Minimize" {
          self.performMiniaturize(nil)
        } else {
          self.performZoom(nil)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // Dart hands over the sounds once ("load", name to bytes), then asks for
    // one by name ("play").
    let sound = FlutterMethodChannel(
      name: "exam_corrector/sound",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    sound.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "load":
        if let sounds = call.arguments as? [String: FlutterStandardTypedData] {
          var loaded: [String: AVAudioPlayer] = [:]
          for (name, bytes) in sounds {
            if let player = try? AVAudioPlayer(data: bytes.data) {
              player.prepareToPlay()
              loaded[name] = player
            }
          }
          self?.players = loaded
        }
        result(nil)
      case "play":
        if let name = call.arguments as? String, let player = self?.players[name] {
          player.currentTime = 0
          player.play()
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // Background marking: keep the Mac awake, show progress on the Dock
    // icon, and say when it is done.
    let background = FlutterMethodChannel(
      name: "exam_corrector/background",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    background.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "keepAwake":
        let on = (call.arguments as? Bool) ?? false
        if on, self?.activity == nil {
          self?.activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: "Marklume is marking a class")
        } else if !on, let held = self?.activity {
          ProcessInfo.processInfo.endActivity(held)
          self?.activity = nil
        }
        result(nil)
      case "badge":
        NSApp.dockTile.badgeLabel = call.arguments as? String
        result(nil)
      case "isActive":
        result(NSApp.isActive)
      case "requestNotifications":
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
          DispatchQueue.main.async { result(granted) }
        }
      case "notify":
        let args = call.arguments as? [String: String] ?? [:]
        let content = UNMutableNotificationContent()
        content.title = args["title"] ?? "Marklume"
        content.body = args["body"] ?? ""
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    self.windowChannel = window

    // In full screen the system hides the window's buttons, and the rail
    // gives their room back; it hears as the change begins.
    NotificationCenter.default.addObserver(
      forName: NSWindow.willEnterFullScreenNotification, object: self, queue: .main
    ) { [weak self] _ in self?.windowChannel?.invokeMethod("fullScreen", arguments: true) }
    NotificationCenter.default.addObserver(
      forName: NSWindow.willExitFullScreenNotification, object: self, queue: .main
    ) { [weak self] _ in self?.windowChannel?.invokeMethod("fullScreen", arguments: false) }

    // AppKit puts the buttons back wherever it lays out the title bar again.
    for name in [
      NSWindow.didResizeNotification,
      NSWindow.didExitFullScreenNotification,
      NSWindow.didBecomeKeyNotification,
      NSWindow.didResignKeyNotification,
    ] {
      NotificationCenter.default.addObserver(
        forName: name, object: self, queue: .main
      ) { [weak self] _ in self?.placeWindowButtons() }
    }

    super.awakeFromNib()
    placeWindowButtons()
  }

  // Where the window's buttons sit: across the top of the rail (10 in from
  // the window's edge, 70 wide), on the centre line of the app's floating
  // bars (10 down, 46 tall) — AppTheme.floatInset, railWidth and barHeight.
  private static let buttonsCentreX: CGFloat = 45
  private static let buttonsCentreY: CGFloat = 33

  /// Moves the close, minimise and zoom buttons into the top of the rail.
  private func placeWindowButtons() {
    guard !styleMask.contains(.fullScreen),
          let close = standardWindowButton(.closeButton),
          let minimise = standardWindowButton(.miniaturizeButton),
          let zoom = standardWindowButton(.zoomButton),
          let titleBar = close.superview?.superview
    else { return }
    let size = close.frame.size
    let spacing = minimise.frame.minX - close.frame.minX
    // The title bar grows just enough to hold the buttons there.
    let height = Self.buttonsCentreY + size.height / 2 + 4
    var bar = titleBar.frame
    bar.size.height = height
    bar.origin.y = frame.height - height
    titleBar.frame = bar
    let left = (Self.buttonsCentreX - (2 * spacing + size.width) / 2).rounded()
    let bottom = (height - Self.buttonsCentreY - size.height / 2).rounded()
    for (index, button) in [close, minimise, zoom].enumerated() {
      button.setFrameOrigin(NSPoint(x: left + CGFloat(index) * spacing, y: bottom))
    }
  }
}
