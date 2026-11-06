package moe.yutro.yomiru

import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.view.KeyEvent
import android.content.Intent
import android.app.Activity
import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import java.io.File
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import java.util.IllformedLocaleException
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.speech.tts.Voice
import java.util.Locale
import java.util.UUID

class MainActivity : AudioServiceActivity() {
    private var readerChannel: MethodChannel? = null
    private var epubChannel: MethodChannel? = null
    private var ttsChannel: MethodChannel? = null
    private var pendingNotificationPermissionResult: MethodChannel.Result? = null
    private val notificationPermissionRequestCode = 10137
    private var tts: TextToSpeech? = null
    // TTS state is confined to the main thread, including callbacks from the engine.
    private var ttsReady = false
    private var ttsInitFailed = false
    private var selectedTtsEngineName: String? = null
    private var ttsGeneration = 0
    private val mainHandler = Handler(Looper.getMainLooper())
    private var activeTtsId: String? = null
    private var activeClientId: String? = null
    private val pendingFileSynthesis = mutableMapOf<String, MethodChannel.Result>()
    private val pendingFileClientIds = mutableMapOf<String, String>()
    private val pendingFilePaths = mutableMapOf<String, String>()
    private var volumePaging = false
    private var readerOwner = -1
    private val capturedKeys = mutableSetOf<Int>()

    private var pendingSaveResult: MethodChannel.Result? = null
    private var pendingSourceFilePath: String? = null
    private val REQUEST_CODE_SAVE_EPUB = 10091

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        readerChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "moe.yutro.yomiru/reader_keys").also { channel ->
            channel.setMethodCallHandler { call, result ->
                if (call.method == "setVolumePaging") {
                    val owner = call.argument<Int>("owner") ?: -1
                    val enabled = call.argument<Boolean>("enabled") == true
                    // 切章后的旧页面 dispose 不得关闭新页面的按键捕获。
                    if (enabled || owner == readerOwner) {
                        readerOwner = owner
                        volumePaging = enabled
                    }
                    result.success(null)
                } else result.notImplemented()
            }
        }

        releaseTts()
        val generation = ttsGeneration
        ttsChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "moe.yutro.yomiru/tts").also { channel ->
            channel.setMethodCallHandler { call, result ->
                val engine = tts
                when {
                    call.method == "requestNotificationPermission" -> {
                        requestNotificationPermission(result)
                    }
                    call.method == "getEngines" -> {
                        val installed = try {
                            packageManager.queryIntentServices(Intent("android.intent.action.TTS_SERVICE"), 0).map { info ->
                                val pkg = info.serviceInfo.packageName
                                val label = info.loadLabel(packageManager)?.toString() ?: pkg
                                mapOf("name" to pkg, "label" to label, "isSystem" to pkg.startsWith("com."))
                            }
                        } catch (_: Exception) { emptyList<Map<String, Any>>() }
                        if (installed.isNotEmpty()) {
                            result.success(installed)
                        } else if (ttsReady && engine != null) {
                            result.success(engine.engines.map { mapOf("name" to it.name, "label" to it.label, "isSystem" to it.name.startsWith("com.")) })
                        } else {
                            result.success(emptyList<Map<String, Any>>())
                        }
                    }
                    call.method == "setEngine" -> {
                        switchTtsEngine(call, result)
                    }
                    call.method == "stop" || call.method == "pause" -> {
                        activeTtsId = null
                        activeClientId = null
                        val cancelled = pendingFileSynthesis.values.toList()
                        pendingFileSynthesis.clear()
                        pendingFileClientIds.clear()
                        pendingFilePaths.clear()
                        cancelled.forEach { it.error("TTS_STOPPED", "Speech synthesis was stopped", null) }
                        if (engine != null && engine.stop() == TextToSpeech.ERROR)
                            result.error("stop_failed", "Could not stop speech", null)
                        else result.success(null)
                    }
                    call.method !in setOf("getEngines", "getVoices", "setLanguage", "setVoice", "setSpeechRate", "speak", "synthesizeToFile") -> result.notImplemented()
                    !ttsReady || engine == null -> result.error(
                        if (ttsInitFailed) "INIT_FAILED" else "TTS_NOT_READY",
                        if (ttsInitFailed) "TextToSpeech initialization failed" else "TextToSpeech engine is initializing", null)
                    else -> handleTtsCall(call, result, engine)
                }
            }
        }
        // Posting also handles an initialization callback delivered before the constructor returns.
        tts = TextToSpeech(applicationContext) { status ->
            mainHandler.post {
                if (generation != ttsGeneration) return@post
                val engine = tts
                if (status == TextToSpeech.SUCCESS && engine != null) {
                    val listenerStatus = engine.setOnUtteranceProgressListener(
                        createTtsProgressListener(generation)
                    )
                    ttsReady = listenerStatus == TextToSpeech.SUCCESS
                    ttsInitFailed = !ttsReady
                } else {
                    ttsInitFailed = true
                }
            }
        }

        epubChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "moe.yutro.yomiru/epub_export").also { channel ->
            channel.setMethodCallHandler { call, result ->
                if (call.method == "saveDocument") {
                    val filePath = call.argument<String>("filePath")
                    val fileName = call.argument<String>("fileName") ?: "book.epub"
                    if (filePath == null || !File(filePath).exists()) {
                        result.error("FILE_NOT_FOUND", "Source EPUB file does not exist", null)
                        return@setMethodCallHandler
                    }
                    pendingSaveResult = result
                    pendingSourceFilePath = filePath

                    val explicitMime = call.argument<String>("mimeType")
                    val mimeType = explicitMime ?: if (fileName.endsWith(".txt", ignoreCase = true)) "text/plain" else "application/epub+zip"

                    val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = mimeType
                        putExtra(Intent.EXTRA_TITLE, fileName)
                    }
                    try {
                        startActivityForResult(intent, REQUEST_CODE_SAVE_EPUB)
                    } catch (e: Exception) {
                        pendingSaveResult = null
                        pendingSourceFilePath = null
                        result.error("ACTIVITY_NOT_FOUND", e.message, null)
                    }
                } else {
                    result.notImplemented()
                }
            }
        }
    }

    private fun handleTtsCall(call: MethodCall, result: MethodChannel.Result, engine: TextToSpeech) {
        // Accept the Dart facade's map arguments as well as older scalar callers.
        val args = call.arguments as? Map<*, *>
        when (call.method) {
            "getEngines" -> result.success(engine.engines.map { mapOf("name" to it.name, "label" to it.label, "isSystem" to it.name.startsWith("com.")) })
            "getVoices" -> result.success((engine.voices ?: emptySet()).map { voiceToMap(it) })
            "setLanguage" -> {
                val locale = parseLocale((call.arguments as? String) ?: (args?.get("locale") as? String))
                if (locale == null) result.error("INVALID_LOCALE", "Expected a BCP-47 locale tag", null)
                else {
                    val status = engine.setLanguage(locale)
                    if (status < TextToSpeech.LANG_AVAILABLE) result.error("INVALID_LOCALE", "Language is not available", status)
                    else result.success(mapOf("status" to status, "available" to true))
                }
            }
            "setVoice" -> {
                val id = (args?.get("id") as? String) ?: (call.arguments as? String)
                val voice = engine.voices?.firstOrNull { it.name == id }
                if (voice == null || engine.setVoice(voice) != TextToSpeech.SUCCESS)
                    result.error("VOICE_NOT_FOUND", "Voice id is not available", null)
                else result.success(true)
            }
            "setSpeechRate" -> {
                val rate = ((call.arguments as? Number) ?: (args?.get("rate") as? Number))?.toFloat()
                if (rate == null || !rate.isFinite() || rate <= 0f || engine.setSpeechRate(rate) != TextToSpeech.SUCCESS)
                    result.error("INVALID_RATE", "Rate must be finite and greater than zero", null)
                else result.success(true)
            }
            "synthesizeToFile" -> {
                val text = args?.get("text") as? String
                val path = args?.get("filePath") as? String
                val requestedId = args?.get("utteranceId") as? String
                if (text.isNullOrBlank() || text.length >= TextToSpeech.getMaxSpeechInputLength()) {
                    result.error("INVALID_TEXT", "Text is empty or exceeds the engine limit", null)
                    return
                }
                if (path.isNullOrBlank()) {
                    result.error("INVALID_PATH", "filePath is required", null)
                    return
                }
                val target = try { File(path).canonicalFile } catch (e: Exception) {
                    result.error("INVALID_PATH", e.message, null)
                    return
                }
                val cache = cacheDir.canonicalFile
                if (target == cache || !target.path.startsWith(cache.path + File.separator)) {
                    result.error("INVALID_PATH", "Output must be inside the app cache directory", null)
                    return
                }
                val localeTag = args["locale"] as? String
                val locale = if (localeTag != null) parseLocale(localeTag) else null
                if (localeTag != null && locale == null) {
                    result.error("INVALID_LOCALE", "Expected a BCP-47 locale tag", null)
                    return
                }
                val voiceId = args["voiceId"] as? String
                val voice = if (voiceId != null) engine.voices?.firstOrNull { it.name == voiceId } else null
                if (voiceId != null && voice == null) {
                    result.error("VOICE_NOT_FOUND", "Voice id is not available", null)
                    return
                }
                val rate = (args["rate"] as? Number)?.toFloat()
                if (args.containsKey("rate") && (rate == null || !rate.isFinite() || rate <= 0f)) {
                    result.error("INVALID_RATE", "Rate must be finite and greater than zero", null)
                    return
                }
                if (locale != null && engine.setLanguage(locale) < TextToSpeech.LANG_AVAILABLE) {
                    result.error("INVALID_LOCALE", "Language is not available", null)
                    return
                }
                if (voice != null && engine.setVoice(voice) != TextToSpeech.SUCCESS) {
                    result.error("VOICE_NOT_FOUND", "Voice id is not available", null)
                    return
                }
                if (rate != null && engine.setSpeechRate(rate) != TextToSpeech.SUCCESS) {
                    result.error("INVALID_RATE", "Rate must be finite and greater than zero", null)
                    return
                }
                target.parentFile?.let { if (!it.exists() && !it.mkdirs()) {
                    result.error("FILE_CREATE_FAILED", "Could not create cache subdirectory", null)
                    return
                } }
                val internalId = UUID.randomUUID().toString()
                val clientId = requestedId ?: internalId
                val bundle = Bundle().apply {
                    putString(TextToSpeech.Engine.KEY_PARAM_UTTERANCE_ID, internalId)
                }
                pendingFileSynthesis[internalId] = result
                pendingFileClientIds[internalId] = clientId
                pendingFilePaths[internalId] = target.path
                val status = engine.synthesizeToFile(text, bundle, target, internalId)
                if (status != TextToSpeech.SUCCESS) {
                    pendingFileSynthesis.remove(internalId)
                    pendingFileClientIds.remove(internalId)
                    pendingFilePaths.remove(internalId)
                    result.error("SYNTHESIS_FAILED", "TextToSpeech rejected the synthesis request", status)
                }
            }
            "speak" -> {
                val text = args?.get("text") as? String
                if (text.isNullOrBlank() || text.length >= TextToSpeech.getMaxSpeechInputLength()) {
                    result.error("INVALID_TEXT", "Text is empty or exceeds the engine limit", null)
                } else {
                    // Internal IDs remain unique even if callers reuse a public utterance ID.
                    activeTtsId = null
                    activeClientId = null
                    if (engine.stop() != TextToSpeech.SUCCESS) {
                        result.error("stop_failed", "Could not stop previous speech", null)
                    } else {
                        val clientId = (args.get("utteranceId") as? String) ?: UUID.randomUUID().toString()
                        val internalId = UUID.randomUUID().toString()
                        activeTtsId = internalId
                        activeClientId = clientId
                        val status = engine.speak(text, TextToSpeech.QUEUE_ADD, Bundle(), internalId)
                        if (status != TextToSpeech.SUCCESS) {
                            activeTtsId = null
                            activeClientId = null
                            result.error("SPEAK_FAILED", "TextToSpeech rejected the utterance", status)
                        } else result.success(mapOf("utteranceId" to clientId, "accepted" to true))
                    }
                }
            }
        }
    }

    private fun createTtsProgressListener(generation: Int) = object : UtteranceProgressListener() {
        override fun onStart(utteranceId: String) = emitTtsEvent(generation, utteranceId, "onStart")
        override fun onDone(utteranceId: String) {
            completeFileSynthesis(generation, utteranceId, null)
            emitTtsEvent(generation, utteranceId, "onComplete", terminal = true)
        }
        @Deprecated("Deprecated in API")
        override fun onError(utteranceId: String) {
            completeFileSynthesis(generation, utteranceId, "TTS_ERROR")
            emitTtsEvent(generation, utteranceId, "onError", mapOf("code" to "TTS_ERROR"), true)
        }
        override fun onError(utteranceId: String, errorCode: Int) {
            completeFileSynthesis(generation, utteranceId, "TTS_ERROR", errorCode)
            emitTtsEvent(generation, utteranceId, "onError", mapOf("code" to "TTS_ERROR", "nativeCode" to errorCode), true)
        }
        override fun onStop(utteranceId: String, interrupted: Boolean) {
            completeFileSynthesis(generation, utteranceId, "TTS_STOPPED")
            emitTtsEvent(generation, utteranceId, "onStopped", terminal = true)
        }
        override fun onRangeStart(utteranceId: String, start: Int, end: Int, frame: Int) =
            emitTtsEvent(generation, utteranceId, "onProgress", mapOf("start" to start, "end" to end, "frame" to frame))
    }

    private fun switchTtsEngine(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val requestedId = (call.arguments as? Map<*, *>)?.get("id") as? String
        if (requestedId.isNullOrBlank()) {
            result.error("INVALID_ENGINE", "An engine package name is required", null)
            return
        }
        val requested = if (requestedId == "default") null else requestedId
        if (requested == selectedTtsEngineName && ttsReady) {
            result.success(true)
            return
        }

        val installedPackages = try {
            packageManager.queryIntentServices(Intent("android.intent.action.TTS_SERVICE"), 0)
                .map { it.serviceInfo.packageName }.toSet()
        } catch (_: Exception) { emptySet() }

        if (requested != null && installedPackages.isNotEmpty() && requested !in installedPackages) {
            result.error("ENGINE_NOT_FOUND", "The requested TTS engine is not installed", null)
            return
        }

        ++ttsGeneration
        val generation = ttsGeneration
        pendingFileSynthesis.values.toList().forEach {
            it.error("TTS_ENGINE_CHANGED", "TTS engine changed during synthesis", null)
        }
        pendingFileSynthesis.clear()
        pendingFileClientIds.clear()
        pendingFilePaths.clear()
        activeTtsId = null
        activeClientId = null
        ttsReady = false
        ttsInitFailed = false
        tts?.stop()
        tts?.shutdown()
        tts = null
        tts = TextToSpeech(applicationContext, { status ->
            mainHandler.post {
                if (generation != ttsGeneration) return@post
                val engine = tts
                if (status == TextToSpeech.SUCCESS && engine != null) {
                    ttsReady = engine.setOnUtteranceProgressListener(
                        createTtsProgressListener(generation)
                    ) == TextToSpeech.SUCCESS
                    ttsInitFailed = !ttsReady
                    if (ttsReady) {
                        selectedTtsEngineName = requested
                        result.success(true)
                    } else {
                        result.error("INIT_FAILED", "Could not attach the TTS listener", null)
                    }
                } else {
                    ttsInitFailed = true
                    result.error("INIT_FAILED", "Requested TTS engine failed to initialize", status)
                }
            }
        }, requested)
    }

    private fun parseLocale(tag: String?): Locale? {
        if (tag.isNullOrBlank()) return null
        return try {
            Locale.Builder().setLanguageTag(tag.replace('_', '-')).build().takeIf { it.language.isNotEmpty() }
        } catch (_: IllformedLocaleException) {
            null
        }
    }

    private fun emitTtsEvent(generation: Int, internalId: String, method: String,
                             fields: Map<String, Any> = emptyMap(), terminal: Boolean = false) {
        mainHandler.post {
            if (generation != ttsGeneration) return@post
            val synthesisClientId = pendingFileClientIds[internalId]
            if (synthesisClientId != null) {
                if (method == "onProgress") ttsChannel?.invokeMethod(method, fields + ("utteranceId" to synthesisClientId))
                return@post
            }
            if (activeTtsId != internalId) return@post
            val clientId = activeClientId ?: return@post
            if (terminal) {
                activeTtsId = null
                activeClientId = null
            }
            ttsChannel?.invokeMethod(method, fields + ("utteranceId" to clientId))
        }
    }

    private fun completeFileSynthesis(generation: Int, internalId: String, errorCode: String?, nativeCode: Int? = null) {
        mainHandler.post {
            if (generation != ttsGeneration) return@post
            val pending = pendingFileSynthesis.remove(internalId) ?: return@post
            val clientId = pendingFileClientIds.remove(internalId)
            val outputPath = pendingFilePaths.remove(internalId)
            if (errorCode == null) {
                pending.success(mapOf("utteranceId" to clientId, "completed" to true, "path" to outputPath))
            } else {
                pending.error(errorCode, "TextToSpeech file synthesis failed", nativeCode)
            }
        }
    }

    private fun releaseTts() {
        ++ttsGeneration
        pendingFileSynthesis.values.forEach { it.error("TTS_DISPOSED", "TextToSpeech engine was disposed", null) }
        pendingFileSynthesis.clear()
        pendingFileClientIds.clear()
        pendingFilePaths.clear()
        activeTtsId = null
        activeClientId = null
        ttsReady = false
        ttsInitFailed = false
        selectedTtsEngineName = null
        ttsChannel?.setMethodCallHandler(null)
        ttsChannel = null
        tts?.stop()
        tts?.shutdown()
        tts = null
    }

    private fun voiceToMap(voice: Voice): Map<String, Any?> = mapOf(
        "id" to voice.name,
        "name" to voice.name,
        "locale" to voice.locale.toLanguageTag(),
        "quality" to voice.quality,
        "latency" to voice.latency,
        "networkRequired" to voice.isNetworkConnectionRequired
    )

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
            result.success(true)
            return
        }
        if (pendingNotificationPermissionResult != null) {
            result.error("PERMISSION_REQUEST_PENDING", "A notification permission request is already pending", null)
            return
        }
        pendingNotificationPermissionResult = result
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), notificationPermissionRequestCode)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != notificationPermissionRequestCode) return
        val result = pendingNotificationPermissionResult ?: return
        pendingNotificationPermissionResult = null
        result.success(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_CODE_SAVE_EPUB) {
            val result = pendingSaveResult
            val sourcePath = pendingSourceFilePath
            pendingSaveResult = null
            pendingSourceFilePath = null

            if (resultCode == Activity.RESULT_OK && data?.data != null && sourcePath != null) {
                try {
                    val destUri = data.data!!
                    contentResolver.openOutputStream(destUri)?.use { out ->
                        File(sourcePath).inputStream().use { input ->
                            input.copyTo(out)
                        }
                    }
                    result?.success(true)
                } catch (e: Exception) {
                    result?.error("SAVE_FAILED", e.message, null)
                }
            } else {
                result?.success(false)
            }
        }
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val code = event.keyCode
        if (code == KeyEvent.KEYCODE_VOLUME_UP || code == KeyEvent.KEYCODE_VOLUME_DOWN) {
            if (event.action == KeyEvent.ACTION_UP && capturedKeys.remove(code)) return true
            if (event.action == KeyEvent.ACTION_DOWN && capturedKeys.contains(code)) return true
            if (event.action == KeyEvent.ACTION_DOWN && volumePaging && hasWindowFocus()) {
                capturedKeys.add(code)
                // 长按只翻一页；消费重复事件，避免连续跳章或同时改变音量。
                if (event.repeatCount == 0) readerChannel?.invokeMethod("volumeKey", mapOf(
                    "owner" to readerOwner,
                    "direction" to if (code == KeyEvent.KEYCODE_VOLUME_DOWN) "next" else "previous"
                ))
                return true
            }
        }
        return super.dispatchKeyEvent(event)
    }

    override fun onPause() {
        volumePaging = false
        super.onPause()
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        volumePaging = false
        capturedKeys.clear()
        readerChannel?.setMethodCallHandler(null)
        readerChannel = null
        releaseTts()
        epubChannel?.setMethodCallHandler(null)
        epubChannel = null
        pendingSaveResult = null
        pendingSourceFilePath = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
