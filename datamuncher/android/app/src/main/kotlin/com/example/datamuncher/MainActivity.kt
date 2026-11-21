package com.example.datamuncher

import android.media.MediaScannerConnection
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // After the Garbage Bin moves files, re-index their old and new paths
        // so the gallery (and photo_manager) stop showing stale entries.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "datamuncher/media")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "scanFiles" -> {
                        val paths = call.argument<List<String>>("paths").orEmpty()
                        MediaScannerConnection.scanFile(applicationContext, paths.toTypedArray(), null, null)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
