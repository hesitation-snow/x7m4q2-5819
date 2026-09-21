import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var documentPickerDelegate: DocumentPickerDelegate?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    if let registrar = self.registrar(forPlugin: "YomiruEpubExport") {
      let epubChannel = FlutterMethodChannel(
        name: "moe.yutro.yomiru/epub_export",
        binaryMessenger: registrar.messenger()
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

          guard let presentingVC = self?.topViewController() else {
            result(FlutterError(code: "NO_VIEW_CONTROLLER", message: "Cannot find presenting view controller", details: nil))
            return
          }

          let delegate = DocumentPickerDelegate(result: result) { [weak self] in
            self?.documentPickerDelegate = nil
          }
          self?.documentPickerDelegate = delegate

          let picker: UIDocumentPickerViewController
          if #available(iOS 14.0, *) {
            picker = UIDocumentPickerViewController(forExporting: [fileUrl], asCopy: true)
          } else {
            picker = UIDocumentPickerViewController(url: fileUrl, in: .exportToService)
          }
          picker.delegate = delegate
          picker.modalPresentationStyle = .formSheet
          if let popover = picker.popoverPresentationController {
            popover.sourceView = presentingVC.view
            popover.sourceRect = CGRect(x: presentingVC.view.bounds.midX, y: presentingVC.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
          }
          presentingVC.present(picker, animated: true, completion: nil)
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func topViewController() -> UIViewController? {
    var rootVC: UIViewController?
    if #available(iOS 13.0, *) {
      let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      for scene in scenes {
        if let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first {
          rootVC = window.rootViewController
          break
        }
      }
    }
    if rootVC == nil {
      let keyWindow = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) ?? UIApplication.shared.keyWindow
      rootVC = keyWindow?.rootViewController
    }
    var top = rootVC
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }
}

class DocumentPickerDelegate: NSObject, UIDocumentPickerDelegate {
  private var result: FlutterResult?
  private var completion: (() -> Void)?

  init(result: @escaping FlutterResult, completion: (() -> Void)? = nil) {
    self.result = result
    self.completion = completion
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    result?(true)
    result = nil
    completion?()
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    result?(false)
    result = nil
    completion?()
  }
}
