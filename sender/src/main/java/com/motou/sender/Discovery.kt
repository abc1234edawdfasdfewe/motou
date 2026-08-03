package com.motou.sender

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo

/**
 * NSD 自动发现：找出局域网里所有广播 _motou._tcp 的墨水屏设备。
 * NsdManager 同时只能 resolve 一个服务，内部用队列串行解析。
 */
class Discovery(context: Context) {

    data class Found(val name: String, val host: String, val port: Int)

    /** 设备列表变化回调（线程不定，UI 操作自行切主线程） */
    var onChanged: ((List<Found>) -> Unit)? = null

    private val mgr = context.getSystemService(NsdManager::class.java)
    private val found = LinkedHashMap<String, Found>()
    private val pending = ArrayDeque<NsdServiceInfo>()
    private var resolvingActive = false
    private var listener: NsdManager.DiscoveryListener? = null

    @Synchronized
    private fun emit() {
        onChanged?.invoke(found.values.toList())
    }

    @Synchronized
    private fun resolveNext() {
        if (resolvingActive) return
        val info = pending.removeFirstOrNull() ?: return
        resolvingActive = true
        runCatching {
            mgr.resolveService(info, object : NsdManager.ResolveListener {
                override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                    synchronized(this@Discovery) {
                        resolvingActive = false
                        resolveNext()
                    }
                }

                override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                    val host = serviceInfo.host?.hostAddress
                    synchronized(this@Discovery) {
                        resolvingActive = false
                        if (host != null) {
                            found[serviceInfo.serviceName] =
                                Found(serviceInfo.serviceName, host, serviceInfo.port)
                            emit()
                        }
                        resolveNext()
                    }
                }
            })
        }.onFailure {
            synchronized(this) {
                resolvingActive = false
                resolveNext()
            }
        }
    }

    fun start() {
        if (listener != null) return
        val l = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) { stop() }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}

            override fun onServiceFound(info: NsdServiceInfo) {
                synchronized(this@Discovery) {
                    pending.addLast(info)
                    resolveNext()
                }
            }

            override fun onServiceLost(info: NsdServiceInfo) {
                synchronized(this@Discovery) {
                    if (found.remove(info.serviceName) != null) emit()
                }
            }
        }
        listener = l
        runCatching { mgr.discoverServices(NSD_TYPE, NsdManager.PROTOCOL_DNS_SD, l) }
    }

    fun stop() {
        listener?.let { runCatching { mgr.stopServiceDiscovery(it) } }
        listener = null
    }

    companion object {
        const val NSD_TYPE = "_motou._tcp."
    }
}
