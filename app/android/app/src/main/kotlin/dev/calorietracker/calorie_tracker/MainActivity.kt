package dev.calorietracker.calorie_tracker

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Settings › 照片 › 后台扫描 asks whether the user set the app to
        // 电池 › 受限 (App info › App battery usage › Restricted). In that
        // bucket Android parks the periodic WorkManager job — the
        // closed-app photo scan AND the nightly summary — for days, and
        // nothing else in the app could explain the frozen 尚未运行. Only
        // the UI engine goes through this activity; the background engine
        // never needs the answer. No manifest permission is involved.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isBackgroundRestricted" -> result.success(isBackgroundRestricted())
                    else -> result.notImplemented()
                }
            }
    }

    private fun isBackgroundRestricted(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return false
        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        return am.isBackgroundRestricted
    }

    private companion object {
        const val CHANNEL = "dev.calorietracker/background"
    }
}
