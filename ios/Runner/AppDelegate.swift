import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var documentPickerDelegate: DocumentPickerDelegate?
  private var ttsHandler: ReaderTtsHandler?

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

    if let registrar = self.registrar(forPlugin: "YomiruTts") {
      let ttsChannel = FlutterMethodChannel(
        name: "moe.yutro.yomiru/tts",
        binaryMessenger: registrar.messenger()
      )
      let handler = ReaderTtsHandler(channel: ttsChannel)
      self.ttsHandler = handler
      ttsChannel.setMethodCallHandler { [weak handler] (call, result) in
        guard let handler = handler else {
          result(FlutterError(code: "TTS_DISPOSED", message: "TTS handler released", details: nil))
          return
        }
        handler.handle(call, result: result)
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

private final class ReaderTtsHandler: NSObject, AVSpeechSynthesizerDelegate {
  static let defaultEngineId = "com.apple.speech.synthesis"
  static let defaultEngineLabel = "Apple 系统语音"

  private let channel: FlutterMethodChannel
  private let liveSynthesizer = AVSpeechSynthesizer()

  private var selectedLocale: String?
  private var selectedVoiceId: String?
  private var selectedRate: Double = 1.0

  private var activeLiveUtteranceId: String?
  private var utteranceIds: [ObjectIdentifier: String] = [:]
  private var activeSynthesisJob: FileSynthesisJob?

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
    self.liveSynthesizer.delegate = self
    self.liveSynthesizer.usesApplicationAudioSession = true
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "requestNotificationPermission":
      result(true)
    case "getEngines":
      result([
        [
          "name": Self.defaultEngineId,
          "label": Self.defaultEngineLabel,
          "isSystem": true,
        ],
      ])
    case "setEngine":
      guard let args = call.arguments as? [String: Any],
            let engineId = (args["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !engineId.isEmpty else {
        result(FlutterError(code: "INVALID_ENGINE", message: "Missing engine id", details: nil))
        return
      }
      if engineId == "default" || engineId == Self.defaultEngineId {
        result(true)
      } else {
        result(FlutterError(code: "ENGINE_NOT_FOUND", message: "Unknown engine id: \(engineId)", details: nil))
      }
    case "getVoices":
      let voices = sortedVoices().map { voice -> [String: Any] in
        [
          "id": voice.identifier,
          "voiceId": voice.identifier,
          "name": voice.name,
          "locale": voice.language,
          "engine": Self.defaultEngineId,
          "networkRequired": false,
        ]
      }
      result(voices)
    case "setLanguage":
      let args = call.arguments as? [String: Any]
      let locale = (args?["locale"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !locale.isEmpty, let voice = findVoice(forLocale: locale) else {
        result(FlutterError(code: "INVALID_LOCALE", message: "Unsupported locale: \(locale)", details: nil))
        return
      }
      selectedLocale = voice.language
      selectedVoiceId = nil
      result(["status": 0, "available": true])
    case "setVoice":
      let args = call.arguments as? [String: Any]
      let voiceId = (args?["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !voiceId.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: voiceId) else {
        result(FlutterError(code: "VOICE_NOT_FOUND", message: "Voice not found: \(voiceId)", details: nil))
        return
      }
      selectedVoiceId = voice.identifier
      selectedLocale = voice.language
      result(true)
    case "setSpeechRate":
      let args = call.arguments as? [String: Any]
      guard let rate = parseDouble(args?["rate"]), rate.isFinite, rate > 0 else {
        result(FlutterError(code: "INVALID_RATE", message: "Invalid speech rate", details: nil))
        return
      }
      selectedRate = rate
      result(true)
    case "speak":
      handleSpeak(call, result: result)
    case "synthesizeToFile":
      handleSynthesizeToFile(call, result: result)
    case "pause", "stop":
      stopAll()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func handleSpeak(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    let text = args?["text"] as? String ?? ""
    let utteranceId = (args?["utteranceId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      result(FlutterError(code: "INVALID_TEXT", message: "Empty speech text", details: nil))
      return
    }
    guard !utteranceId.isEmpty else {
      result(FlutterError(code: "INVALID_ARGUMENT", message: "Missing utteranceId", details: nil))
      return
    }

    stopLiveSynthesizer()

    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = resolveVoice(locale: nil, voiceId: nil)
    utterance.rate = mapSpeechRate(selectedRate)
    utteranceIds[ObjectIdentifier(utterance)] = utteranceId
    activeLiveUtteranceId = utteranceId
    liveSynthesizer.speak(utterance)
    result([
      "accepted": true,
      "utteranceId": utteranceId,
    ])
  }

  private func handleSynthesizeToFile(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    let text = args?["text"] as? String ?? ""
    let rawPath = (args?["filePath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let requestedLocale = (args?["locale"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let requestedVoiceId = (args?["voiceId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      result(FlutterError(code: "INVALID_TEXT", message: "Empty speech text", details: nil))
      return
    }
    guard !rawPath.isEmpty else {
      result(FlutterError(code: "INVALID_ARGUMENT", message: "Missing filePath", details: nil))
      return
    }

    let rate: Double
    if let rawRate = args?["rate"], !(rawRate is NSNull) {
      guard let parsed = parseDouble(rawRate), parsed.isFinite, parsed > 0 else {
        result(FlutterError(code: "INVALID_RATE", message: "Invalid speech rate", details: nil))
        return
      }
      rate = parsed
    } else {
      rate = selectedRate
    }

    let tempRoot = FileManager.default.temporaryDirectory
      .resolvingSymlinksInPath()
      .standardizedFileURL
      .path
    let tempPrefix = tempRoot.hasSuffix("/") ? tempRoot : tempRoot + "/"
    let resolvedTargetUrl = URL(fileURLWithPath: rawPath)
      .resolvingSymlinksInPath()
      .standardizedFileURL
    let resolvedTargetPath = resolvedTargetUrl.path
    guard resolvedTargetPath.hasPrefix(tempPrefix) && resolvedTargetPath != tempRoot else {
      result(
        FlutterError(
          code: "INVALID_ARGUMENT",
          message: "Output path must be inside temporary directory",
          details: nil
        )
      )
      return
    }

    if let voiceId = requestedVoiceId,
       !voiceId.isEmpty,
       voiceId != "default",
       AVSpeechSynthesisVoice(identifier: voiceId) == nil,
       (requestedLocale ?? "").isEmpty {
      result(FlutterError(code: "VOICE_NOT_FOUND", message: "Voice not found: \(voiceId)", details: nil))
      return
    }

    let voice = resolveVoice(locale: requestedLocale, voiceId: requestedVoiceId)
    let mappedRate = mapSpeechRate(rate)

    activeSynthesisJob?.cancel()
    activeSynthesisJob = nil

    let job = FileSynthesisJob(
      text: text,
      originalFilePath: rawPath,
      fileUrl: resolvedTargetUrl,
      voice: voice,
      rate: mappedRate,
      result: result,
      onFinish: { [weak self] finishedJob in
        if let self = self, self.activeSynthesisJob === finishedJob {
          self.activeSynthesisJob = nil
        }
      }
    )
    activeSynthesisJob = job
    job.start()
  }

  private func stopAll() {
    activeSynthesisJob?.cancel()
    activeSynthesisJob = nil
    stopLiveSynthesizer()
  }

  private func stopLiveSynthesizer() {
    let previousId = activeLiveUtteranceId
    activeLiveUtteranceId = nil
    if liveSynthesizer.isSpeaking || liveSynthesizer.isPaused {
      liveSynthesizer.stopSpeaking(at: .immediate)
    } else if let id = previousId {
      utteranceIds = utteranceIds.filter { $0.value != id }
      sendEvent("onStopped", arguments: ["utteranceId": id])
    }
  }

  private func sortedVoices() -> [AVSpeechSynthesisVoice] {
    AVSpeechSynthesisVoice.speechVoices().sorted { lhs, rhs in
      if lhs.quality.rawValue != rhs.quality.rawValue {
        return lhs.quality.rawValue > rhs.quality.rawValue
      }
      return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
  }

  private func normalizeLocale(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "_", with: "-")
  }

  private func findVoice(forLocale locale: String) -> AVSpeechSynthesisVoice? {
    let normalized = normalizeLocale(locale)
    guard !normalized.isEmpty else { return nil }
    if let exact = AVSpeechSynthesisVoice(language: normalized) {
      return exact
    }
    let voices = sortedVoices()
    if let caseExact = voices.first(where: {
      $0.language.caseInsensitiveCompare(normalized) == .orderedSame
    }) {
      return caseExact
    }
    let primary = normalized.split(separator: "-").first.map { String($0).lowercased() } ?? ""
    guard !primary.isEmpty else { return nil }
    return voices.first { voice in
      let voicePrimary = voice.language.split(separator: "-").first.map { String($0).lowercased() } ?? ""
      return voicePrimary == primary
    }
  }

  private func resolveVoice(locale: String?, voiceId: String?) -> AVSpeechSynthesisVoice? {
    if let id = voiceId?.trimmingCharacters(in: .whitespacesAndNewlines),
       !id.isEmpty,
       id != "default",
       let voice = AVSpeechSynthesisVoice(identifier: id) {
      return voice
    }
    if let loc = locale, let voice = findVoice(forLocale: loc) {
      return voice
    }
    if let id = selectedVoiceId, let voice = AVSpeechSynthesisVoice(identifier: id) {
      return voice
    }
    if let loc = selectedLocale, let voice = findVoice(forLocale: loc) {
      return voice
    }
    return AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
  }

  private func mapSpeechRate(_ rate: Double) -> Float {
    let clamped = max(0.5, min(3.0, rate))
    let defaultRate = Double(AVSpeechUtteranceDefaultSpeechRate)
    let mapped: Double
    if clamped <= 1.0 {
      mapped = defaultRate * clamped
    } else {
      mapped = defaultRate + ((clamped - 1.0) / 2.0) * 0.22
    }
    return Float(
      max(
        Double(AVSpeechUtteranceMinimumSpeechRate),
        min(Double(AVSpeechUtteranceMaximumSpeechRate), mapped)
      )
    )
  }

  private func parseDouble(_ value: Any?) -> Double? {
    if value is Bool {
      return nil
    }
    if let number = value as? NSNumber {
      return number.doubleValue
    }
    if let doubleValue = value as? Double {
      return doubleValue
    }
    return nil
  }

  private func sendEvent(_ method: String, arguments: [String: Any]) {
    if Thread.isMainThread {
      channel.invokeMethod(method, arguments: arguments)
    } else {
      DispatchQueue.main.async { [weak self] in
        self?.channel.invokeMethod(method, arguments: arguments)
      }
    }
  }

  // MARK: - AVSpeechSynthesizerDelegate (Live Playback)

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
    guard synthesizer === liveSynthesizer,
          let id = utteranceIds[ObjectIdentifier(utterance)] else {
      return
    }
    sendEvent("onStart", arguments: ["utteranceId": id])
  }

  func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    willSpeakRangeOfSpeechString characterRange: NSRange,
    utterance: AVSpeechUtterance
  ) {
    guard synthesizer === liveSynthesizer,
          let id = utteranceIds[ObjectIdentifier(utterance)] else {
      return
    }
    sendEvent(
      "onProgress",
      arguments: [
        "utteranceId": id,
        "start": characterRange.location,
        "end": characterRange.location + characterRange.length,
      ]
    )
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    guard synthesizer === liveSynthesizer,
          let id = utteranceIds.removeValue(forKey: ObjectIdentifier(utterance)) else {
      return
    }
    if activeLiveUtteranceId == id {
      activeLiveUtteranceId = nil
    }
    sendEvent("onComplete", arguments: ["utteranceId": id])
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    guard synthesizer === liveSynthesizer,
          let id = utteranceIds.removeValue(forKey: ObjectIdentifier(utterance)) else {
      return
    }
    if activeLiveUtteranceId == id {
      activeLiveUtteranceId = nil
    }
    sendEvent("onStopped", arguments: ["utteranceId": id])
  }
}

private final class FileSynthesisJob: NSObject, AVSpeechSynthesizerDelegate {
  private let text: String
  private let originalFilePath: String
  private let fileUrl: URL
  private let voice: AVSpeechSynthesisVoice?
  private let rate: Float
  private let result: FlutterResult
  private let onFinish: (FileSynthesisJob) -> Void
  private let queue = DispatchQueue(label: "moe.yutro.yomiru.tts.file")
  private let synthesizer = AVSpeechSynthesizer()

  private var audioFile: AVAudioFile?
  private var hasWrittenFrames = false
  private var finished = false

  init(
    text: String,
    originalFilePath: String,
    fileUrl: URL,
    voice: AVSpeechSynthesisVoice?,
    rate: Float,
    result: @escaping FlutterResult,
    onFinish: @escaping (FileSynthesisJob) -> Void
  ) {
    self.text = text
    self.originalFilePath = originalFilePath
    self.fileUrl = fileUrl
    self.voice = voice
    self.rate = rate
    self.result = result
    self.onFinish = onFinish
    super.init()
    self.synthesizer.delegate = self
    self.synthesizer.usesApplicationAudioSession = true
  }

  func start() {
    queue.async { [weak self] in
      guard let self = self, !self.finished else { return }
      do {
        try FileManager.default.createDirectory(
          at: self.fileUrl.deletingLastPathComponent(),
          withIntermediateDirectories: true,
          attributes: nil
        )
        if FileManager.default.fileExists(atPath: self.fileUrl.path) {
          try FileManager.default.removeItem(at: self.fileUrl)
        }
      } catch {
        self.finishFailure(code: "SYNTHESIS_FAILED", message: error.localizedDescription)
        return
      }

      let utterance = AVSpeechUtterance(string: self.text)
      utterance.voice = self.voice
      utterance.rate = self.rate

      self.synthesizer.write(utterance) { [weak self] buffer in
        self?.queue.async { [weak self] in
          self?.handleBuffer(buffer)
        }
      }
    }
  }

  func cancel() {
    queue.async { [weak self] in
      guard let self = self, !self.finished else { return }
      self.synthesizer.stopSpeaking(at: .immediate)
      self.finishFailure(code: "TTS_STOPPED", message: "Synthesis stopped")
    }
  }

  private func handleBuffer(_ buffer: AVAudioBuffer) {
    guard !finished else { return }
    guard let pcmBuffer = buffer as? AVAudioPCMBuffer else {
      synthesizer.stopSpeaking(at: .immediate)
      finishFailure(code: "SYNTHESIS_FAILED", message: "Unexpected non-PCM audio buffer")
      return
    }
    if pcmBuffer.frameLength == 0 {
      completeIfReady()
      return
    }

    if audioFile == nil {
      let format = pcmBuffer.format
      let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: format.sampleRate,
        AVNumberOfChannelsKey: format.channelCount,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsNonInterleaved: false,
      ]
      do {
        audioFile = try AVAudioFile(
          forWriting: fileUrl,
          settings: settings,
          commonFormat: format.commonFormat,
          interleaved: format.isInterleaved
        )
      } catch {
        synthesizer.stopSpeaking(at: .immediate)
        finishFailure(code: "SYNTHESIS_FAILED", message: error.localizedDescription)
        return
      }
    }

    do {
      try audioFile?.write(from: pcmBuffer)
      hasWrittenFrames = true
    } catch {
      synthesizer.stopSpeaking(at: .immediate)
      finishFailure(code: "SYNTHESIS_FAILED", message: error.localizedDescription)
    }
  }

  private func completeIfReady() {
    guard !finished else { return }
    finished = true
    synthesizer.delegate = nil
    audioFile = nil

    let fileSize: Int64
    if let attrs = try? FileManager.default.attributesOfItem(atPath: fileUrl.path),
       let size = attrs[.size] as? NSNumber {
      fileSize = size.int64Value
    } else {
      fileSize = 0
    }

    guard hasWrittenFrames && fileSize > 44 else {
      try? FileManager.default.removeItem(at: fileUrl)
      DispatchQueue.main.async {
        self.result(
          FlutterError(
            code: "SYNTHESIS_FAILED",
            message: "Synthesized audio file is empty",
            details: nil
          )
        )
        self.onFinish(self)
      }
      return
    }

    let outputPath = originalFilePath
    DispatchQueue.main.async {
      self.result([
        "completed": true,
        "path": outputPath,
      ])
      self.onFinish(self)
    }
  }

  private func finishFailure(code: String, message: String) {
    guard !finished else { return }
    finished = true
    synthesizer.delegate = nil
    audioFile = nil
    try? FileManager.default.removeItem(at: fileUrl)
    DispatchQueue.main.async {
      self.result(FlutterError(code: code, message: message, details: nil))
      self.onFinish(self)
    }
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    queue.async { [weak self] in
      self?.completeIfReady()
    }
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    queue.async { [weak self] in
      self?.finishFailure(code: "TTS_STOPPED", message: "Synthesis cancelled")
    }
  }
}
