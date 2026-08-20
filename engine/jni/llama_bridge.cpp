#include "llama_bridge.h"

#include <android/log.h>

#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include <llama.h>

namespace {

#define LOG_TAG "youssira_llama"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

std::mutex g_mutex;
bool g_backend_init = false;
llama_model* g_model = nullptr;
llama_context* g_ctx = nullptr;
llama_sampler* g_sampler = nullptr;
bool g_ready = false;

std::string to_string(JNIEnv* env, jstring value) {
  if (value == nullptr) return {};
  const char* chars = env->GetStringUTFChars(value, nullptr);
  std::string result(chars);
  env->ReleaseStringUTFChars(value, chars);
  return result;
}

void free_all() {
  if (g_sampler != nullptr) {
    llama_sampler_free(g_sampler);
    g_sampler = nullptr;
  }
  if (g_ctx != nullptr) {
    llama_free(g_ctx);
    g_ctx = nullptr;
  }
  if (g_model != nullptr) {
    llama_model_free(g_model);
    g_model = nullptr;
  }
  g_ready = false;
}

}  // namespace

extern "C" {

JNIEXPORT jboolean JNICALL
Java_com_radjtech_youssira_1reader_LlamaChatPlugin_nativeIsAvailable(
    JNIEnv* /*env*/, jclass /*clazz*/) {
  return JNI_TRUE;  // la bibliothèque est liée
}

JNIEXPORT jboolean JNICALL
Java_com_radjtech_youssira_1reader_LlamaChatPlugin_nativeInitialize(
    JNIEnv* env, jclass /*clazz*/, jstring model_path, jint threads,
    jint n_ctx) {
  const std::string path = to_string(env, model_path);

  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_ready) return JNI_TRUE;

  try {
    if (!g_backend_init) {
      llama_backend_init();
      g_backend_init = true;
    }

    llama_model_params mparams = llama_model_default_params();
    mparams.n_gpu_layers = 0;  // CPU uniquement

    g_model = llama_model_load_from_file(path.c_str(), mparams);
    if (g_model == nullptr) {
      throw std::runtime_error("llama_model_load_from_file échoué : " + path);
    }

    llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx = n_ctx > 0 ? static_cast<uint32_t>(n_ctx) : 4096;
    cparams.n_threads = threads > 0 ? static_cast<int32_t>(threads) : 4;
    cparams.n_threads_batch = cparams.n_threads;
    // Pas besoin de performances excessives sur téléphone.
    cparams.n_batch = 256;

    g_ctx = llama_init_from_model(g_model, cparams);
    if (g_ctx == nullptr) {
      throw std::runtime_error("llama_init_from_model échoué");
    }

    g_sampler =
        llama_sampler_chain_init(llama_sampler_chain_default_params());
    llama_sampler_chain_add(g_sampler, llama_sampler_init_top_k(40));
    llama_sampler_chain_add(g_sampler, llama_sampler_init_top_p(0.9f, 1));
    llama_sampler_chain_add(g_sampler, llama_sampler_init_temp(0.7f));
    llama_sampler_chain_add(g_sampler,
                            llama_sampler_init_dist(LLAMA_DEFAULT_SEED));

    g_ready = true;
  } catch (const std::exception& e) {
    LOGE("initialize failed: %s", e.what());
    free_all();
    return JNI_FALSE;
  }
  return JNI_TRUE;
}

JNIEXPORT jstring JNICALL
Java_com_radjtech_youssira_1reader_LlamaChatPlugin_nativeChat(
    JNIEnv* env, jclass /*clazz*/, jstring system_prompt,
    jstring user_prompt) {
  const std::string system = to_string(env, system_prompt);
  const std::string user = to_string(env, user_prompt);

  std::lock_guard<std::mutex> lock(g_mutex);
  if (!g_ready || g_model == nullptr || g_ctx == nullptr) return nullptr;

  try {
    // Gabarit de chat du modèle (Qwen2.5 / ChatML détecté automatiquement).
    std::vector<llama_chat_message> messages = {
        {"system", system.c_str()},
        {"user", user.c_str()},
    };
    const int32_t needed = llama_chat_apply_template(
        g_model, nullptr, messages.data(),
        static_cast<int32_t>(messages.size()), true, nullptr, 0);
    if (needed < 0) {
      throw std::runtime_error("llama_chat_apply_template échoué");
    }
    std::string formatted(static_cast<size_t>(needed), '\0');
    llama_chat_apply_template(g_model, nullptr, messages.data(),
                              static_cast<int32_t>(messages.size()), true,
                              formatted.data(), needed + 1);

    // Tokenisation (parse_special = true pour les balises du gabarit).
    std::vector<llama_token> tokens(static_cast<size_t>(needed) + 8);
    const int32_t n = llama_tokenize(g_model, formatted.c_str(),
                                     static_cast<int32_t>(formatted.size()),
                                     tokens.data(),
                                     static_cast<int32_t>(tokens.size()),
                                     /*add_special=*/true,
                                     /*parse_special=*/true);
    if (n < 0) {
      throw std::runtime_error("contexte trop petit pour le prompt");
    }
    tokens.resize(static_cast<size_t>(n));

    llama_kv_self_clear(g_ctx);
    llama_decode(g_ctx, llama_batch_get_one(tokens.data(), n));

    // Génération (plafonnée : réponse concise sur téléphone).
    std::string out;
    char piece[64];
    const int32_t max_tokens = 512;
    for (int32_t i = 0; i < max_tokens; i++) {
      const llama_token id = llama_sampler_sample(g_sampler, g_ctx, -1);
      if (llama_vocab_is_eog(llama_model_get_vocab(g_model), id)) break;
      const int32_t c = llama_token_to_piece(g_model, id, piece,
                                             sizeof(piece), 0, true);
      if (c > 0) out.append(piece, static_cast<size_t>(c));
      llama_decode(g_ctx, llama_batch_get_one(&id, 1));
    }
    return env->NewStringUTF(out.c_str());
  } catch (const std::exception& e) {
    LOGE("chat failed: %s", e.what());
    return nullptr;
  }
}

JNIEXPORT void JNICALL
Java_com_radjtech_youssira_1reader_LlamaChatPlugin_nativeShutdown(
    JNIEnv* /*env*/, jclass /*clazz*/) {
  std::lock_guard<std::mutex> lock(g_mutex);
  free_all();
}

}  // extern "C"
