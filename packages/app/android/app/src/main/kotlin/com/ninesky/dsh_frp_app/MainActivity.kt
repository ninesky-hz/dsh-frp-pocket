package com.ninesky.dsh_frp_app

import android.app.DownloadManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 极小的原生桥：只提供 Flutter 侧拿不到的三件事
 *  - keepAwake 保持屏幕常亮（FLAG_KEEP_SCREEN_ON）
 *  - download  交给系统 DownloadManager 下载（带 Cookie）
 *  - openUrl   用系统浏览器打开链接（ACTION_VIEW）
 */
class MainActivity : FlutterActivity() {

    private val channelName = "com.ninesky.dsh_frp_app/native"

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
}
