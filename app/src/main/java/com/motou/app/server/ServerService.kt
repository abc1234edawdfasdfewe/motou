package com.motou.app.server

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.IBinder
import com.motou.app.R
import com.motou.app.util.Net

/** 前台服务：持有内置服务器，保证退到后台/熄屏后仍可接收投送。 */
class ServerService : Service() {

    private var server: MoTouServer? = null
    private var nsdManager: NsdManager? = null
    private var nsdListener: NsdManager.RegistrationListener? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
        val ip = Net.localIp() ?: "未连接WiFi"
        val notification = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("墨投正在接收")
            .setContentText("http://$ip:8383")
            .setSmallIcon(R.drawable.ic_launcher)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIF_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIF_ID, notification)
        }
        server = MoTouServer(applicationContext).also { it.start() }
        registerNsd()
    }

    /** 局域网广播自己，发送端（手机/网页端未来）可免输 IP 自动发现。 */
    private fun registerNsd() {
        val info = NsdServiceInfo().apply {
            serviceName = "MoTou-${Build.MODEL}"
            serviceType = NSD_TYPE
            port = 8383
            setAttribute("model", Build.MODEL)
        }
        val mgr = getSystemService(NsdManager::class.java) ?: return
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {}
            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {}
            override fun onServiceUnregistered(info: NsdServiceInfo) {}
            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) {}
        }
        runCatching { mgr.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener) }
            .onSuccess {
                nsdManager = mgr
                nsdListener = listener
            }
    }

    override fun onDestroy() {
        nsdListener?.let { l -> runCatching { nsdManager?.unregisterService(l) } }
        nsdListener = null
        nsdManager = null
        server?.stop()
        server = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID, "投送服务", NotificationManager.IMPORTANCE_LOW
        ).apply { setShowBadge(false) }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    companion object {
        private const val CHANNEL_ID = "cast"
        private const val NOTIF_ID = 1
        /** NSD 服务类型（发送端按此发现设备） */
        const val NSD_TYPE = "_motou._tcp."
    }
}
