#include "ct2_bridge.h"

#include <memory>
#include <mutex>
#include <string>
#include <vector>

// Décommenter une fois CTranslate2 compilé pour Android :
// #include <ctranslate2/translator.h>

namespace {

std::mutex g_mutex;

// ctranslate2::Translator = modèle seq2seq (opus-mt, NLLB) chargé en mémoire.
// std::unique_ptr<ctranslate2::Translator> g_translator;

// Le modèle est chargé : passe à true après un initialize() réussi.
bool g_ready = false;

std::string to_string(JNIEnv* env, jstring value) {
  if (value == nullptr) return {};
  const char* chars = env->GetStringUTFChars(value, nullptr);
  std::string result(chars);
  env->ReleaseStringUTFChars(value, chars);
  return result;
}

}  // namespace

extern "C" {

JNIEXPORT jboolean JNICALL
Java_com_youssira_reader_NativeTranslationPlugin_nativeIsAvailable(
    JNIEnv* /*env*/, jclass /*clazz*/) {
  // La bibliothèque est liée : le moteur est disponible.
  return JNI_TRUE;
}

JNIEXPORT jboolean JNICALL
Java_com_youssira_reader_NativeTranslationPlugin_nativeInitialize(
    JNIEnv* env, jclass /*clazz*/, jstring model_dir, jstring source_lang,
    jstring target_lang, jint threads) {
  const std::string model_dir_str = to_string(env, model_dir);
  const std::string source = to_string(env, source_lang);
  const std::string target = to_string(env, target_lang);

  std::lock_guard<std::mutex> lock(g_mutex);

  // TODO(mode qualité) : charger le modèle CTranslate2.
  //
  // ctranslate2::models::ModelLoader loader(model_dir_str);
  // loader.cpu_threads = threads;
  // loader.compute_type = ctranslate2::ComputeType::INT8;
  // g_translator = std::make_unique<ctranslate2::Translator>(loader);
  // g_ready = true;

  (void)source;
  (void)target;

  return g_ready ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jstring JNICALL
Java_com_youssira_reader_NativeTranslationPlugin_nativeTranslate(
    JNIEnv* env, jclass /*clazz*/, jstring text) {
  const std::string input = to_string(env, text);

  std::lock_guard<std::mutex> lock(g_mutex);
  if (!g_ready /* || !g_translator */) {
    return nullptr;
  }

  // TODO(mode qualité) : tokeniser (SentencePiece), traduire, dé-tokeniser.
  //
  // std::vector<std::string> tokens = g_tokenizer.encode(input);
  // auto hypotheses = g_translator->translate_batch({tokens});
  // std::string output = g_tokenizer.decode(hypotheses[0].output);
  // return env->NewStringUTF(output.c_str());

  (void)input;
  return nullptr;
}

JNIEXPORT void JNICALL
Java_com_youssira_reader_NativeTranslationPlugin_nativeShutdown(
    JNIEnv* /*env*/, jclass /*clazz*/) {
  std::lock_guard<std::mutex> lock(g_mutex);
  // g_translator.reset();
  g_ready = false;
}

}
