package __PACKAGE__

// DataMuncher Android code for unused app detection (DAT-25).
// Installed by `dart run tool/setup_platforms.dart`, which fills in the
// package line above. Edit the copy in tool/android/, not the generated one.

import android.app.AppOpsManager
import android.app.usage.StorageStatsManager
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.provider.Settings
import android.provider.Telephony
import android.telecom.TelecomManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val worker = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    // Uninstall in progress: package name and the Dart call waiting for it.
    private var pendingUninstall: Pair<String, MethodChannel.Result>? = null
    private var leftForUninstall = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasUsageAccess" -> result.success(hasUsageAccess())
                    "openUsageAccessSettings" -> {
                        openUsageAccessSettings()
                        result.success(null)
                    }
                    "listApps" -> inBackground(result) { listApps() }
                    "appIcon" -> {
                        val pkg = call.argument<String>("packageName")
                        if (pkg == null) {
                            result.error("bad_args", "packageName is required", null)
                        } else {
                            inBackground(result) { appIcon(pkg) }
                        }
                    }
                    "uninstall" -> {
                        val pkg = call.argument<String>("packageName")
                        if (pkg == null) {
                            result.error("bad_args", "packageName is required", null)
                        } else {
                            startUninstall(pkg, result)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onPause() {
        super.onPause()
        if (pendingUninstall != null) leftForUninstall = true
    }

    override fun onResume() {
        super.onResume()
        val pending = pendingUninstall
        if (pending != null && leftForUninstall) {
            pendingUninstall = null
            leftForUninstall = false
            // Android can take a moment to finish removing the package after
            // its dialog closes, so check a few times before saying no.
            finishUninstall(pending.first, pending.second, attemptsLeft = 10)
        }
    }

    override fun onDestroy() {
        worker.shutdown()
        super.onDestroy()
    }

    // ---- Usage access ------------------------------------------------------

    private fun hasUsageAccess(): Boolean {
        val ops = getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val mode = checkUsageOp(ops)
        if (mode == AppOpsManager.MODE_DEFAULT) {
            return checkCallingOrSelfPermission(android.Manifest.permission.PACKAGE_USAGE_STATS) ==
                PackageManager.PERMISSION_GRANTED
        }
        return mode == AppOpsManager.MODE_ALLOWED
    }

    @Suppress("DEPRECATION")
    private fun checkUsageOp(ops: AppOpsManager): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ops.unsafeCheckOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), packageName)
        } else {
            ops.checkOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), packageName)
        }

    private fun openUsageAccessSettings() {
        // Jump straight to DataMuncher's switch where the phone supports it.
        val direct = Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS, Uri.parse("package:$packageName"))
        try {
            startActivity(direct)
        } catch (e: Exception) {
            startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS))
        }
    }

    // ---- Installed apps ----------------------------------------------------

    private fun listApps(): List<Map<String, Any?>> {
        val pm = packageManager
        val lastUsed = lastUsedTimes()
        val essential = essentialPackages()
        val launchable = launchablePackages()

        return installedApplications()
            .filter { it.packageName != packageName }
            .map { ai ->
                val pkg = ai.packageName
                mapOf(
                    "packageName" to pkg,
                    "label" to pm.getApplicationLabel(ai).toString(),
                    "sizeBytes" to sizeOf(ai),
                    "installedAt" to firstInstallTime(pkg),
                    "lastUsedAt" to lastUsed[pkg],
                    "isSystem" to ((ai.flags and ApplicationInfo.FLAG_SYSTEM) != 0),
                    // No launcher icon (keyboards, widgets, services) or a default
                    // role app: they work without being opened.
                    "isEssential" to (pkg in essential || pkg !in launchable),
                )
            }
    }

    /** Last time each package was on screen, from Android's usage history. */
    private fun lastUsedTimes(): Map<String, Long> {
        if (!hasUsageAccess()) return emptyMap()
        val usm = getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        val now = System.currentTimeMillis()
        val stats = usm.queryAndAggregateUsageStats(now - HISTORY_MS, now)
        val times = HashMap<String, Long>()
        for ((pkg, s) in stats) {
            var t = s.lastTimeUsed
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) t = maxOf(t, s.lastTimeVisible)
            if (t > 0) times[pkg] = t
        }
        return times
    }

    private fun essentialPackages(): Set<String> {
        val set = HashSet<String>()
        resolveHome()?.activityInfo?.packageName?.let { set.add(it) }
        Telephony.Sms.getDefaultSmsPackage(this)?.let { set.add(it) }
        Settings.Secure.getString(contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD)
            ?.substringBefore('/')
            ?.let { set.add(it) }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            (getSystemService(Context.TELECOM_SERVICE) as? TelecomManager)
                ?.defaultDialerPackage
                ?.let { set.add(it) }
        }
        return set
    }

    @Suppress("DEPRECATION")
    private fun installedApplications(): List<ApplicationInfo> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.getInstalledApplications(PackageManager.ApplicationInfoFlags.of(0))
        } else {
            packageManager.getInstalledApplications(0)
        }

    @Suppress("DEPRECATION")
    private fun launchablePackages(): Set<String> {
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val found: List<ResolveInfo> =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                packageManager.queryIntentActivities(intent, PackageManager.ResolveInfoFlags.of(0))
            } else {
                packageManager.queryIntentActivities(intent, 0)
            }
        return found.map { it.activityInfo.packageName }.toSet()
    }

    @Suppress("DEPRECATION")
    private fun resolveHome(): ResolveInfo? {
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.resolveActivity(
                intent,
                PackageManager.ResolveInfoFlags.of(PackageManager.MATCH_DEFAULT_ONLY.toLong()),
            )
        } else {
            packageManager.resolveActivity(intent, PackageManager.MATCH_DEFAULT_ONLY)
        }
    }

    @Suppress("DEPRECATION")
    private fun firstInstallTime(pkg: String): Long? = try {
        val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.getPackageInfo(pkg, PackageManager.PackageInfoFlags.of(0))
        } else {
            packageManager.getPackageInfo(pkg, 0)
        }
        info.firstInstallTime
    } catch (e: Exception) {
        null
    }

    /** App, data and cache. Falls back to just the app file. */
    private fun sizeOf(ai: ApplicationInfo): Long {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                val ssm = getSystemService(Context.STORAGE_STATS_SERVICE) as StorageStatsManager
                val s = ssm.queryStatsForPackage(ai.storageUuid, ai.packageName, Process.myUserHandle())
                return s.appBytes + s.dataBytes + s.cacheBytes
            } catch (e: Exception) {
                // Needs usage access; fall through.
            }
        }
        return try {
            File(ai.sourceDir).length()
        } catch (e: Exception) {
            0L
        }
    }

    private fun appIcon(pkg: String): ByteArray? = try {
        val drawable = packageManager.getApplicationIcon(pkg)
        val bitmap = Bitmap.createBitmap(ICON_PX, ICON_PX, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, ICON_PX, ICON_PX)
        drawable.draw(canvas)
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
        out.toByteArray()
    } catch (e: Exception) {
        null
    }

    // ---- Uninstall ---------------------------------------------------------

    private fun startUninstall(pkg: String, result: MethodChannel.Result) {
        when {
            pendingUninstall != null ->
                result.error("busy", "Another uninstall is still waiting for an answer", null)
            !isInstalled(pkg) -> result.success(true)
            else -> {
                pendingUninstall = pkg to result
                leftForUninstall = false
                try {
                    // Android shows its own "Do you want to uninstall?" dialog.
                    startActivity(Intent(Intent.ACTION_DELETE, Uri.parse("package:$pkg")))
                } catch (e: Exception) {
                    pendingUninstall = null
                    result.error("failed", e.message, null)
                }
            }
        }
    }

    private fun finishUninstall(pkg: String, result: MethodChannel.Result, attemptsLeft: Int) {
        if (!isInstalled(pkg)) {
            result.success(true)
        } else if (attemptsLeft <= 0) {
            result.success(false)
        } else {
            mainHandler.postDelayed({ finishUninstall(pkg, result, attemptsLeft - 1) }, 300)
        }
    }

    @Suppress("DEPRECATION")
    private fun isInstalled(pkg: String): Boolean = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.getPackageInfo(pkg, PackageManager.PackageInfoFlags.of(0))
        } else {
            packageManager.getPackageInfo(pkg, 0)
        }
        true
    } catch (e: PackageManager.NameNotFoundException) {
        false
    }

    // ---- Helpers -----------------------------------------------------------

    private fun <T> inBackground(result: MethodChannel.Result, work: () -> T) {
        worker.execute {
            try {
                val value = work()
                mainHandler.post { result.success(value) }
            } catch (e: Exception) {
                mainHandler.post { result.error("failed", e.message, null) }
            }
        }
    }

    companion object {
        private const val CHANNEL = "datamuncher/apps"
        private const val ICON_PX = 96

        // Android keeps usage history for about two years.
        private const val HISTORY_MS = 2L * 365 * 24 * 60 * 60 * 1000
    }
}
