#include "ct2_bridge.h"

#include <android/log.h>

#include <fstream>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include <ctranslate2/translator.h>
#include <ctranslate2/sentence_piece.h>

namespace {

bool file_exists(const std::string& path) {
  std::ifstream f(path);
  return f.good();
}

}  // namespace

namespace {

std::mutex g_mutex;
std::unique_ptr<ctranslate2::Translator> g_translator;
std::unique_ptr<ctranslate2::SentencePiece> g_tokenizer;
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
Java_com_radjtech_youssira_1reader_NativeTranslationPlugin_nativeIsAvailable(
    JNIEnv* /*env*/, jclass /*clazz*/) {
  return JNI_TRUE;  // la bibliothèque est liée
}

JNIEXPORT jboolean JNICALL
Java_com_radjtech_youssira_1reader_NativeTranslationPlugin_nativeInitialize(
    JNIEnv* env, jclass /*clazz*/, jstring model_dir, jstring /*source_lang*/,
    jstring /*target_lang*/, jint threads) {
  const std::string model_dir_str = to_string(env, model_dir);

  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_ready) return JNI_TRUE;

  try {
    ctranslate2::ReplicaPoolConfig config;
    config.intra_threads = threads > 0 ? static_cast<size_t>(threads) : 4;
    config.inter_threads = 1;
    config.compute_type = ctranslate2::ComputeType::AUTO;  // = type stocké (int8)

    g_translator = std::make_unique<ctranslate2::Translator>(
        model_dir_str, ctranslate2::Device::CPU, 0, config);

    // Tokenizer SentencePiece copié à côté de model.bin :
    // - source.spm pour les modèles Marian (opus-mt, copie auto du
    //   convertisseur) ;
    // - sentencepiece.bpe.model pour NLLB.
    std::string tokenizer_path;
    for (const char* name : {"source.spm", "sentencepiece.bpe.model"}) {
      const std::string candidate = model_dir_str + "/" + name;
      if (file_exists(candidate)) {
        tokenizer_path = candidate;
        break;
      }
    }
    if (tokenizer_path.empty()) {
      throw std::runtime_error(
          "tokenizer introuvable (source.spm ou sentencepiece.bpe.model) "
          "dans " + model_dir_str);
    }
    g_tokenizer =
        std::make_unique<ctranslate2::SentencePiece>(tokenizer_path);

    g_ready = true;
  } catch (const std::exception& e) {
    g_translator.reset();
    g_tokenizer.reset();
    g_ready = false;
    __android_log_print(ANDROID_LOG_ERROR, "youssira_ct2",
                        "initialize failed: %s", e.what());
    return JNI_FALSE;
  }
  return JNI_TRUE;
}

JNIEXPORT jstring JNICALL
Java_com_radjtech_youssira_1reader_NativeTranslationPlugin_nativeTranslate(
    JNIEnv* env, jclass /*clazz*/, jstring text) {
  const std::string input = to_string(env, text);

  std::lock_guard<std::mutex> lock(g_mutex);
  if (!g_ready || !g_translator || !g_tokenizer) return nullptr;

  try {
    std::vector<std::string> source_tokens;
    g_tokenizer->encode(input, source_tokens);
    source_tokens.push_back("</s>");  // EOS attendu par Marian

    ctranslate2::TranslationOptions options;
    options.beam_size = 4;
    options.max_length = 512;

    const auto results =
        g_translator->translate_batch({source_tokens}, options);
    if (results.empty()) return nullptr;

    std::string output;
    g_tokenizer->decode(results[0].output(), output);
    return env->NewStringUTF(output.c_str());
  } catch (const std::exception& e) {
    __android_log_print(ANDROID_LOG_ERROR, "youssira_ct2",
                        "translate failed: %s", e.what());
    return nullptr;
  }
}

JNIEXPORT void JNICALL
Java_com_radjtech_youssira_1reader_NativeTranslationPlugin_nativeShutdown(
    JNIEnv* /*env*/, jclass /*clazz*/) {
  std::lock_guard<std::mutex> lock(g_mutex);
  g_tokenizer.reset();
  g_translator.reset();
  g_ready = false;
}

}
