package moe.yutro.yomiru

import android.app.Activity
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.view.KeyEvent
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : AudioServiceActivity() {
    private var readerChannel: MethodChannel? = null
    private var epubChannel: MethodChannel? = null
    private var lifecycleChannel: MethodChannel? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var volumePaging = false
    private var readerOwner = -1
    private val capturedKeys = mutableSetOf<Int>()

    private var pendingSaveResult: MethodChannel.Result? = null
    private var pendingSourceFilePath: String? = null
    private val REQUEST_CODE_SAVE_EPUB = 10091

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        if (!flutterEngine.plugins.has(ReaderTtsPlugin::class.java)) {
            flutterEngine.plugins.add(ReaderTtsPlugin())
        }
        readerChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "moe.yutro.yomiru/reader_keys"
        ).also { channel ->
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
                } else {
                    result.notImplemented()
                }
            }
        }

        epubChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "moe.yutro.yomiru/epub_export"
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                if (call.method == "saveDocument") {
                    if (pendingSaveResult != null) {
                        result.error("SAVE_IN_PROGRESS", "Another save operation is already in progress", null)
                        return@setMethodCallHandler
                    }
                    val filePath = call.argument<String>("filePath")
                    val fileName = call.argument<String>("fileName") ?: "book.epub"
                    if (filePath == null || !File(filePath).exists()) {
                        result.error("FILE_NOT_FOUND", "Source EPUB file does not exist", null)
                        return@setMethodCallHandler
                    }
                    pendingSaveResult = result
                    pendingSourceFilePath = filePath

                    val explicitMime = call.argument<String>("mimeType")
                    val mimeType = explicitMime ?: if (fileName.endsWith(".txt", ignoreCase = true)) {
                        "text/plain"
                    } else {
                        "application/epub+zip"
                    }

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

        lifecycleChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "moe.yutro.yomiru/app_lifecycle"
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                if (call.method == "moveToBackground") {
                    result.success(moveTaskToBack(true))
                } else {
                    result.notImplemented()
                }
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_CODE_SAVE_EPUB) {
            val result = pendingSaveResult
            val sourcePath = pendingSourceFilePath
            pendingSaveResult = null
            pendingSourceFilePath = null

            val destUri = data?.data
            if (resultCode == Activity.RESULT_OK && destUri != null && sourcePath != null) {
                val resolver = contentResolver
                Thread {
                    try {
                        val out = resolver.openOutputStream(destUri)
                        if (out == null) {
                            mainHandler.post {
                                result?.error("SAVE_FAILED", "Could not open destination output stream", null)
                            }
                            return@Thread
                        }
                        out.use { stream ->
                            File(sourcePath).inputStream().use { input ->
                                input.copyTo(stream)
                            }
                        }
                        mainHandler.post { result?.success(true) }
                    } catch (e: Exception) {
                        mainHandler.post { result?.error("SAVE_FAILED", e.message, null) }
                    }
                }.start()
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
                if (event.repeatCount == 0) {
                    readerChannel?.invokeMethod(
                        "volumeKey",
                        mapOf(
                            "owner" to readerOwner,
                            "direction" to if (code == KeyEvent.KEYCODE_VOLUME_DOWN) "next" else "previous"
                        )
                    )
                }
                return true
            }
        }
        return super.dispatchKeyEvent(event)
    }

    override fun onPause() {
        volumePaging = false
        capturedKeys.clear()
        super.onPause()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        if (!hasFocus) {
            capturedKeys.clear()
        }
        super.onWindowFocusChanged(hasFocus)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        volumePaging = false
        capturedKeys.clear()
        readerChannel?.setMethodCallHandler(null)
        readerChannel = null
        epubChannel?.setMethodCallHandler(null)
        epubChannel = null
        lifecycleChannel?.setMethodCallHandler(null)
        lifecycleChannel = null
        pendingSaveResult?.error("ACTIVITY_DESTROYED", "Activity engine was cleaned up before save completed", null)
        pendingSaveResult = null
        pendingSourceFilePath = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
