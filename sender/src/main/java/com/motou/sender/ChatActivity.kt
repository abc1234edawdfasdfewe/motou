package com.motou.sender

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.activity.ComponentActivity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import com.motou.sender.SettingsStore.activeLlmId
import java.util.Locale

/**
 * AI 对话页：选择已配置的大模型，文字/语音输入，回复展示 + TTS 播报 + 一键投屏。
 * 对话历史存 SharedPreferences，供墨水屏端续聊回显。
 */
class ChatActivity : ComponentActivity() {

    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private val prefs by lazy { getSharedPreferences("motou.chat", MODE_PRIVATE) }

    private lateinit var msgList: LinearLayout
    private lateinit var scroll: ScrollView
    private lateinit var input: EditText
    private lateinit var modelBtn: Button
    private lateinit var sendBtn: Button
    private lateinit var castBtn: Button
    private lateinit var voiceBtn: ImageButton

    private var tts: android.speech.tts.TextToSpeech? = null
    private var ttsReady = false

    /** 会话历史由 ChatStore 统一持有（与墨水屏续聊同一份）。 */
    private val history get() = ChatStore.history(this)
    private var sending = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_chat)

        msgList = findViewById(R.id.chatMsgList)
        scroll = findViewById(R.id.chatScroll)
        input = findViewById(R.id.chatInput)
        modelBtn = findViewById(R.id.chatModelBtn)
        sendBtn = findViewById(R.id.chatSendBtn)
        castBtn = findViewById(R.id.chatCastBtn)
        voiceBtn = findViewById(R.id.chatVoiceBtn)

        findViewById<ImageButton>(R.id.chatBack).setOnClickListener { finish() }
        findViewById<ImageButton>(R.id.chatClear).setOnClickListener { clearHistory() }

        modelBtn.setOnClickListener { pickModel() }
        sendBtn.setOnClickListener { send(input.text.toString()) }
        castBtn.setOnClickListener { castLast() }
        voiceBtn.setOnClickListener { startVoice() }

        tts = android.speech.tts.TextToSpeech(this) { s ->
            ttsReady = s == android.speech.tts.TextToSpeech.SUCCESS
            if (ttsReady) tts?.language = Locale.CHINESE
        }

        loadHistory()
        refreshModelBtn()
        renderAll()
    }

    override fun onDestroy() {
        tts?.stop(); tts?.shutdown()
        scope.cancel()
        super.onDestroy()
    }

    // ---------- 模型选择 ----------

    private fun refreshModelBtn() {
        val llm = SettingsStore.activeLlm(this)
        modelBtn.text = llm?.let { "模型：${it.name}" } ?: "模型：未配置（去设置）"
    }

    private fun pickModel() {
        val all = SettingsStore.loadLlms(this)
        val names = all.map { it.name }.toTypedArray()
        android.app.AlertDialog.Builder(this)
            .setTitle("选择对话模型")
            .setItems(names) { _, i ->
                activeLlmId = all[i].id
                refreshModelBtn()
            }
            .setNegativeButton("去设置") { _, _ ->
                startActivity(Intent(this, SettingsActivity::class.java))
            }
            .show()
    }

    // ---------- 历史持久化（委托 ChatStore） ----------

    private fun loadHistory() { /* ChatStore 首次访问即加载 */ }

    private fun clearHistory() {
        ChatStore.clear(this)
        renderAll()
        Toast.makeText(this, "已清空对话", Toast.LENGTH_SHORT).show()
    }

    // ---------- 渲染 ----------

    private fun renderAll() {
        msgList.removeAllViews()
        for (m in history) addMsgView(m.role, m.content)
        scroll.post { scroll.fullScroll(View.FOCUS_DOWN) }
    }

    private fun addMsgView(role: String, content: String): TextView {
        val isUser = role == "user"
        val tv = TextView(this)
        tv.text = content
        tv.textSize = 16f
        tv.setTextColor(0xFF000000.toInt())
        tv.setPadding(28, 20, 28, 20)
        val bg = android.graphics.drawable.GradientDrawable()
        bg.cornerRadius = 24f
        bg.setColor(if (isUser) 0xFF000000.toInt() else 0xFFF1F1F1.toInt())
        tv.setTextColor(if (isUser) 0xFFFFFFFF.toInt() else 0xFF000000.toInt())
        tv.background = bg
        val lp = LinearLayout.LayoutParams(
            (resources.displayMetrics.widthPixels * 0.8).toInt(),
            LinearLayout.LayoutParams.WRAP_CONTENT
        )
        lp.topMargin = 16
        lp.marginStart = if (isUser) 24 else 0
        lp.marginEnd = if (isUser) 0 else 24
        if (isUser) lp.gravity = android.view.Gravity.END
        tv.layoutParams = lp
        msgList.addView(tv)
        return tv
    }

    // ---------- 发送 ----------

    private fun send(text: String) {
        val t = text.trim()
        if (t.isEmpty() || sending) return
        val llm = SettingsStore.activeLlm(this)
        if (llm == null || llm.apiKey.isBlank()) {
            Toast.makeText(this, "请先在设置中配置模型 API Key", Toast.LENGTH_SHORT).show()
            startActivity(Intent(this, SettingsActivity::class.java))
            return
        }
        input.text.clear()
        addMsgView("user", t)
        val thinking = addMsgView("assistant", "…")
        scroll.post { scroll.fullScroll(View.FOCUS_DOWN) }
        sending = true
        sendBtn.isEnabled = false

        // 历史/持久化/投屏/LLM 全部由 ChatStore 处理；这里只负责把结果画到气泡上
        ChatStore.ask(this, t) { _, err ->
            sending = false
            sendBtn.isEnabled = true
            if (err == null) {
                val reply = history.lastOrNull { it.role == "assistant" }?.content
                thinking.text = reply ?: "（空回复）"
                if (reply != null && ttsReady) tts?.speak(reply, android.speech.tts.TextToSpeech.QUEUE_FLUSH, null, "motou")
            } else {
                thinking.text = "出错了：$err"
            }
            scroll.post { scroll.fullScroll(View.FOCUS_DOWN) }
        }
    }

    // ---------- 语音输入 ----------

    private fun startVoice() {
        val intent = Intent(android.speech.RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(android.speech.RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                android.speech.RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(android.speech.RecognizerIntent.EXTRA_LANGUAGE, "zh-CN")
            putExtra(android.speech.RecognizerIntent.EXTRA_PROMPT, "说出你的问题…")
        }
        runCatching { startActivityForResult(intent, 7) }
            .onFailure { Toast.makeText(this, "设备不支持语音识别", Toast.LENGTH_SHORT).show() }
    }

    @Deprecated("语音回调")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 7 && resultCode == RESULT_OK) {
            val said = data?.getStringArrayListExtra(android.speech.RecognizerIntent.EXTRA_RESULTS)
                ?.firstOrNull()
            if (!said.isNullOrBlank()) {
                input.setText(said)
                input.setSelection(said.length)
            }
        }
    }

    // ---------- 一键投屏（整段会话 → 墨水屏聊天模式，可在设备上继续追问） ----------

    private fun castLast() {
        if (history.isEmpty()) {
            Toast.makeText(this, "还没有对话内容", Toast.LENGTH_SHORT).show()
            return
        }
        // 前台服务保活需通知权限（33+）
        if (android.os.Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 9)
        }
        (application as SenderApp).ensureConnected(this) {
            ChatStore.syncToDevice(this)
            ChatLinkService.start(this)   // 锁屏后仍能响应墨水屏追问
            Toast.makeText(this, "已投屏整段对话，可在墨水屏上继续追问（锁屏也会保持）", Toast.LENGTH_SHORT).show()
        }
    }
}
