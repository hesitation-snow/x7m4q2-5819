package moe.yutro.yomiru

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.view.KeyEvent

class MainActivity : FlutterActivity() {
    private var readerChannel: MethodChannel? = null
    private var volumePaging = false
    private var readerOwner = -1
    private val capturedKeys = mutableSetOf<Int>()

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
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
