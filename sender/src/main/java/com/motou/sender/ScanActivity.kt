package com.motou.sender

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.FrameLayout
import android.widget.TextView
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import com.google.zxing.BinaryBitmap
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.QRCodeReader
import java.util.concurrent.Executors

/**
 * 扫码连接：全屏相机预览，ZXing 解码墨水屏待机页二维码（内容为 http://<ip>:8383），
 * 解出 IP 即 setResult 返回 MainActivity 自动填入并连接。
 */
class ScanActivity : ComponentActivity() {

    private val analysisExecutor = Executors.newSingleThreadExecutor()
    private var done = false
    private var previewView: PreviewView? = null

    private val permLauncher = registerForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.RequestPermission()
    ) { granted ->
        val pv = previewView
        if (granted && pv != null) startCamera(pv)
        else {
            Toast.makeText(this, "没有相机权限，无法扫码", Toast.LENGTH_SHORT).show()
            finish()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val root = FrameLayout(this)
        val preview = PreviewView(this)
        root.addView(preview, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))

        val hint = TextView(this).apply {
            text = "对准墨水屏待机页的二维码"
            setTextColor(Color.WHITE)
            textSize = 17f
            gravity = Gravity.CENTER
            setBackgroundColor(0x66000000)
            setPadding(0, 24, 0, 24)
        }
        root.addView(hint, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.TOP))

        val cancel = Button(this).apply { text = "取消" }
        root.addView(cancel, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT,
            Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL).apply { bottomMargin = 60 })
        cancel.setOnClickListener { finish() }

        setContentView(root)
        previewView = preview

        if (checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            startCamera(preview)
        } else {
            permLauncher.launch(Manifest.permission.CAMERA)
        }
    }

    private fun startCamera(previewView: PreviewView) {
        val future = ProcessCameraProvider.getInstance(this)
        future.addListener({
            val provider = future.get()
            val preview = Preview.Builder().build().also {
                it.setSurfaceProvider(previewView.surfaceProvider)
            }
            val analysis = ImageAnalysis.Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
            analysis.setAnalyzer(analysisExecutor) { image -> analyze(image) }
            provider.unbindAll()
            provider.bindToLifecycle(this, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
        }, mainExecutor)
    }

    /** Y 平面提灰度 → ZXing；rowStride ≠ width 时按行裁剪。 */
    private fun analyze(image: ImageProxy) {
        if (done) { image.close(); return }
        try {
            val plane = image.planes[0]
            val buf = plane.buffer
            val w = image.width
            val h = image.height
            val stride = plane.rowStride
            val data = ByteArray(w * h)
            if (stride == w) {
                buf.get(data)
            } else {
                val row = ByteArray(stride)
                for (y in 0 until h) {
                    buf.get(row)
                    System.arraycopy(row, 0, data, y * w, w)
                }
            }
            val source = PlanarYUVLuminanceSource(data, w, h, 0, 0, w, h, false)
            val result = runCatching {
                QRCodeReader().decode(BinaryBitmap(HybridBinarizer(source)))
            }.getOrNull()
            val text = result?.text
            if (text != null) {
                val m = Regex("((?:\\d{1,3}\\.){3}\\d{1,3})").find(text)
                if (m != null) {
                    done = true
                    runOnUiThread {
                        setResult(RESULT_OK, Intent().putExtra("ip", m.groupValues[1]))
                        finish()
                    }
                }
            }
        } catch (_: Exception) {
        } finally {
            image.close()
        }
    }

    override fun onDestroy() {
        analysisExecutor.shutdown()
        super.onDestroy()
    }
}
