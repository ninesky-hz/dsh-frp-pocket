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
import android.os.PowerManager
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/**
 * 极小的原生桥：只提供 Flutter 侧拿不到的几件事
 *  - keepAwake       保持屏幕常亮（FLAG_KEEP_SCREEN_ON）
 *  - download        交给系统 DownloadManager 下载（带 Cookie）
 *  - openUrl         用系统浏览器打开链接（ACTION_VIEW）
 *  - notifyRoundDone 一轮答完发条通知（前台由 Flutter 侧画灵动岛，这里只管后台）
 *  - startTurnWatch  一轮在跑时挂前台服务，别让系统在后台把进程冻住
 *  - stopTurnWatch   这一轮结束了，把上面那个服务收掉
 *
 * 外加这条通知的权限面：`notificationStatus` / `requestNotificationPermission` /
 * `openNotificationSettings`——设置页靠它们显示「到底哪一层没开」。
 */
class MainActivity : FlutterActivity() {

    private val channelName = "com.ninesky.dsh_frp_app/native"

    /** 答完提醒的通道与通知 id。 */
    private val turnChannelId = "turn_done"
    private val turnNotificationId = 0x4453

    /**
     * 每发一条就换一个 id。
     *
     * 同一个 id 再 `notify` 属于「更新已有通知」：系统只改内容，**不会再弹一次横幅**
     * （用户点「试一下」第二下就毫无反应，答完提醒连着来两轮也只响第一下）。
     * 所以 id 按 0…63 循环递增，并记住最后一条，[cancelRoundDone] 用它撤。
     */
    private var turnNotificationSeq = 0
    private var lastTurnNotificationId = 0x4453

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
                        val focus = args?.get("focus") as? Boolean ?: false
                        result.success(notifyRoundDone(title, body, focus))
                    }

                    "startTurnWatch" -> {
                        val args = call.arguments as? Map<*, *>
                        val text = (args?.get("text") as? String)?.takeIf { it.isNotBlank() }
                        result.success(startTurnWatch(text))
                    }

                    "stopTurnWatch" -> result.success(stopTurnWatch())

                    "cancelRoundDone" -> {
                        try {
                            val manager =
                                getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                            manager.cancel(turnNotificationId)
                            manager.cancel(lastTurnNotificationId)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }

                    "notificationStatus" -> result.success(notificationStatus())

                    "requestNotificationPermission" -> requestNotificationPermission(result)

                    "openNotificationSettings" -> result.success(openNotificationSettings())

                    "focusStatus" -> result.success(focusStatus())

                    "batteryStatus" -> result.success(batteryStatus())

                    "requestIgnoreBatteryOptimizations" ->
                        result.success(requestIgnoreBatteryOptimizations())

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
     *  3. `focus=true` 时才顺手塞一份 MIUI/HyperOS「焦点通知」的 extras —— 系统认了
     *     就会画进顶部灵动岛，不认就当普通横幅（[applyFocusExtras]）。默认不发：
     *     没有 `miui.permission.USE_INTERNAL_GENERAL_API` 的第三方 App 塞了这些字段，
     *     有些 ROM 版本会整条丢掉，那样用户看到的就是「权限给了、通知没了」。
     */
    private fun notifyRoundDone(title: String, body: String, focus: Boolean): Boolean {
        val manager =
            getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (!ensureNotificationPermission()) {
            // 这一次没发出去：记下来，等授权框点完再补一条。
            // 之前是直接 return false —— 而这条路径几乎总在后台触发，
            // 后台根本弹不出授权框，于是「每一轮都丢」，用户看到的就是
            // 「权限也给了，后台就是不提醒」。
            pendingRoundDone = title to body
            return false
        }
        return try {
            ensureTurnChannel(manager)
            val notification = buildTurnNotification(title, body, focus)
            val id = nextTurnNotificationId()
            lastTurnNotificationId = id
            manager.notify(id, notification)
            true
        } catch (e: Exception) {
            false
        }
    }

    /** 因为没权限没发出去的那一条：授权成功后补发，别让人白等一轮。 */
    private var pendingRoundDone: Pair<String, String>? = null

    /** 每次换一个 id：同 id 更新不会重新弹横幅（见字段注释）。 */
    private fun nextTurnNotificationId(): Int {
        turnNotificationSeq = (turnNotificationSeq + 1) and 0x3F
        return turnNotificationId + turnNotificationSeq
    }

    /**
     * 挂一个前台服务把进程顶住，别让系统在后台把它冻住。
     *
     * 只在一轮对话开始（Flutter 侧收到 `turn/start`）时调，答完立刻 [stopTurnWatch]。
     * 调用点必须在 App 还在前台：Android 12+ 不允许从后台起前台服务。
     */
    private fun startTurnWatch(text: String?): Boolean {
        return try {
            val intent = Intent(this, TurnWatchService::class.java)
                .putExtra("text", text ?: "这一轮还没答完")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
            true
        } catch (e: Exception) {
            // 起不来（后台限制 / 系统策略）就算了：最多少一条后台提醒，不影响前台。
            false
        }
    }

    private fun stopTurnWatch(): Boolean {
        return try {
            stopService(Intent(this, TurnWatchService::class.java))
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
        // 刚才因为没权限被丢掉的那条提醒：现在能发了就补上，
        // 不然用户点完「允许」还得再等一整轮才知道通知是通的。
        val waiting = pendingRoundDone
        pendingRoundDone = null
        if (granted && waiting != null) {
            notifyRoundDone(waiting.first, waiting.second, true)
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
        // MIUI / HyperOS：「悬浮通知」（真正决定有没有横幅的那一档）藏在应用的通知页里，
        // 原生通知页进不去那么深，只能靠它自己的私有 action 直接送到位。
        candidates.add(
            Intent("miui.intent.action.APP_NOTIFICATION_SETTINGS")
                .putExtra("miui.intent.extra.APPLICATION_SETTINGS", true)
                .putExtra("app_package_name", packageName)
                .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
        )
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
    private fun buildTurnNotification(
        title: String,
        body: String,
        focus: Boolean
    ): Notification {
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
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            // 同一条通知再更新时也要再响一次：反正 id 每次都是新的，这条只是兜底。
            .setOnlyAlertOnce(false)
            .setColor(0xFF3DDC97.toInt())
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            // 8.0 以下没有通道，横幅只看 priority，给到 MAX 才会盖在屏幕上方弹出来。
            builder.setPriority(Notification.PRIORITY_MAX)
            builder.setDefaults(Notification.DEFAULT_ALL)
        }
        launchIntent()?.let { builder.setContentIntent(it) }
        val notification = builder.build()
        if (focus) applyFocusExtras(notification, title, body)
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
     * 小米 HyperOS 的「焦点通知 / 小米超级岛」。
     *
     * 官方文档（dev.mi.com/xiaomihyperos/documentation/detail?pId=2131）规定：照发普通
     * 通知，再往 `notification.extras` 里塞一个 **JSON 字符串** 键 `miui.focus.param`，
     * 内容形如 `{"param_v2": {...}}`。之前这里塞的是 Bundle，系统解不出来就整段忽略，
     * 所以一直只有普通通知。
     *
     * 还差一步是权限：焦点通知要在小米那边按包名开通（邮件申请），客户端可以用
     * `canShowFocus` 查当前有没有。没权限时 `filterWhenNoPermission` 默认 false，
     * 系统会把它当普通通知展示——但那样岛和状态栏都没有，所以先查再塞。
     */
    private fun applyFocusExtras(notification: Notification, title: String, body: String) {
        if (focusProtocolVersion() < 2 || !hasFocusPermission()) return
        try {
            notification.extras.putString(
                "miui.focus.param",
                buildFocusParamJson(title, body)
            )
        } catch (e: Exception) {
            // 组装失败就当普通通知发，绝不让提醒本身丢掉。
        }
    }

    /**
     * 系统支持到什么程度：0 不支持 / 1 OS1 焦点通知 / 2 OS2 焦点通知 / 3 OS3 超级岛。
     * OS1 那版要单独适配，官方也建议别再接，所以小于 2 一律当不支持。
     */
    private fun focusProtocolVersion(): Int {
        return try {
            Settings.System.getInt(contentResolver, "notification_focus_protocol", 0)
        } catch (e: Exception) {
            0
        }
    }

    /** 本应用有没有拿到焦点通知权限（小米按包名开通，未开通返回 false）。 */
    private fun hasFocusPermission(): Boolean {
        return try {
            val extras = Bundle().apply { putString("package", packageName) }
            val bundle = contentResolver.call(
                Uri.parse("content://miui.statusbar.notification.public"),
                "canShowFocus",
                null,
                extras
            )
            bundle?.getBoolean("canShowFocus", false) ?: false
        } catch (e: Exception) {
            false
        }
    }

    /**
     * 后台跑的资格：本应用有没有被放进「不受电池优化限制」名单。
     *
     * 为什么这一步是必须的：MIUI / HyperOS 会把后台进程直接冻住，冻住之后 Dart 侧
     * 的定时器不跑、WS 也断——前台服务只是「有资格活着」，真正决定它能不能醒着的是
     * 这个名单。`canAsk` 为假表示系统连这个对话框都不给（企业策略 / 旧版本），
     * 那就只能引导用户自己去设置里找。
     */
    private fun batteryStatus(): Map<String, Any> {
        val ignoring = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            try {
                val manager = getSystemService(Context.POWER_SERVICE) as PowerManager
                manager.isIgnoringBatteryOptimizations(packageName)
            } catch (e: Exception) {
                false
            }
        } else {
            true
        }
        return mapOf(
            "ignoring" to ignoring,
            "canAsk" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M),
        )
    }

    /**
     * 弹系统的「允许后台运行」框。
     *
     * 先试带包名的精确请求（一步到位）；这条 Intent 被 ROM 改掉时退回电池优化列表页，
     * 让用户自己点。两条都打不开就返回 false，Flutter 侧改说「去设置里手动找」。
     */
    private fun requestIgnoreBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
        try {
            val direct = Intent(
                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                Uri.parse("package:$packageName")
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(direct)
            return true
        } catch (e: Exception) {
            // 落到下面那条更保守的入口。
        }
        return try {
            val list = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(list)
            true
        } catch (e: Exception) {
            false
        }
    }

    /** 给 Flutter 侧看的状态，设置页据此说清楚「系统支持但没权限」还是「都就绪」。 */
    private fun focusStatus(): Map<String, Any> {
        val protocol = focusProtocolVersion()
        val canShow = protocol >= 2 && hasFocusPermission()
        return mapOf(
            "protocol" to protocol,
            "canShowFocus" to canShow,
            "supported" to (protocol >= 2),
            "island" to (protocol >= 3)
        )
    }

    /**
     * 按官方 `param_v2` 结构拼一串 JSON。
     *
     * 只放纯文本：`ticker`/`aodTitle` 是状态栏与息屏必填，`baseInfo` 是通知本体，
     * `param_island` 里的两块区域用官方示例的文本组件（`miui.focus.paramtextInfo`）。
     * 没带图片也就不需要 `miui.focus.pics`。
     */
    private fun buildFocusParamJson(title: String, body: String): String {
        val param = JSONObject()
        param.put("protocol", 1)
        // 一次性提醒：60 分钟没点就自己消失，岛 60 秒后退场。
        param.put("timeout", 60)
        param.put("enableFloat", true)
        param.put("islandFirstFloat", true)
        param.put("updatable", false)
        param.put("filterWhenNoPermission", false)
        param.put("ticker", body)
        param.put("aodTitle", title)

        param.put(
            "baseInfo",
            JSONObject()
                .put("title", title)
                .put("content", body)
                .put("type", 2)
        )

        val textInfo = JSONObject()
            .put("frontTitle", "")
            .put("title", title)
            .put("content", body)
            .put("useHighLight", false)

        val island = JSONObject()
            .put("islandProperty", 1)
            .put("islandTimeout", 60)
            .put("bigIslandArea", JSONObject().put("miui.focus.paramtextInfo", textInfo))
            .put("smallIslandArea", JSONObject().put("miui.focus.paramtextInfo", textInfo))
        param.put("param_island", island)

        return JSONObject().put("param_v2", param).toString()
    }
}
