import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var secureOverlay: UIView?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Watch for screen recording / AirPlay mirroring and blank the UI while active.
    NotificationCenter.default.addObserver(
      self, selector: #selector(handleCaptureChange),
      name: UIScreen.capturedDidChangeNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(handleCaptureChange),
      name: UIApplication.didBecomeActiveNotification, object: nil)
    DispatchQueue.main.async { self.handleCaptureChange() }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }

  // iOS cannot prevent screen capture the way Android's FLAG_SECURE does, so while
  // the screen is being recorded or mirrored we cover all content with an opaque
  // notice — the recording/mirror then shows nothing usable. Removed when capture
  // stops. This is the iOS equivalent of the app-wide recording block.
  @objc private func handleCaptureChange() {
    let captured = UIScreen.main.isCaptured
    guard let window = self.window ?? UIApplication.shared.windows.first else { return }
    if captured {
      if secureOverlay == nil {
        let overlay = UIView(frame: window.bounds)
        overlay.backgroundColor = .black
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let label = UILabel()
        label.text = "Screen recording is not allowed"
        label.textColor = .white
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(label)
        NSLayoutConstraint.activate([
          label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
          label.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
          label.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 24),
          label.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -24),
        ])
        window.addSubview(overlay)
        secureOverlay = overlay
      }
      window.bringSubviewToFront(secureOverlay!)
    } else {
      secureOverlay?.removeFromSuperview()
      secureOverlay = nil
    }
  }
}
