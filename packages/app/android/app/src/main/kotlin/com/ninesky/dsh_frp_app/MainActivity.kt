package com.ninesky.dsh_frp_app

import android.Manifest
import android.app.DownloadManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 极小的原生桥：只提供 Flutter 侧拿不到的四件事
 *  - keepAwake       保持屏幕常亮（FLAG_KEEP_SCREEN_ON）
 *  - download        交给系统 DownloadManager 下载（带 Cookie）
 *  - openUrl         用系统浏览器打开链接（ACTION_VIEW）
 *  - notifyRoundDone 一轮答完发条通知（前台由 Flutter 侧画灵动岛，这里只管后台）
 *
 * 外加这条通知的权限面：`notificationStatus` / `requestNotificationPermission` /
 * `openNotificationSettings`——设置页靠它们显示「到底哪一层没开」。
 */
class MainActivity : FlutterActivity() {

    private val channelName = "com.ninesky.dsh_frp_app/native"

    /** 答完提醒的通道与通知 id：同一个 id 反复用，新一轮直接顶掉上一轮。 */
    private val turnChannelId = "turn_done"
    private val turnNotificationId = 0x4453

    /** 通知权限的请求码，与上面那个 id 错开，别让两件事的回调撞车。 */
    private val notificationRequestCode = 0x4454

    /** 授权框还开着时挂在这；用户点完按钮，系统回调再把它兑现成返回值。 */
    private var pendingPermission: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "keepAwake" -> {
                        val enabled = call.arguments as? Boolean ?: false
                        runOnUiThread {
                            if (enabled) {
                                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            } else {
                                window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            }
                        }
                        result.success(true)
                    }

                    "download" -> {
                        val args = call.arguments as? Map<*, *>
                        val url = args?.get("url") as? String
                        if (url.isNullOrEmpty()) {
                            result.error("bad_args", "url is empty", null)
                        } else {
                            val ok = enqueueDownload(
                                url = url,
                                filename = args?.get("filename") as? String,
                                mimeType = args?.get("mimeType") as? String,
                                cookie = args?.get("cookie") as? String
                            )
                            result.success(ok)
                        }
                    }

                    "openUrl" -> {
                        val url = call.arguments as? String
                        if (url.isNullOrEmpty()) {
                            result.error("bad_args", "url is empty", null)
                        } else {
                            result.success(openInBrowser(url))
                        }
                    }

                    "notifyRoundDone" -> {
                        val args = call.arguments as? Map<*, *>
                        val title = (args?.get("title") as? String)?.takeIf { it.isNotBlank() }
                            ?: appLabel()
                        val body = (args?.get("body") as? String)?.takeIf { it.isNotBlank() }
                            ?: "这一轮已答完"
                        result.success(notifyRoundDone(title, body))
                    }

                    "cancelRoundDone" -> {
                        try {
                            val manager =
                                getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                            manager.cancel(turnNotificationId)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }

                    "notificationStatus" -> result.success(notificationStatus())

                    "requestNotificationPermission" -> requestNotificationPermission(result)

                    "openNotificationSettings" -> result.success(openNotificationSettings())

                    else -> result.notImplemented()
                }
            }
    }

    /** 用系统浏览器打开链接；没有可用的 Activity 时返回 false，交给 Flutter 侧降级。 */
    private fun openInBrowser(url: String): Boolean {
        return try {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun enqueueDownload(
        url: String,
        filename: String?,
        mimeType: String?,
        cookie: String?
    ): Boolean {
        return try {
            val request = DownloadManager.Request(Uri.parse(url))
            request.setNotificationVisibility(
                DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED
            )
            request.setAllowedOverMetered(true)
            if (!filename.isNullOrEmpty()) {
                request.setTitle(filename)
            }
            if (!mimeType.isNullOrEmpty()) {
                request.setMimeType(mimeType)
            }
            if (!cookie.isNullOrEmpty()) {
                request.addRequestHeader("Cookie", cookie)
            }
            val manager =
                getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
            manager.enqueue(request)
            true
        } catch (e: Exception) {
            false
        }
    }

    /** App 自己的名字，标题为空时兜底。 */
    private fun appLabel(): String {
        return try {
            packageManager.getApplicationLabel(applicationInfo).toString()
        } catch (e: Exception) {
            "DSH 口袋隧道"
        }
    }

    /**
     * 「一轮答完」的系统通知。
     *
     * 只有 App 在后台时才会走到这里（前台由 Flutter 侧的灵动岛负责）。三件事：
     *  1. Android 13+ 没给通知权限就顺手要一次，这一条先不发（返回 false）；
     *  2. 通道用 IMPORTANCE_HIGH，横幅 + 声音，别做成静默弹一下就沉进列表；
     *  3. 顺手塞一份 MIUI/HyperOS「焦点通知」的 extras —— 系统认了就会画进顶部
     *     灵动岛，不认就当普通横幅，不影响任何逻辑（[applyFocusExtras]）。
     */
    private fun notifyRoundDone(title: String, body: String): Boolean {
        val manager =
            getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (!ensureNotificationPermission()) return false
        return try {
            ensureTurnChannel(manager)
            val notification = buildTurnNotification(title, body)
            manager.notify(turnNotificationId, notification)
            true
        } catch (e: Exception) {
            false
        }
    }

    /** Android 13+ 的运行时通知权限：没给就当场要一次，结果由用户决定。 */
    private fun ensureNotificationPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        val granted = checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        if (granted) return true
        try {
            markNotificationPermissionAsked()
            requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                notificationRequestCode
            )
        } catch (e: Exception) {
            // 要权限都失败（比如没有 Activity 窗口）就认了：这一条不发。
        }
        return false
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != notificationRequestCode) return
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        val pending = pendingPermission
        pendingPermission = null
        try {
            pending?.success(granted)
        } catch (e: Exception) {
            // 发起申请的那个页面已经没了，没人等这个结果。
        }
    }

    /**
     * 设置页那行「系统通知权限」问的就是这个：权限位 + 系统总开关 + 通道。
     *
     * 三者任何一个不对，通知都出不来，但用户看到的症状都一样（「没提醒」），
     * 所以一次查全，让 UI 直接说清是哪一层的问题。
     */
    private fun notificationStatus(): Map<String, Any> {
        val granted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
        var appEnabled = true
        var channelReady = true
        var importance = -1
        try {
            val manager =
                getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            // 这两个都是较新 API（24 / 26），老系统上不调，别用 try-catch 去接
            // NoSuchMethodError——它是 Error 不是 Exception。
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                appEnabled = manager.areNotificationsEnabled()
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = manager.getNotificationChannel(turnChannelId)
                if (channel != null) {
                    importance = channel.importance
                    channelReady = channel.importance != NotificationManager.IMPORTANCE_NONE
                }
            }
        } catch (e: Exception) {
            // 查不到就按「没关」算：查询失败不该被显示成故障。
        }
        return mapOf(
            "platform" to Build.VERSION.SDK_INT,
            "granted" to granted,
            "canAsk" to canAskNotificationPermission(granted),
            "appNotificationsEnabled" to appEnabled,
            "channelReady" to channelReady,
            "channelImportance" to importance
        )
    }

    /**
     * 还能不能再弹一次授权框。
     *
     * `shouldShowRequestPermissionRationale` 在「从没问过」和「点了不再询问」两种
     * 情况下都返回 false，光看它分不清这两种。所以另记一个「问过没」：没问过 → 能问；
     * 问过但系统仍建议解释 → 还能问；否则只剩手动去设置这条路。
     */
    private fun canAskNotificationPermission(granted: Boolean): Boolean {
        if (granted) return false
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return false
        if (!notificationPermissionAsked()) return true
        return try {
            shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS)
        } catch (e: Exception) {
            false
        }
    }

    private fun notificationPrefs() = getPreferences(Context.MODE_PRIVATE)

    private fun notificationPermissionAsked(): Boolean {
        return try {
            notificationPrefs().getBoolean("notif_asked", false)
        } catch (e: Exception) {
            // 读不出来就当成「问过了」，至少不会每次进设置都弹框。
            true
        }
    }

    private fun markNotificationPermissionAsked() {
        try {
            notificationPrefs().edit().putBoolean("notif_asked", true).apply()
        } catch (e: Exception) {
            // 记不住就算了，最多下次多问一遍。
        }
    }

    /**
     * 设置页点「去申请」时走这里：先挂起返回值，等用户点完按钮再由
     * [onRequestPermissionsResult] 兑现。
     *
     * 同时只能有一次在等；旧的按 false 收掉，免得两条结果互相覆盖。
     */
    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(true)
            return
        }
        val granted = checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        if (granted) {
            result.success(true)
            return
        }
        if (!canAskNotificationPermission(false)) {
            // 系统已经不弹框了：告诉 Flutter 侧「这次没戏」，它会把按钮换成跳设置。
            result.success(false)
            return
        }
        try {
            pendingPermission?.success(false)
        } catch (e: Exception) {
            // 上一个调用方早断了。
        }
        pendingPermission = result
        try {
            markNotificationPermissionAsked()
            requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                notificationRequestCode
            )
        } catch (e: Exception) {
            pendingPermission = null
            result.success(false)
        }
    }

    /** 跳到系统的「本应用通知设置」页；老系统上退到应用详情页。 */
    private fun openNotificationSettings(): Boolean {
        val candidates = ArrayList<Intent>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            candidates.add(
                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                    .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
            )
        }
        candidates.add(
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                .setData(Uri.parse("package:$packageName"))
        )
        for (intent in candidates) {
            try {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
                return true
            } catch (e: Exception) {
                // 这版 ROM 没有这个页面，试下一个。
            }
        }
        return false
    }

    /** 通道只建一次；已存在时改不动重要性，所以重要性从一开始就定成 HIGH。 */
    private fun ensureTurnChannel(manager: NotificationManager) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        if (manager.getNotificationChannel(turnChannelId) != null) return
        val channel = NotificationChannel(
            turnChannelId,
            "答完提醒",
            NotificationManager.IMPORTANCE_HIGH
        )
        channel.description = "一轮对话答完之后提醒你回来看结果"
        channel.enableVibration(true)
        channel.setShowBadge(true)
        manager.createNotificationChannel(channel)
    }

    @Suppress("DEPRECATION")
    private fun buildTurnNotification(title: String, body: String): Notification {
        val context = applicationContext
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, turnChannelId)
        } else {
            Notification.Builder(context)
        }
        builder
            // 系统自带的聊天图标：小图标要单色剪影，用 launcher 贴上去会是块花方块。
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setWhen(System.currentTimeMillis())
            .setShowWhen(true)
            .setAutoCancel(true)
            .setColor(0xFF3DDC97.toInt())
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            builder.setPriority(Notification.PRIORITY_HIGH)
        }
        launchIntent()?.let { builder.setContentIntent(it) }
        val notification = builder.build()
        applyFocusExtras(notification, title, body)
        return notification
    }

    /** 点通知回到 App（singleTop，不会叠出第二个实例）。 */
    private fun launchIntent(): PendingIntent? {
        val intent = packageManager.getLaunchIntentForPackage(packageName) ?: return null
        intent.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        return PendingIntent.getActivity(
            applicationContext,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    /**
     * 小米 HyperOS / MIUI 的「焦点通知」。
     *
     * 没有公开 API：系统读的是通知 extras 里那几个约定字段，读到了就把它画进顶部
     * 灵动岛区（`enableFloat`），读不到就退回普通横幅。字段名各家 ROM 版本略有差异，
     * 所以整段包在 try 里，任何异常都当「这版系统不认」，不影响通知本体。
     */
    private fun applyFocusExtras(notification: Notification, title: String, body: String) {
        try {
            val focus = Bundle()
            focus.putString("protocol", "1")
            focus.putBoolean("enableFloat", true)
            focus.putString("ticker", body)
            focus.putString("tickerTitle", title)
            focus.putInt("updatableVersion", 1)
            notification.extras.putBundle("miui.focus.param", focus)
            notification.extras.putBoolean("miui.focus.notification", true)
            notification.extras.putInt("miui.focus.pic_color", 0xFF3DDC97.toInt())
        } catch (e: Exception) {
            // 系统不认这些 extras：当普通通知发，什么都不用做。
        }
    }
}
