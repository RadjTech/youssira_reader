#ifndef YOUSSIRA_LLAMA_BRIDGE_H_
#define YOUSSIRA_LLAMA_BRIDGE_H_

#include <jni.h>

#ifdef __cplusplus
extern "C" {
#endif

JNIEXPORT jboolean JNICALL
Java_com_radjtech_youssira_1reader_LlamaChatPlugin_nativeIsAvailable(
    JNIEnv* env, jclass clazz);

JNIEXPORT jboolean JNICALL
Java_com_radjtech_youssira_1reader_LlamaChatPlugin_nativeInitialize(
    JNIEnv* env, jclass clazz, jstring model_path, jint threads, jint n_ctx);

JNIEXPORT jstring JNICALL
Java_com_radjtech_youssira_1reader_LlamaChatPlugin_nativeChat(
    JNIEnv* env, jclass clazz, jstring system_prompt, jstring user_prompt);

JNIEXPORT void JNICALL
Java_com_radjtech_youssira_1reader_LlamaChatPlugin_nativeShutdown(
    JNIEnv* env, jclass clazz);

#ifdef __cplusplus
}
#endif

#endif  // YOUSSIRA_LLAMA_BRIDGE_H_
