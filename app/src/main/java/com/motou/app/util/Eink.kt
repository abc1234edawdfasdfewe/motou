package com.motou.app.util

import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

/**
 * Rockchip 墨水屏管理接口封装（M4 实时投送的关键能力）。
 *
 * 真机（rk3576_ebook, Android 14 userdebug）探测结论：
 * - boot framework 内置 android.os.EinkManager，签名见 android/os/EinkManager.java 编译期 stub；
 * - 反射实例化被隐藏 API 策略拦截（构造器/字段枚举为空），改为 stub 直连（编译期骗过 SDK、
 *   运行时由 bootclasspath 真身接管，与 weread/起点墨水屏版同路）；
 * - 模式即字符串常量（EPD_A2="12"、EPD_DU="14"、EPD_FULL_GC16="2"、EPD_AUTO="0"），
 *   对应 sys.ebook.mode 系统属性；模式在息屏/亮屏切换后会被系统重置回默认（9），
 *   因此每次进入实时投送都要重新 setMode，退出时恢复。
 */
object Eink {

    private const val TAG = "MoTou.Eink"

    /** 常用模式（完整列表见 stub 的 EinkMode）。 */
    const val MODE_AUTO = "0"
    const val MODE_FULL_GC16 = "2"
    const val MODE_A2 = "12"
    const val MODE_A2_DITHER = "13"
    const val MODE_DU = "14"

    private var manager: android.os.EinkManager? = null
    private var binder: android.os.IBinder? = null
    private var initialized = false
    private var lastError: String? = null

    /** IEinkManager 事务码（root 下 service call 穷举实测）：setProperty(String,String)=5。 */
    private const val EINK_DESC = "android.os.IEinkManager"
    private const val TX_SET_PROPERTY = 5

    /** 闪屏测试挂钩：MainActivity 注册，/debug/eink?flash=N 触发（主线程执行）。 */
    @Volatile
    var flashHook: ((Int) -> Unit)? = null

    @Synchronized
    private fun init(): Boolean {
        if (initialized) return binder != null || manager != null
        initialized = true
        // 写通道：eink 系统服务 binder，直接 transact（公开 API，绕开隐藏 API 过滤——
        // asInterface/Proxy 构造器均被过滤，只能手写 Parcel）
        try {
            binder = android.os.ServiceManager.getService("eink")
            Log.i(TAG, "eink binder: ${binder != null}")
        } catch (t: Throwable) {
            lastError = "binder: $t"
            Log.w(TAG, "getService(eink) failed", t)
        }
        // 读通道：EinkManager 门面的 getMode()（JNI 直读，不经服务）
        try {
            manager = android.os.EinkManager()
            runCatching { manager!!.init() }
        } catch (t: Throwable) {
            Log.w(TAG, "EinkManager() failed: $t")
        }
        return binder != null || manager != null
    }

    fun isAvailable(): Boolean = init()

    /** 当前模式字符串（如 "9"），失败返回错误描述。 */
    fun getMode(): String {
        if (!init()) return "unavailable: $lastError"
        val m = manager ?: return "no manager"
        return runCatching { m.mode ?: "null" }
            .getOrElse { "error: $it" }
    }

    /** 设置刷新模式（传字符串常量，如 Eink.MODE_A2="12"）。 */
    fun setMode(mode: String): Boolean {
        if (!init()) { lastError = "unavailable: $lastError"; return false }
        val b = binder ?: run { lastError = "no binder"; return false }
        return runCatching {
            val data = android.os.Parcel.obtain()
            val reply = android.os.Parcel.obtain()
            try {
                data.writeInterfaceToken(EINK_DESC)
                data.writeString("sys.ebook.mode")
                data.writeString(mode)
                b.transact(TX_SET_PROPERTY, data, reply, 0)
                reply.readException()
            } finally {
                data.recycle()
                reply.recycle()
            }
            Log.i(TAG, "setMode($mode) ok via transact, getMode()=${getMode()}")
            true
        }.getOrElse {
            lastError = it.toString()
            Log.w(TAG, "setMode($mode) failed", it)
            false
        }
    }

    /** 触发一次全屏全刷（清残影）。 */
    fun sendFullFrame(): Boolean {
        if (!init()) return false
        return runCatching { manager!!.sendOneFullFrame(); true }
            .getOrElse { lastError = it.toString(); false }
    }

    /** 诊断报告：直连状态、当前模式 + 反射转储的类形态（供对照排障）。 */
    fun diagnose(): JSONObject {
        val available = init()
        val out = JSONObject()
            .put("available", available)
            .put("error", lastError ?: JSONObject.NULL)
            .put("currentMode", if (available) getMode() else JSONObject.NULL)
        runCatching {
            val cls = Class.forName("android.os.EinkManager")
            val methods = JSONArray()
            cls.declaredMethods.sortedBy { it.name }.forEach { mm ->
                methods.put(
                    java.lang.reflect.Modifier.toString(mm.modifiers) + " " +
                        mm.name + "(" + mm.parameterTypes.joinToString(",") { it.simpleName } + "):" + mm.returnType.simpleName
                )
            }
            out.put("methods", methods)
        }
        return out
    }
}
