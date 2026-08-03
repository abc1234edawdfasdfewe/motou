package com.motou.sender

import android.os.Bundle
import android.content.Intent
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.activity.ComponentActivity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import com.motou.sender.SettingsStore.ocrModel
import com.motou.sender.SettingsStore.ocrToken

/** 设置页：OCR Token + 各家大模型 OpenAI 兼容接口配置（含检测模型 / 测试连通性）。 */
class SettingsActivity : ComponentActivity() {

    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private lateinit var llmContainer: LinearLayout
    private lateinit var ocrTokenEdit: EditText
    private lateinit var ocrModelEdit: EditText

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_settings)

        findViewById<ImageButton>(R.id.settingsBack).setOnClickListener { finish() }
        ocrTokenEdit = findViewById(R.id.ocrToken)
        ocrModelEdit = findViewById(R.id.ocrModel)
        llmContainer = findViewById(R.id.llmContainer)

        ocrTokenEdit.setText(ocrToken)
        ocrModelEdit.setText(ocrModel)

        findViewById<Button>(R.id.ocrSave).setOnClickListener {
            ocrToken = ocrTokenEdit.text.toString()
            ocrModel = ocrModelEdit.text.toString()
            Toast.makeText(this, "OCR 配置已保存", Toast.LENGTH_SHORT).show()
        }

        setupBatteryBtn()
        renderLlms()
    }

    override fun onResume() {
        super.onResume()
        refreshBatteryBtn()
    }

    // ---------- 锁屏续聊保活（忽略电池优化） ----------

    private fun isBatteryWhitelisted(): Boolean {
        val pm = getSystemService(POWER_SERVICE) as android.os.PowerManager
        return pm.isIgnoringBatteryOptimizations(packageName)
    }

    private fun refreshBatteryBtn() {
        findViewById<Button>(R.id.batteryBtn).text =
            if (isBatteryWhitelisted()) "✓ 已允许后台运行（锁屏可续聊）" else "点我开启：允许后台运行"
    }

    private fun setupBatteryBtn() {
        findViewById<Button>(R.id.batteryBtn).setOnClickListener {
            if (isBatteryWhitelisted()) {
                Toast.makeText(this, "已在白名单中，锁屏续聊可用", Toast.LENGTH_SHORT).show()
            } else {
                // 引导用户授予「忽略电池优化」，豁免 ColorOS/Hans 锁屏冻结
                val intent = Intent(android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                    data = android.net.Uri.parse("package:$packageName")
                }
                runCatching { startActivity(intent) }
                    .onFailure {
                        startActivity(Intent(android.provider.Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                    }
            }
        }
        refreshBatteryBtn()
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    // ---------- 大模型卡片 ----------

    private fun renderLlms() {
        llmContainer.removeAllViews()
        val all = SettingsStore.loadLlms(this)
        for (llm in all) llmContainer.addView(buildLlmCard(llm))
    }

    private fun buildLlmCard(llm: SettingsStore.Llm): View {
        val card = layoutInflater.inflate(R.layout.item_llm, llmContainer, false)
        val name = card.findViewById<TextView>(R.id.llmName)
        val base = card.findViewById<EditText>(R.id.llmBase)
        val key = card.findViewById<EditText>(R.id.llmKey)
        val model = card.findViewById<EditText>(R.id.llmModel)
        val result = card.findViewById<TextView>(R.id.llmResult)
        val testBtn = card.findViewById<Button>(R.id.llmTest)
        val modelsBtn = card.findViewById<Button>(R.id.llmModels)
        val saveBtn = card.findViewById<Button>(R.id.llmSave)

        name.text = llm.name
        base.setText(llm.baseUrl)
        key.setText(llm.apiKey)
        model.setText(llm.model)

        fun collect(): SettingsStore.Llm = llm.copy(
            baseUrl = base.text.toString().trim(),
            apiKey = key.text.toString().trim(),
            model = model.text.toString().trim()
        )

        saveBtn.setOnClickListener {
            SettingsStore.updateLlm(this, collect())
            result.text = "已保存"
        }
        testBtn.setOnClickListener {
            result.text = "测试中…"
            scope.launch {
                val err = AiClient.testConnection(collect())
                result.text = if (err == null) "✓ 连接成功" else "✗ $err"
            }
        }
        modelsBtn.setOnClickListener {
            result.text = "拉取模型列表…"
            scope.launch {
                val models = AiClient.listModels(collect())
                if (models == null) {
                    result.text = "✗ 拉取失败（部分服务不支持 /models）"
                } else if (models.isEmpty()) {
                    result.text = "未返回任何模型"
                } else {
                    android.app.AlertDialog.Builder(this@SettingsActivity)
                        .setTitle("选择模型")
                        .setItems(models.toTypedArray()) { _, i ->
                            model.setText(models[i])
                            SettingsStore.updateLlm(this@SettingsActivity, collect())
                            result.text = "已选 ${models[i]}"
                        }
                        .show()
                    result.text = "共 ${models.size} 个模型"
                }
            }
        }
        return card
    }
}
