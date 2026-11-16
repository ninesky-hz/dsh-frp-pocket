package com.ninesky.dsh_frp_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder

/**
 * 一轮对话在跑的时候挂一个前台服务。
 *
 * 为什么需要它：Android 会把后台进程冻住（MIUI / HyperOS 尤其积极），进程一冻，
 * WebSocket 就收不到 `turn/end`，于是「答完提醒」永远等不到触发点——用户看到的
 * 症状就是「权限也给了，就是不弹」。
 *
 * 这个服务不干别的活，只做一件事：让进程在后台保持活跃，把连接拖到这一轮结束。
 * 通道用 IMPORTANCE_LOW：静默、不上横幅，答完由 [MainActivity] 撤掉。
 */
class TurnWatchService : Service() {

    private val channelId = "turn_watch"
    private val notificationId = 0x4455

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val text = intent?.getStringExtra(EXTRA_TEXT)?.takeIf { it.isNotBlank() }
            ?: "这一轮还没答完"
        try {
            startForeground(notificationId, build(text))
        } catch (e: Exception) {
            // 拿不到前台资格（系统限制了 FGS / 没有通知权限）：别崩，直接收摊。
            stopSelf()
            return START_NOT_STICKY
        }
        // 不用 STICKY：进程真被杀之后重拉起来也接不回那条连接，只会留下一条
        // 撤不掉的「正在等」。下次打开 App 会重新挂。
        return START_NOT_STICKY
    }

    private fun build(text: String): Notification {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            manager.getNotificationChannel(channelId) == null
        ) {
            val channel = NotificationChannel(
                channelId,
                "任务进行中",
                NotificationManager.IMPORTANCE_LOW
            )
            channel.description = "一轮对话答完之前挂着的常驻通知，答完自动消失"
            channel.setShowBadge(false)
            channel.enableVibration(false)
            manager.createNotificationChannel(channel)
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, channelId)
        } else {
            Notification.Builder(this)
        }
        builder
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle("正在等这一轮答完")
            .setContentText(text)
            .setOngoing(true)
            .setShowWhen(false)
        launchIntent()?.let { builder.setContentIntent(it) }
        return builder.build()
    }

    /** 点常驻通知回到 App（singleTop，不会叠出第二个实例）。 */
    private fun launchIntent(): PendingIntent? {
        val intent = packageManager.getLaunchIntentForPackage(packageName) ?: return null
        intent.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        return PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    companion object {
        private const val EXTRA_TEXT = "text"
    }
}
