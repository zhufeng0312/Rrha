package com.rrha.rrha

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.webkit.CookieManager
import android.webkit.WebView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 微博 cookie 的**全局**读取通道（`rrha/weibo_cookie`）。
 *
 * ## 为什么需要它
 *
 * `WeiboWebViewPlugin.kt` 里的 `getCookies` 挂在 per-view 通道
 * `rrha/weibo_webview_<viewId>` 上 —— 只有微博 WebView 这个 PlatformView
 * **活着**时才能调用。而数据层要在后台（时间线刷新）拉微博，那时页面通常
 * 已经销毁，所以必须有一个与任何视图无关的入口。
 *
 * ## 惰性初始化 WebView 内核
 *
 * [CookieManager] 的读写依赖 WebView 内核已经加载：进程里从未创建过
 * `WebView` 时，`CookieManager.getInstance().getCookie(...)` 可能抛
 * `IllegalStateException`，或者读到空串（表现为「明明登录了却说没登录」）。
 *
 * 所以第一次调用时用 `applicationContext` 创建一个 `WebView` **只用于
 * 初始化内核**：**绝不 attach 到任何视图树**、不加载任何 URL、关掉 JS。
 * 之后复用同一个实例。创建与读取都必须在主线程 —— `MethodChannel` 的
 * handler 默认就在 platform thread（= 主线程），这里再做一次防御性转投。
 *
 * ## 凭据安全（硬约束）
 *
 * cookie 内容是用户的登录凭据：
 * - **绝不** `Log` 出 cookie 的值，连长度也不写；
 * - 只通过 `result.success(...)` 交给 Dart，Dart 侧只准放进请求头；
 * - 日志里最多出现「读失败」这一类与内容无关的结论。
 */
object WeiboCookieChannel {

    /** 通道名。Dart 侧见 `lib/core/net/weibo_cookie_source.dart`。 */
    const val CHANNEL_NAME = "rrha/weibo_cookie"

    private const val TAG = "RrhaWeiboCookie"

    /** cookie 的作用域：只读 m 站，不碰 passport / weibo.com 的其它域。 */
    private const val COOKIE_URL = "https://m.weibo.cn"

    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * 只用于初始化内核的 WebView。
     *
     * `@Volatile`：写入只发生在主线程，读取可能在其它线程（防御性转投之前
     * 的一次快速路径判断），用 volatile 保证可见性。
     */
    @Volatile
    private var warmWebView: WebView? = null

    /** 在 [MainActivity.configureFlutterEngine] 里调用一次。 */
    fun register(messenger: BinaryMessenger, context: Context) {
        // 用 applicationContext：通道的生命周期比任何 Activity 都长，
        // 持有一个 Activity 的引用会漏内存。
        val appContext = context.applicationContext
        val channel = MethodChannel(messenger, CHANNEL_NAME)
        channel.setMethodCallHandler { call, result ->
            // MethodChannel 的 handler 本来就在主线程；这里显式再判一次，
            // 是因为「后台线程读 CookieManager」在某些 ROM 上会静默返回空串。
            if (Looper.myLooper() == Looper.getMainLooper()) {
                handle(appContext, call, result)
            } else {
                mainHandler.post { handle(appContext, call, result) }
            }
        }
    }

    private fun handle(context: Context, call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // 返回值可能是空串：空串 = 未登录（Dart 侧据此抛 auth 错误）。
            "getCookies" -> result.success(readCookies(context))
            // 便捷方法：只给布尔，调用方连 cookie 字符串都不必接触。
            "hasCookies" -> result.success(readCookies(context).isNotEmpty())
            else -> result.notImplemented()
        }
    }

    /**
     * 读 m.weibo.cn 域下的 cookie。
     *
     * 失败一律返回空串（不抛、不 crash）：通道的另一端把空串当成
     * 「未登录」，会给出可读的登录提示，比一个 `PlatformException` 更好排查。
     */
    private fun readCookies(context: Context): String {
        if (!ensureWebViewReady(context)) return ""
        return try {
            CookieManager.getInstance().getCookie(COOKIE_URL) ?: ""
        } catch (e: Exception) {
            // 只记结论，不记异常 message（避免任何与内容相关的串被带进日志）。
            Log.w(TAG, "read cookie failed: ${e.javaClass.simpleName}")
            ""
        }
    }

    /**
     * 确保 WebView 内核已初始化。返回 false 表示这台设备上读不了 cookie。
     *
     * 幂等：成功后把实例挂在 [warmWebView] 上，后续调用直接复用，不会每读
     * 一次 cookie 就 new 一个 WebView（那样会持续吃内存）。
     */
    @SuppressLint("SetJavaScriptEnabled")
    private fun ensureWebViewReady(context: Context): Boolean {
        if (warmWebView != null) return true
        return try {
            // 先把 cookie 总开关打开：游客态也需要它维持会话。
            CookieManager.getInstance().setAcceptCookie(true)
            val webView = WebView(context)
            // 这个 WebView 永不显示、永不加载页面，JS 没有必要开。
            webView.settings.javaScriptEnabled = false
            webView.settings.allowFileAccess = false
            webView.settings.allowContentAccess = false
            // 刻意不 addView、不 attach 到任何容器。
            warmWebView = webView
            true
        } catch (e: Exception) {
            Log.w(TAG, "webview warm-up failed: ${e.javaClass.simpleName}")
            false
        }
    }
}
