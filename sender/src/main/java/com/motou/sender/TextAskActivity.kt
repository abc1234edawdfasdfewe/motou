package com.motou.sender

import android.os.Bundle
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.TextView
import android.widget.Toast
import androidx.activity.ComponentActivity
import com.motou.sender.SettingsStore.activeLlmId

/**
 * 阅读页选中文字「问 AI」：展示选中文字，输入提示词后与选中文字一起调 LLM。
 * 回复投到墨水屏阅读页（html 通道），并把这一轮并入对话历史。
 * 由通知点开（锁屏/后台也能收到），或 App 前台时直接弹出。
 */
class TextAskActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_text_ask)

        val selected = intent.getStringExtra(EXTRA_TEXT).orEmpty()
        if (selected.isBlank()) { finish(); return }

        findViewById<TextView>(R.id.askSelected).text = selected
        val promptInput = findViewById<EditText>(R.id.askPrompt)
        val sendBtn = findViewById<Button>(R.id.askSend)
        val status = findViewById<TextView>(R.id.askStatus)

        findViewById<View>(R.id.askClose).setOnClickListener { finish() }

        sendBtn.setOnClickListener {
            val prompt = promptInput.text.toString().trim()
            if (prompt.isEmpty()) {
                Toast.makeText(this, "请输入提示词", Toast.LENGTH_SHORT).show()
                return@setOnClickListener
            }
            val llm = SettingsStore.activeLlm(this)
            if (llm == null || llm.apiKey.isBlank()) {
                Toast.makeText(this, "请先在设置中配置模型 API Key", Toast.LENGTH_SHORT).show()
                return@setOnClickListener
            }
            sendBtn.isEnabled = false
            status.text = "思考中…"

            // 组合：提示词 + 引用选中文字，作为一条 user 消息进入对话历史
            val combined = "$prompt\n\n> $selected"
            ChatStore.ask(this, combined) { done, err ->
                if (!done) return@ask
                sendBtn.isEnabled = true
                if (err == null) {
                    status.text = "已回复并投到墨水屏"
                    // 回复经 ChatStore 进历史并 syncToDevice（chat 通道）。这里再把最新回复
                    // 以阅读页（html）形式投一次，便于在墨水屏上直接看排版结果。
                    val reply = ChatStore.history(this).lastOrNull { it.role == "assistant" }?.content
                    if (reply != null) {
                        (application as SenderApp).ws?.sendJson {
                            put("type", "html")
                            put("id", "s" + System.currentTimeMillis().toString(36))
                            put("title", prompt.take(20))
                            put("body", ChatStore.markdownToHtml(reply))
                        }
                    }
                    sendBtn.postDelayed({ finish() }, 900)
                } else {
                    status.text = "出错了：$err"
                }
            }
        }
    }

    companion object {
        const val EXTRA_TEXT = "selected_text"
    }
}
