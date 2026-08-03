package com.motou.sender

import android.app.Application
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.widget.Toast
import org.json.JSONObject

/**
 * 发送端 Application：持有全局 WS 连接，供 MainActivity 与 Chat/OCR 等页面共用。
 * 连接参数（设备 IP、分辨率、灰阶）集中在此，避免各页重复管理。
 */
class SenderApp : Application() {

    var ws: WsClient? = null
        private set
    var deviceW = 1404
        private set
    var deviceH = 1872
        private set
    var grayLevels = 16
        private set

    private val prefs by lazy { getSharedPreferences("motou.sender", MODE_PRIVATE) }
    private val mainHandler = Handler(Looper.getMainLooper())
    private var navListener: ((id: String, page: Int) -> Unit)? = null
    private var stateListener: ((m: JSONObject) -> Unit)? = null
    private var statusListener: ((connected: Boolean, desc: String) -> Unit)? = null

    /** 任何线程安全地弹 Toast。 */
    private fun toastSafe(msg: String) {
        mainHandler.post { Toast.makeText(this, msg, Toast.LENGTH_SHORT).show() }
    }

    /** 回调统一切到主线程，避免 WS 后台线程直接驱动 UI。 */
    private fun onMain(block: () -> Unit) = mainHandler.post(block)

    fun setHandlers(
        onNav: ((id: String, page: Int) -> Unit)?,
        onState: ((m: JSONObject) -> Unit)?,
        onStatus: ((connected: Boolean, desc: String) -> Unit)?
    ) {
        navListener = onNav
        stateListener = onState
        statusListener = onStatus
    }

    /** 当前已连接则直接回调，否则按已存 IP 发起连接。 */
    fun ensureConnected(ctx: Context, then: () -> Unit) {
        if (ws?.connected == true) {
            then()
            return
        }
        val ip = prefs.getString("deviceIp", "") ?: ""
        if (ip.isBlank()) {
            toastSafe("请先在「投送」页连接设备")
            return
        }
        connect(ip, then)
    }

    fun connect(ip: String, onConnected: (() -> Unit)? = null) {
        prefs.edit().putString("deviceIp", ip).apply()
        onMain { statusListener?.invoke(false, "连接中…") }
        val client = WsClient(object : WsClient.Listener {
            override fun onOpen() {}
            override fun onHello(m: JSONObject) {
                m.optJSONObject("screen")?.let {
                    deviceW = it.optInt("width", deviceW)
                    deviceH = it.optInt("height", deviceH)
                }
                grayLevels = m.optInt("grayscale", 16).coerceIn(2, 16)
                onMain {
                    statusListener?.invoke(true, "${m.optString("device")}（${deviceW}×${deviceH}）")
                    onConnected?.invoke()
                    // 续聊保活期间：重连成功后把会话重新投给设备，恢复聊天页
                    if (ChatLinkService.running) ChatStore.syncToDevice(this@SenderApp)
                }
            }
            override fun onNav(id: String, page: Int) {
                onMain { navListener?.invoke(id, page) }
            }
            override fun onState(m: JSONObject) {
                onMain { stateListener?.invoke(m) }
            }
            override fun onClosed(reason: String) {
                Log.w("MoTouWS", "closed: $reason, chatLink=${ChatLinkService.running}")
                onMain { statusListener?.invoke(false, reason) }
                // 锁屏 TCP 休眠断连：续聊保活期间自动重连，否则设备追问无人接收
                if (ChatLinkService.running) {
                    mainHandler.postDelayed({
                        if (ChatLinkService.running && ws?.connected != true) {
                            Log.i("MoTouWS", "reconnecting…")
                            connect(ip)
                        }
                    }, 3000)
                }
            }
            override fun onChatAsk(text: String) {
                // 墨水屏端追问：直接走共享枢纽调 LLM 并回投整段会话
                ChatStore.onDeviceAsk(this@SenderApp, text)
            }
            override fun onTextAsk(text: String) {
                onMain { handleTextAsk(text) }
            }
        })
        ws = client
        client.connect("ws://$ip:8383/channel")
    }

    override fun onTerminate() {
        ws?.close()
        super.onTerminate()
    }

    // ---------- 阅读页选中文字「问 AI」 ----------

    /** App 是否在前台（任一 Activity resumed 时置位）。 */
    @Volatile var inForeground = false

    override fun onCreate() {
        super.onCreate()
        var resumed = 0
        registerActivityLifecycleCallbacks(object : ActivityLifecycleCallbacks {
            override fun onActivityResumed(a: android.app.Activity) { resumed++; inForeground = true }
            override fun onActivityPaused(a: android.app.Activity) { if (--resumed <= 0) { resumed = 0; inForeground = false } }
            override fun onActivityCreated(a: android.app.Activity, s: android.os.Bundle?) {}
            override fun onActivityStarted(a: android.app.Activity) {}
            override fun onActivityStopped(a: android.app.Activity) {}
            override fun onActivitySaveInstanceState(a: android.app.Activity, s: android.os.Bundle) {}
            override fun onActivityDestroyed(a: android.app.Activity) {}
        })
    }

    private fun handleTextAsk(text: String) {
        if (text.isBlank()) return
        if (inForeground) {
            // 前台：直接弹提示词页
            val i = Intent(this, TextAskActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra(TextAskActivity.EXTRA_TEXT, text)
            runCatching { startActivity(i) }.onFailure { notifyTextAsk(text) }
        } else {
            notifyTextAsk(text)
        }
    }

    /** 后台/锁屏：发系统通知，点通知打开提示词页。 */
    private fun notifyTextAsk(text: String) {
        val nm = getSystemService(NOTIFICATION_SERVICE) as android.app.NotificationManager
        nm.createNotificationChannel(
            android.app.NotificationChannel("text_ask", "问 AI", android.app.NotificationManager.IMPORTANCE_HIGH)
        )
        val pi = android.app.PendingIntent.getActivity(
            this, 100,
            Intent(this, TextAskActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra(TextAskActivity.EXTRA_TEXT, text),
            android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE
        )
        val notif = android.app.Notification.Builder(this, "text_ask")
            .setContentTitle("墨水屏选中了一段文字")
            .setContentText("${text.take(40)}… 点开输入提示词问 AI")
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentIntent(pi)
            .setAutoCancel(true)
            .build()
        nm.notify(1001, notif)
    }
}
