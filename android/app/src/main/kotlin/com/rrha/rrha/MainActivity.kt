package com.rrha.rrha

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 注册微博内置浏览器用的 PlatformView（见 WeiboWebViewPlugin.kt）。
        // 用 platformViewsController.registry 注册，而不是旧的
        // flutterEngine.plugins.add(...)，这样无需额外的 FlutterPlugin 壳。
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "rrha/weibo_webview",
            WeiboWebViewFactory(flutterEngine.dartExecutor.binaryMessenger),
        )

        // 全局 cookie 通道：与 PlatformView 无关，后台刷新时间线时也能读。
        // 见 WeiboCookieChannel.kt 的类注释（惰性初始化 WebView 内核 + 凭据安全）。
        WeiboCookieChannel.register(
            flutterEngine.dartExecutor.binaryMessenger,
            applicationContext,
        )
    }
}
