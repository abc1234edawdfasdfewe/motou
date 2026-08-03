package com.motou.app.util

import java.net.Inet4Address
import java.net.NetworkInterface
import java.util.Collections

object Net {

    /** 取第一个非回环、site-local 的 IPv4 地址（局域网 IP）。 */
    fun localIp(): String? = runCatching {
        NetworkInterface.getNetworkInterfaces()
            ?.let { Collections.list(it) }
            ?.flatMap { Collections.list(it.inetAddresses) }
            ?.firstOrNull { !it.isLoopbackAddress && it is Inet4Address && it.isSiteLocalAddress }
            ?.hostAddress
    }.getOrNull()
}
