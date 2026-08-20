package com.radjtech.youssira_reader

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Pont Flutter ↔ CTranslate2 (via JNI).
 *
 * Canal : "com.radjtech.youssira_reader/translation".
 * Voir engine/README.md pour compiler la bibliothèque native
 * (libyoussira_ct2.so + libctranslate2.so).
 *
 * Enregistrement dans MainActivity :
 *   flutterEngine.plugins.add(NativeTranslationPlugin())
 */
class NativeTranslationPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel

    companion object {
        private var libraryLoaded = false

        init {
            libraryLoaded = try {
                System.loadLibrary("youssira_ct2")
                true
            } catch (e: UnsatisfiedLinkError) {
                // Module natif non compilé : le mode qualité sera désactivé,
                // l'app bascule sur ML Kit (mode léger).
                false
            }
        }

        @JvmStatic
        private external fun nativeIsAvailable(): Boolean

        @JvmStatic
        private external fun nativeInitialize(
            modelDir: String,
            sourceLang: String,
            targetLang: String,
            threads: Int,
        ): Boolean

        @JvmStatic
        private external fun nativeTranslate(text: String): String?

        @JvmStatic
        private external fun nativeShutdown()
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(
            binding.binaryMessenger,
            "com.radjtech.youssira_reader/translation",
        )
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAvailable" ->
                result.success(libraryLoaded && (safeNative { nativeIsAvailable() } ?: false))

            "initialize" -> {
                if (!libraryLoaded) return result.success(false)
                val modelDir = call.argument<String>("modelDir")
                    ?: return result.error("bad_args", "modelDir est requis", null)
                val sourceLang = call.argument<String>("sourceLang") ?: "fr"
                val targetLang = call.argument<String>("targetLang") ?: "en"
                val threads = Runtime.getRuntime().availableProcessors()
                val ok = safeNative { nativeInitialize(modelDir, sourceLang, targetLang, threads) }
                result.success(ok)
            }

            "translate" -> {
                if (!libraryLoaded) return result.error("native_unavailable", "Module natif absent", null)
                val text = call.argument<String>("text")
                    ?: return result.error("bad_args", "text est requis", null)
                result.success(safeNative { nativeTranslate(text) })
            }

            "shutdown" -> {
                if (libraryLoaded) safeNative { nativeShutdown() }
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    /** Toute exception native est convertie en valeur par défaut. */
    private inline fun <T> safeNative(default: T? = null, block: () -> T?): T? =
        try {
            block()
        } catch (t: Throwable) {
            default
        }
}
