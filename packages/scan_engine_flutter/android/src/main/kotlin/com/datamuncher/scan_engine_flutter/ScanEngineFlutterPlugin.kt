package com.datamuncher.scan_engine_flutter

import android.app.AppOpsManager
import android.app.usage.StorageStatsManager
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.StatFs
import android.os.storage.StorageManager
import android.provider.Settings
import android.provider.Telephony
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Android half of the DataMuncher scan engine: storage locations and totals,
 * usage access, and the installed-app list. File scanning itself happens in
 * Dart; this only covers what Dart can't reach.
 */
class ScanEngineFlutterPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private lateinit var worker: ExecutorService
    private val mainThread = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        worker = Executors.newSingleThreadExecutor()
        channel = MethodChannel(binding.binaryMessenger, "datamuncher/scan_engine")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        worker.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getSdkInt" -> result.success(Build.VERSION.SDK_INT)
            "getStorageRoots" -> result.success(storageRoots())
            "getStorageStats" -> inBackground(result) { storageStats() }
            "hasUsageAccess" -> result.success(hasUsageAccess())
            "openUsageAccessSettings" -> {
                context.startActivity(
                    Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
                result.success(null)
            }
            "listInstalledApps" -> inBackground(result) { installedApps() }
            else -> result.notImplemented()
        }
    }

    /** Runs slow work off the main thread and replies on it, as Flutter requires. */
    private fun inBackground(result: MethodChannel.Result, work: () -> Any?) {
        worker.execute {
            try {
                val value = work()
                mainThread.post { result.success(value) }
            } catch (e: Exception) {
                mainThread.post { result.error("native_error", e.message, null) }
            }
        }
    }

    /**
     * Root of every shared-storage volume (internal storage plus SD cards).
     * getExternalFilesDirs returns this app's folder on each volume, e.g.
     * /storage/emulated/0/Android/data/<pkg>/files, so trim back to the root.
     * No storage permission is needed for this.
     */
    private fun storageRoots(): List<String> =
        context.getExternalFilesDirs(null)
            .filterNotNull()
            .map { it.absolutePath.substringBefore("/Android/data/") }
            .distinct()

    /** Totals as shown in the Settings app's storage screen. */
    private fun storageStats(): Map<String, Long> {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = context.getSystemService(StorageStatsManager::class.java)
            try {
                return mapOf(
                    "totalBytes" to manager.getTotalBytes(StorageManager.UUID_DEFAULT),
                    "freeBytes" to manager.getFreeBytes(StorageManager.UUID_DEFAULT),
                )
            } catch (e: Exception) {
                // Fall back to the data partition below.
            }
        }
        val stat = StatFs(Environment.getDataDirectory().path)
        return mapOf("totalBytes" to stat.totalBytes, "freeBytes" to stat.availableBytes)
    }

    private fun hasUsageAccess(): Boolean {
        val appOps = context.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            appOps.unsafeCheckOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName
            )
        } else {
            @Suppress("DEPRECATION")
            appOps.checkOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName
            )
        }
        return if (mode == AppOpsManager.MODE_DEFAULT) {
            context.checkCallingOrSelfPermission(android.Manifest.permission.PACKAGE_USAGE_STATS) ==
                PackageManager.PERMISSION_GRANTED
        } else {
            mode == AppOpsManager.MODE_ALLOWED
        }
    }

    /** Launchable apps (other than this one) with size and usage history. */
    private fun installedApps(): List<Map<String, Any?>> {
        val pm = context.packageManager
        val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val packages = pm.queryIntentActivities(launcher, 0)
            .map { it.activityInfo.packageName }
            .toSet() - context.packageName
        val lastUsed = lastUsedTimes()
        val essential = essentialPackages()

        return packages.mapNotNull { pkg ->
            val info = try {
                pm.getPackageInfo(pkg, 0)
            } catch (e: PackageManager.NameNotFoundException) {
                return@mapNotNull null
            }
            val app: ApplicationInfo = info.applicationInfo ?: return@mapNotNull null
            val systemFlags = ApplicationInfo.FLAG_SYSTEM or ApplicationInfo.FLAG_UPDATED_SYSTEM_APP
            mapOf(
                "packageName" to pkg,
                "label" to pm.getApplicationLabel(app).toString(),
                "sizeBytes" to appSize(app),
                "installedAt" to info.firstInstallTime,
                "lastUsedAt" to lastUsed[pkg],
                "isSystem" to ((app.flags and systemFlags) != 0),
                "isEssential" to (pkg in essential),
            )
        }
    }

    /** Last time each app was in the foreground, over the last two years. */
    private fun lastUsedTimes(): Map<String, Long> {
        val usage = context.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        val now = System.currentTimeMillis()
        val twoYears = 2L * 365 * 24 * 60 * 60 * 1000
        return usage.queryAndAggregateUsageStats(now - twoYears, now)
            .mapValues { it.value.lastTimeUsed }
            .filterValues { it > 0 }
    }

    /** Apps that do their job without being opened, so never look "used". */
    private fun essentialPackages(): Set<String> {
        val result = mutableSetOf<String>()
        val home = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
        context.packageManager.resolveActivity(home, PackageManager.MATCH_DEFAULT_ONLY)
            ?.activityInfo?.packageName?.let(result::add)
        Settings.Secure.getString(context.contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD)
            ?.substringBefore('/')?.let(result::add)
        Telephony.Sms.getDefaultSmsPackage(context)?.let(result::add)
        return result
    }

    /** App + data size (needs usage access); falls back to the APK size. */
    private fun appSize(app: ApplicationInfo): Long {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                val stats = context.getSystemService(StorageStatsManager::class.java)
                    .queryStatsForPackage(app.storageUuid, app.packageName, Process.myUserHandle())
                return stats.appBytes + stats.dataBytes
            } catch (e: Exception) {
                // No usage access, or the package moved; use the APK size.
            }
        }
        return File(app.sourceDir).length()
    }
}
