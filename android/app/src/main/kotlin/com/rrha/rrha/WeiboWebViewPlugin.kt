package com.rrha.rrha

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.net.http.SslError
import android.util.Log
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.SslErrorHandler
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * 微博内置浏览器的 PlatformView 工厂。
 *
 * 为什么不用 `webview_flutter`：本工程在**无网络环境**下开发，pub.dev 不可达，
 * 无法新增 pub 依赖，所以直接包一层系统 `android.webkit.WebView`。
 */
class WeiboWebViewFactory(private val messenger: BinaryMessenger) :
    PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val params = args as? Map<*, *> ?: emptyMap<Any, Any>()
        return WeiboWebView(context, messenger, viewId, params)
    }
}

/**
 * 单个 WebView 实例。
 *
 * 视图树是 `FrameLayout(MATCH_PARENT) -> WebView(MATCH_PARENT)`：
 * 直接把 WebView 交给 Flutter 时，测量出来的尺寸可能是 0，表现为整片白屏，
 * 所以必须外面套一层容器并显式给 MATCH_PARENT 布局参数。
 *
 * 与 Dart 侧的通信用 `rrha/weibo_webview_$viewId` 这个 per-view 通道：
 * - 原生 -> Dart：`onProgress` / `onPageStarted` / `onPageFinished` / `onCanGoBackChanged` / `onError`
 * - Dart -> 原生：`canGoBack` / `goBack` / `reload` / `openExternal`
 *
 * Cookie 只在系统 `CookieManager` 里维护，**绝不读出传给 Dart**。
 * UA 保持系统默认：改成桌面 UA 会被 `m.weibo.cn` 重定向。
 */
class WeiboWebView(
    context: Context,
    messenger: BinaryMessenger,
    viewId: Int,
    params: Map<*, *>,
) : PlatformView {

    private val channel = MethodChannel(messenger, CHANNEL_PREFIX + viewId)
    private val container = FrameLayout(context)
    private val webView = WebView(context)
    private var disposed = false

    // 注意：必须声明在 init 之前。Kotlin 的属性初始化与 init 块按**声明顺序**
    // 执行，声明在后面会被判定为「Variable must be initialized」。
    private val weiboClient = object : WebViewClient() {
        override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean {
            val url = request?.url?.toString() ?: return false
            return handleNavigation(url)
        }

        @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
        override fun shouldOverrideUrlLoading(view: WebView?, url: String?): Boolean {
            if (url.isNullOrEmpty()) return false
            return handleNavigation(url)
        }

        override fun onPageStarted(view: WebView?, url: String?, favicon: Bitmap?) {
            invokeDart("onPageStarted", null)
        }

        override fun onPageFinished(view: WebView?, url: String?) {
            val target = view ?: webView
            invokeDart("onPageFinished", mapOf("canGoBack" to target.canGoBack()))
        }

        override fun doUpdateVisitedHistory(view: WebView?, url: String?, isReload: Boolean) {
            super.doUpdateVisitedHistory(view, url, isReload)
            // 页内导航（含 SPA 的 pushState）也会走到这里，这是刷新「能否回退」的正确钩子。
            invokeDart("onCanGoBackChanged", mapOf("canGoBack" to (view?.canGoBack() ?: false)))
        }

        override fun onReceivedError(
            view: WebView?,
            request: WebResourceRequest?,
            error: WebResourceError?,
        ) {
            // 只关心主文档：图片/埋点失败不该让用户看到整页错误。
            if (request?.isForMainFrame != true) return
            val code = error?.errorCode ?: -1
            val description = error?.description?.toString() ?: "页面加载失败"
            invokeDart("onError", mapOf("code" to code, "description" to description))
        }

        override fun onReceivedSslError(view: WebView?, handler: SslErrorHandler?, error: SslError?) {
            // 安全红线：**不调 proceed()**，证书错误一律取消加载。
            handler?.cancel()
            val primary = error?.primaryError ?: -1
            invokeDart(
                "onError",
                mapOf("code" to SSL_ERROR_CODE, "description" to "SSL 证书校验失败（$primary）"),
            )
        }
    }

    init {
        container.layoutParams = FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT,
        )
        webView.layoutParams = FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT,
        )
        container.addView(webView)

        configureSettings(webView.settings)

        // 游客态也需要 Cookie（微博 Web 端靠它维持会话），但只在原生侧维护。
        CookieManager.getInstance().setAcceptCookie(true)
        CookieManager.getInstance().setAcceptThirdPartyCookies(webView, true)

        webView.webViewClient = weiboClient
        webView.webChromeClient = object : WebChromeClient() {
            override fun onProgressChanged(view: WebView?, newProgress: Int) {
                invokeDart("onProgress", mapOf("progress" to newProgress))
            }
        }

        channel.setMethodCallHandler { call, result -> handle(call, result) }

        val initialUrl = params["url"] as? String
        if (!initialUrl.isNullOrEmpty()) {
            webView.loadUrl(initialUrl)
        }
    }

    // ------------------------------------------------------------ 配置

    @SuppressLint("SetJavaScriptEnabled")
    private fun configureSettings(settings: WebSettings) {
        settings.javaScriptEnabled = true
        settings.domStorageEnabled = true
        settings.databaseEnabled = true
        // 内置浏览器只该看网页，不该能读本地文件或 content:// 资源。
        settings.allowFileAccess = false
        settings.allowContentAccess = false
        // 页面是 https，混入 http 资源会被系统拦掉，这里显式表达意图。
        settings.mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
        settings.useWideViewPort = true
        settings.loadWithOverviewMode = true
        settings.builtInZoomControls = false
        settings.displayZoomControls = false
        // UA 保持系统默认（不要改成桌面 UA：m.weibo.cn 会重定向）。
    }

    // ------------------------------------------------------------ 导航

    /** http/https 交给 WebView 自己加载；其它 scheme 交给系统 App。 */
    private fun handleNavigation(url: String): Boolean {
        val scheme = runCatching { Uri.parse(url).scheme?.lowercase() }.getOrNull()
        if (scheme == "http" || scheme == "https") return false
        startExternal(url)
        return true
    }

    private fun startExternal(url: String) {
        try {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            container.context.startActivity(intent)
        } catch (e: Exception) {
            // 系统里没有能处理该 scheme 的 App：忽略即可，不要崩。
            Log.w(TAG, "open external failed: $url", e)
        }
    }

    // ------------------------------------------------------------ Dart -> 原生

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "canGoBack" -> result.success(webView.canGoBack())
            "goBack" -> {
                if (webView.canGoBack()) webView.goBack()
                result.success(null)
            }
            "reload" -> {
                webView.reload()
                result.success(null)
            }
            "getCookies" -> {
                // 诊断专用：只读出 m.weibo.cn 域的 cookie 交给 Dart 侧做一次自检请求。
                // 注意不能写进任何 Log —— 里面是用户的登录凭据。
                val cookies = CookieManager.getInstance().getCookie("https://m.weibo.cn")
                result.success(cookies ?: "")
            }
            "openExternal" -> {
                val url = webView.url
                if (url.isNullOrEmpty()) {
                    result.success(null)
                } else {
                    startExternal(url)
                    result.success(null)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun invokeDart(method: String, args: Any?) {
        if (disposed) return
        try {
            channel.invokeMethod(method, args)
        } catch (e: Exception) {
            Log.w(TAG, "invoke $method failed", e)
        }
    }

    // ------------------------------------------------------------ PlatformView

    override fun getView(): FrameLayout = container

    override fun dispose() {
        if (disposed) return
        disposed = true
        channel.setMethodCallHandler(null)
        try {
            webView.stopLoading()
            webView.loadUrl("about:blank")
            // 先摘掉 client，避免 destroy 过程中再回调 Dart。
            webView.webViewClient = WebViewClient()
            webView.webChromeClient = null
            container.removeView(webView)
            webView.destroy()
        } catch (e: Exception) {
            Log.w(TAG, "dispose webview failed", e)
        }
    }

    private companion object {
        const val TAG = "RrhaWeiboWebView"
        const val CHANNEL_PREFIX = "rrha/weibo_webview_"
        const val SSL_ERROR_CODE = -1
    }
}
