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
 */
class MainActivity : FlutterActivity() {

    private val channelName = "com.ninesky.dsh_frp_app/native"

    /** 答完提醒的通道与通知 id：同一个 id 反复用，新一轮直接顶掉上一轮。 */
    private val turnChannelId = "turn_done"
    private val turnNotificationId = 0x4453

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
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 0x4453)
        } catch (e: Exception) {
            // 要权限都失败（比如没有 Activity 窗口）就认了：这一条不发。
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
