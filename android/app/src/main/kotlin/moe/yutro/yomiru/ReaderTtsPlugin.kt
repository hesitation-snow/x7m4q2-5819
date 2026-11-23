package moe.yutro.yomiru

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.speech.tts.Voice
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.util.IllformedLocaleException
import java.util.Locale
import java.util.UUID

/**
 * Engine-scoped Android TextToSpeech plugin (inspired by Wenku8_Flutter's SystemSpeechPlugin).
 * Keeps `moe.yutro.yomiru/tts` and the TextToSpeech session alive across Activity dismissal
 * while AudioService keeps the FlutterEngine running for background listening.
 */
class ReaderTtsPlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    PluginRegistry.RequestPermissionsResultListener {

    private var appContext: Context? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var ttsChannel: MethodChannel? = null

    private var pendingNotificationPermissionResult: MethodChannel.Result? = null
    private val notificationPermissionRequestCode = 10137

    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private var ttsInitFailed = false
    private var selectedTtsEngineName: String? = null
    private var ttsGeneration = 0
    private var pendingEngineSwitchResult: MethodChannel.Result? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private var activeTtsId: String? = null
    private var activeClientId: String? = null
    private val pendingFileSynthesis = mutableMapOf<String, MethodChannel.Result>()
    private val pendingFileClientIds = mutableMapOf<String, String>()
    private val pendingFilePaths = mutableMapOf<String, String>()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        releaseTts()
        val generation = ttsGeneration
        ttsChannel = MethodChannel(binding.binaryMessenger, "moe.yutro.yomiru/tts").also { channel ->
            channel.setMethodCallHandler(this)
        }
        val ctx = binding.applicationContext
        tts = TextToSpeech(ctx) { status ->
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
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        failPendingPermission("ENGINE_DETACHED", "Flutter engine detached before permission completed")
        releaseTts()
        appContext = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        failPendingPermission("ACTIVITY_DETACHED", "Activity detached before permission completed")
    }

    private fun failPendingPermission(code: String, message: String) {
        val pending = pendingNotificationPermissionResult ?: return
        pendingNotificationPermissionResult = null
        pending.error(code, message, null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val engine = tts
        when {
            call.method == "requestNotificationPermission" -> {
                requestNotificationPermission(result)
            }
            call.method == "getEngines" -> {
                val ctx = appContext
                val installed = try {
                    ctx?.packageManager?.queryIntentServices(Intent("android.intent.action.TTS_SERVICE"), 0)
                        ?.map { info ->
                            val pkg = info.serviceInfo.packageName
                            val label = info.loadLabel(ctx.packageManager)?.toString() ?: pkg
                            mapOf("name" to pkg, "label" to label, "isSystem" to pkg.startsWith("com."))
                        } ?: emptyList()
                } catch (_: Exception) {
                    emptyList<Map<String, Any>>()
                }
                if (installed.isNotEmpty()) {
                    result.success(installed)
                } else if (ttsReady && engine != null) {
                    result.success(engine.engines.map {
                        mapOf("name" to it.name, "label" to it.label, "isSystem" to it.name.startsWith("com."))
                    })
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
                if (engine != null && engine.stop() == TextToSpeech.ERROR) {
                    result.error("stop_failed", "Could not stop speech", null)
                } else {
                    result.success(null)
                }
            }
            call.method !in setOf(
                "getEngines",
                "getVoices",
                "setLanguage",
                "setVoice",
                "setSpeechRate",
                "speak",
                "synthesizeToFile"
            ) -> result.notImplemented()
            !ttsReady || engine == null -> result.error(
                if (ttsInitFailed) "INIT_FAILED" else "TTS_NOT_READY",
                if (ttsInitFailed) "TextToSpeech initialization failed" else "TextToSpeech engine is initializing",
                null
            )
            else -> handleTtsCall(call, result, engine)
        }
    }

    private fun handleTtsCall(call: MethodCall, result: MethodChannel.Result, engine: TextToSpeech) {
        val args = call.arguments as? Map<*, *>
        when (call.method) {
            "getEngines" -> result.success(engine.engines.map {
                mapOf("name" to it.name, "label" to it.label, "isSystem" to it.name.startsWith("com."))
            })
            "getVoices" -> result.success((engine.voices ?: emptySet()).map { voiceToMap(it) })
            "setLanguage" -> {
                val locale = parseLocale((call.arguments as? String) ?: (args?.get("locale") as? String))
                if (locale == null) {
                    result.error("INVALID_LOCALE", "Expected a BCP-47 locale tag", null)
                } else {
                    val status = engine.setLanguage(locale)
                    if (status < TextToSpeech.LANG_AVAILABLE) {
                        result.error("INVALID_LOCALE", "Language is not available", status)
                    } else {
                        result.success(mapOf("status" to status, "available" to true))
                    }
                }
            }
            "setVoice" -> {
                val id = (args?.get("id") as? String) ?: (call.arguments as? String)
                val voice = engine.voices?.firstOrNull { it.name == id }
                if (voice == null || engine.setVoice(voice) != TextToSpeech.SUCCESS) {
                    result.error("VOICE_NOT_FOUND", "Voice id is not available", null)
                } else {
                    result.success(true)
                }
            }
            "setSpeechRate" -> {
                val rate = ((call.arguments as? Number) ?: (args?.get("rate") as? Number))?.toFloat()
                if (rate == null || !rate.isFinite() || rate <= 0f || engine.setSpeechRate(rate) != TextToSpeech.SUCCESS) {
                    result.error("INVALID_RATE", "Rate must be finite and greater than zero", null)
                } else {
                    result.success(true)
                }
            }
            "synthesizeToFile" -> {
                val ctx = appContext
                if (ctx == null) {
                    result.error("TTS_DISPOSED", "Plugin context is unavailable", null)
                    return
                }
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
                val target = try {
                    File(path).canonicalFile
                } catch (e: Exception) {
                    result.error("INVALID_PATH", e.message, null)
                    return
                }
                val cache = ctx.cacheDir.canonicalFile
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
                target.parentFile?.let {
                    if (!it.exists() && !it.mkdirs()) {
                        result.error("FILE_CREATE_FAILED", "Could not create cache subdirectory", null)
                        return
                    }
                }
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
                    activeTtsId = null
                    activeClientId = null
                    if (engine.stop() != TextToSpeech.SUCCESS) {
                        result.error("stop_failed", "Could not stop previous speech", null)
                    } else {
                        val clientId = (args["utteranceId"] as? String) ?: UUID.randomUUID().toString()
                        val internalId = UUID.randomUUID().toString()
                        activeTtsId = internalId
                        activeClientId = clientId
                        val status = engine.speak(text, TextToSpeech.QUEUE_ADD, Bundle(), internalId)
                        if (status != TextToSpeech.SUCCESS) {
                            activeTtsId = null
                            activeClientId = null
                            result.error("SPEAK_FAILED", "TextToSpeech rejected the utterance", status)
                        } else {
                            result.success(mapOf("utteranceId" to clientId, "accepted" to true))
                        }
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
            emitTtsEvent(
                generation,
                utteranceId,
                "onError",
                mapOf("code" to "TTS_ERROR", "nativeCode" to errorCode),
                true
            )
        }
        override fun onStop(utteranceId: String, interrupted: Boolean) {
            completeFileSynthesis(generation, utteranceId, "TTS_STOPPED")
            emitTtsEvent(generation, utteranceId, "onStopped", terminal = true)
        }
        override fun onRangeStart(utteranceId: String, start: Int, end: Int, frame: Int) =
            emitTtsEvent(generation, utteranceId, "onProgress", mapOf("start" to start, "end" to end, "frame" to frame))
    }

    private fun switchTtsEngine(call: MethodCall, result: MethodChannel.Result) {
        val ctx = appContext
        if (ctx == null) {
            result.error("TTS_DISPOSED", "Plugin context is unavailable", null)
            return
        }
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
            ctx.packageManager.queryIntentServices(Intent("android.intent.action.TTS_SERVICE"), 0)
                .map { it.serviceInfo.packageName }.toSet()
        } catch (_: Exception) {
            emptySet()
        }

        if (requested != null && installedPackages.isNotEmpty() && requested !in installedPackages) {
            result.error("ENGINE_NOT_FOUND", "The requested TTS engine is not installed", null)
            return
        }

        // Complete any previous in-flight switch so Dart never hangs on rapid engine switching.
        pendingEngineSwitchResult?.error("TTS_ENGINE_CHANGED", "Superseded by a newer TTS engine switch", null)
        pendingEngineSwitchResult = result

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
        tts = TextToSpeech(ctx, { status ->
            mainHandler.post {
                if (generation != ttsGeneration) return@post
                val pending = pendingEngineSwitchResult
                pendingEngineSwitchResult = null
                val engine = tts
                if (status == TextToSpeech.SUCCESS && engine != null) {
                    ttsReady = engine.setOnUtteranceProgressListener(
                        createTtsProgressListener(generation)
                    ) == TextToSpeech.SUCCESS
                    ttsInitFailed = !ttsReady
                    if (ttsReady) {
                        selectedTtsEngineName = requested
                        pending?.success(true)
                    } else {
                        pending?.error("INIT_FAILED", "Could not attach the TTS listener", null)
                    }
                } else {
                    ttsInitFailed = true
                    pending?.error("INIT_FAILED", "Requested TTS engine failed to initialize", status)
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

    private fun emitTtsEvent(
        generation: Int,
        internalId: String,
        method: String,
        fields: Map<String, Any> = emptyMap(),
        terminal: Boolean = false
    ) {
        mainHandler.post {
            if (generation != ttsGeneration) return@post
            val synthesisClientId = pendingFileClientIds[internalId]
            if (synthesisClientId != null) {
                if (method == "onProgress") {
                    ttsChannel?.invokeMethod(method, fields + ("utteranceId" to synthesisClientId))
                }
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

    private fun completeFileSynthesis(
        generation: Int,
        internalId: String,
        errorCode: String?,
        nativeCode: Int? = null
    ) {
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
        pendingEngineSwitchResult?.error("TTS_DISPOSED", "TextToSpeech engine was disposed", null)
        pendingEngineSwitchResult = null
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
        val ctx = appContext
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ctx?.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        val activity: Activity? = activityBinding?.activity
        if (activity == null) {
            result.success(false)
            return
        }
        if (pendingNotificationPermissionResult != null) {
            result.error("PERMISSION_REQUEST_PENDING", "A notification permission request is already pending", null)
            return
        }
        pendingNotificationPermissionResult = result
        activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), notificationPermissionRequestCode)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ): Boolean {
        if (requestCode != notificationPermissionRequestCode) return false
        val result = pendingNotificationPermissionResult ?: return true
        pendingNotificationPermissionResult = null
        result.success(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
        return true
    }
}
