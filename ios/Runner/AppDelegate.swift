import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let registrar = registrar(forPlugin: "YomiruReaderBattery") {
      UIDevice.current.isBatteryMonitoringEnabled = true
      let channel = FlutterMethodChannel(
        name: "moe.yutro.yomiru/reader_battery", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        guard call.method == "level" else {
          result(FlutterMethodNotImplemented)
          return
        }
        let level = UIDevice.current.batteryLevel
        result(level < 0 ? nil : Int((level * 100).rounded()))
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
