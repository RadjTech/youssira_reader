package com.radjtech.youssira_reader

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Pont Flutter ↔ llama.cpp (via JNI) : chat local 100 % hors-ligne
 * (résumé du document, grandes lignes, questions-réponses).
 *
 * Canal : "com.radjtech.youssira_reader/llama".
 * Voir engine/README.md pour compiler la bibliothèque native
 * (libyoussira_llama.so + libllama.so).
 *
 * Enregistrement dans MainActivity :
 *   flutterEngine.plugins.add(LlamaChatPlugin())
 */
class LlamaChatPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel

    companion object {
        private var libraryLoaded = false

        init {
            libraryLoaded = try {
                System.loadLibrary("youssira_llama")
                true
            } catch (e: UnsatisfiedLinkError) {
                // Module natif non compilé : l'assistant sera désactivé.
                false
            }
        }

        @JvmStatic
        private external fun nativeIsAvailable(): Boolean

        @JvmStatic
        private external fun nativeInitialize(
            modelPath: String,
            threads: Int,
            nCtx: Int,
        ): Boolean

        @JvmStatic
        private external fun nativeChat(systemPrompt: String, userPrompt: String): String?

        @JvmStatic
        private external fun nativeShutdown()
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "com.radjtech.youssira_reader/llama")
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
                val modelPath = call.argument<String>("modelPath")
                    ?: return result.error("bad_args", "modelPath est requis", null)
                val nCtx = call.argument<Int>("nCtx") ?: 4096
                val threads = Runtime.getRuntime().availableProcessors()
                result.success(safeNative { nativeInitialize(modelPath, threads, nCtx) })
            }

            "chat" -> {
                if (!libraryLoaded) {
                    return result.error("native_unavailable", "Module natif absent", null)
                }
                val system = call.argument<String>("system") ?: ""
                val user = call.argument<String>("user")
                    ?: return result.error("bad_args", "user est requis", null)
                result.success(safeNative { nativeChat(system, user) })
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
