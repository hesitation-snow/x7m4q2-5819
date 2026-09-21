import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var documentPickerDelegate: DocumentPickerDelegate?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let controller = window?.rootViewController as! FlutterViewController
    let epubChannel = FlutterMethodChannel(
      name: "moe.yutro.yomiru/epub_export",
      binaryMessenger: controller.binaryMessenger
    )

    epubChannel.setMethodCallHandler { [weak self] (call, result) in
      if call.method == "saveDocument" {
        guard let args = call.arguments as? [String: Any],
              let filePath = args["filePath"] as? String else {
          result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing filePath", details: nil))
          return
        }
        let fileUrl = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: fileUrl.path) else {
          result(FlutterError(code: "FILE_NOT_FOUND", message: "Source file not found", details: nil))
          return
        }

        let delegate = DocumentPickerDelegate(result: result)
        self?.documentPickerDelegate = delegate

        if #available(iOS 14.0, *) {
          let picker = UIDocumentPickerViewController(forExporting: [fileUrl], asCopy: true)
          picker.delegate = delegate
          picker.modalPresentationStyle = .formSheet
          controller.present(picker, animated: true, completion: nil)
        } else {
          let picker = UIDocumentPickerViewController(url: fileUrl, in: .exportToService)
          picker.delegate = delegate
          picker.modalPresentationStyle = .formSheet
          controller.present(picker, animated: true, completion: nil)
        }
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

class DocumentPickerDelegate: NSObject, UIDocumentPickerDelegate {
  private var result: FlutterResult?

  init(result: @escaping FlutterResult) {
    self.result = result
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    result?(true)
    result = nil
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    result?(false)
    result = nil
  }
}
