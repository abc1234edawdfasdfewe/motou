package com.motou.sender

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.view.accessibility.AccessibilityEvent

/**
 * 反向控制注入服务：经系统无障碍 API dispatchGesture 把墨水屏回传的点按/滑动
 * 注入到手机当前前台应用。用户需在系统设置中手动开启一次（无法代码代办）。
 */
class TouchService : AccessibilityService() {

    companion object {
        /** 非 null = 无障碍已开启且服务已连接 */
        @Volatile var instance: TouchService? = null
            private set
    }

    override fun onServiceConnected() {
        instance = this
    }

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        instance = null
        return super.onUnbind(intent)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}
    override fun onInterrupt() {}

    /** 点按（x, y 为手机屏幕实际像素）。 */
    fun tap(x: Float, y: Float): Boolean {
        val path = Path().apply { moveTo(x, y) }
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, 80))
            .build()
        return dispatchGesture(gesture, null, null)
    }

    /** 滑动（起止为手机屏幕实际像素，时长 300ms 模拟自然滚动）。 */
    fun swipe(x1: Float, y1: Float, x2: Float, y2: Float): Boolean {
        val path = Path().apply { moveTo(x1, y1); lineTo(x2, y2) }
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, 300))
            .build()
        return dispatchGesture(gesture, null, null)
    }
}
