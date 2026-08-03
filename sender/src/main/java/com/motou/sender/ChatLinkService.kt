package com.motou.sender

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder

/**
 * 墨水屏续聊保活：投屏整段对话后启动的前台服务。
 * 锁屏/退后台后进程不被冻结，设备端追问（chat.ask）仍能经 ChatStore 调 LLM 并回投。
 * 仅在「已投屏会话」期间存活，主动停止或断开即销毁。
 */
class ChatLinkService : Service() {

    companion object {
        @Volatile var running = false
            private set
        const val ACTION_STOP = "com.motou.sender.STOP_CHAT_LINK"

        fun start(ctx: Context) {
            if (running) return
            ctx.startForegroundService(Intent(ctx, ChatLinkService::class.java))
        }

        fun stop(ctx: Context) {
            ctx.startService(Intent(ctx, ChatLinkService::class.java).setAction(ACTION_STOP))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        val channelId = "chat_link"
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(NotificationChannel(channelId, "墨水屏续聊", NotificationManager.IMPORTANCE_MIN))
        val notif: Notification = Notification.Builder(this, channelId)
            .setContentTitle("墨投·墨水屏续聊中")
            .setContentText("在墨水屏上追问将持续得到回复")
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setOngoing(true)
            .build()
        if (android.os.Build.VERSION.SDK_INT >= 29) {
            startForeground(2, notif, android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(2, notif)
        }
        running = true
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }
}
