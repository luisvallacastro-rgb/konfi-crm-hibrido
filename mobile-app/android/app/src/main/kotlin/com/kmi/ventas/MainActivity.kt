package com.kmi.ventas

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val sessionChannel = "com.kmi.ventas/session"
    private val preferencesName = "kmi_ventas_session"
    private val sessionKey = "active_seller"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            sessionChannel,
        ).setMethodCallHandler { call, result ->
            val preferences = getSharedPreferences(preferencesName, MODE_PRIVATE)
            when (call.method) {
                "read" -> result.success(preferences.getString(sessionKey, null))
                "write" -> {
                    val session = call.arguments as? String
                    if (session == null) {
                        result.error("INVALID_SESSION", "Sesion vacia", null)
                    } else {
                        preferences.edit().putString(sessionKey, session).apply()
                        result.success(null)
                    }
                }
                "clear" -> {
                    preferences.edit().remove(sessionKey).apply()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
