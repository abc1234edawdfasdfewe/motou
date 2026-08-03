package com.motou.app

import android.content.Context
import android.util.AttributeSet
import android.view.ActionMode
import android.view.Menu
import android.view.MenuItem
import android.webkit.WebView

/**
 * 阅读页 WebView：长按选中文字时，在系统选择菜单（复制/全选）之外
 * 注入「存为笔记」「问 AI」两项。
 *
 * 选中文字在菜单点击时经 JS 读取，回调给 MainActivity 处理。
 */
class ReaderWebView @JvmOverloads constructor(
    context: Context, attrs: AttributeSet? = null
) : WebView(context, attrs) {

    /** 选中文字后的两个动作回调。 */
    var onSaveNote: ((String) -> Unit)? = null
    var onAskAi: ((String) -> Unit)? = null

    override fun startActionMode(callback: ActionMode.Callback, type: Int): ActionMode {
        return super.startActionMode(wrapCallback(callback), type)
    }

    private fun wrapCallback(original: ActionMode.Callback): ActionMode.Callback {
        return object : ActionMode.Callback2() {
            override fun onCreateActionMode(mode: ActionMode, menu: Menu): Boolean {
                val ok = original.onCreateActionMode(mode, menu)
                mode.menuInflater.inflate(R.menu.text_selection, menu)
                return ok
            }

            override fun onPrepareActionMode(mode: ActionMode, menu: Menu): Boolean {
                return original.onPrepareActionMode(mode, menu)
            }

            override fun onActionItemClicked(mode: ActionMode, item: MenuItem): Boolean {
                when (item.itemId) {
                    R.id.action_save_note -> { withSelection { onSaveNote?.invoke(it) }; mode.finish(); return true }
                    R.id.action_ask_ai -> { withSelection { onAskAi?.invoke(it) }; mode.finish(); return true }
                }
                return original.onActionItemClicked(mode, item)
            }

            override fun onDestroyActionMode(mode: ActionMode) {
                original.onDestroyActionMode(mode)
            }
        }
    }

    /** 异步取当前选中的纯文本。 */
    private fun withSelection(block: (String) -> Unit) {
        evaluateJavascript("(window.getSelection()?window.getSelection().toString():'')") { js ->
            val text = runCatching {
                org.json.JSONTokener(js).nextValue() as? String
            }.getOrNull().orEmpty().trim()
            if (text.isNotEmpty()) block(text)
        }
    }
}
