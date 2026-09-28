import AVFoundation
import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  // The app's sounds, each prepared once so every play starts at once.
  private var players: [String: AVAudioPlayer] = [:]

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // Wide enough for the setup rail beside the results; never so small that
    // the two stop making sense.
    self.setContentSize(NSSize(width: 1280, height: 820))
    self.contentMinSize = NSSize(width: 960, height: 640)
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

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

    super.awakeFromNib()
  }
}
