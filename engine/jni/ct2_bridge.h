#pragma once

#include <jni.h>

// Pont JNI entre Kotlin (NativeTranslationPlugin) et CTranslate2.
//
// Les implémentations dans ct2_bridge.cpp sont des squelettes : décommenter
// les sections CTranslate2 une fois la bibliothèque compilée pour Android
// (voir engine/README.md).
//
// NB : mangling JNI — le `_` du package `youssira_reader` devient `_1`.

extern "C" {

JNIEXPORT jboolean JNICALL
Java_com_radjtech_youssira_1reader_NativeTranslationPlugin_nativeIsAvailable(
    JNIEnv* env, jclass clazz);

JNIEXPORT jboolean JNICALL
Java_com_radjtech_youssira_1reader_NativeTranslationPlugin_nativeInitialize(
    JNIEnv* env, jclass clazz, jstring model_dir, jstring source_lang,
    jstring target_lang, jint threads);

JNIEXPORT jstring JNICALL
Java_com_radjtech_youssira_1reader_NativeTranslationPlugin_nativeTranslate(
    JNIEnv* env, jclass clazz, jstring text);

JNIEXPORT void JNICALL
Java_com_radjtech_youssira_1reader_NativeTranslationPlugin_nativeShutdown(
    JNIEnv* env, jclass clazz);

}
