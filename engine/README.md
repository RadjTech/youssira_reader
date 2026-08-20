# Module natif — CTranslate2 (mode qualité)

Ce dossier contient le pont natif entre Flutter et [CTranslate2](https://github.com/OpenNMT/CTranslate2) pour la traduction de haute qualité 100% offline (opus-mt / NLLB, quantifiés int8).

> **Optionnel** : sans ce module, l'app fonctionne en mode léger (ML Kit Translation). Le code Dart détecte automatiquement l'absence de la bibliothèque native (`NativeTranslationEngine.isAvailable() == false`).

## Architecture

```
Flutter (Dart)                    Android (Kotlin)                  Natif (C++)
NativeTranslationEngine ────────► NativeTranslationPlugin ────────► ct2_bridge.cpp
 MethodChannel                     MethodChannel handler             JNI → ctranslate2::Translator
 'com.radjtech.youssira_reader/translation'                                   (libyoussira_ct2.so)
```

Méthodes du canal :
| Méthode | Arguments | Retour |
| --- | --- | --- |
| `isAvailable` | — | `bool` (la lib est-elle liée ?) |
| `initialize` | `sourceLang`, `targetLang`, `modelDir` | `bool` |
| `translate` | `text`, `sourceLang`, `targetLang` | `String` |
| `shutdown` | — | — |

## Étapes de build

### 1. Compiler CTranslate2 pour Android

```bash
git clone --recursive https://github.com/OpenNMT/CTranslate2.git
cd CTranslate2

cmake -S . -B build-android-arm64 \
  -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake \
  -DANDROID_ABI=arm64-v8a \
  -DANDROID_PLATFORM=android-26 \
  -DCMAKE_BUILD_TYPE=Release \
  -DWITH_CUDA=OFF -DWITH_MKL=OFF -DWITH_DNNL=OFF \
  -DWITH_SENTENCEPIECE=ON \
  -DBUILD_CLI=OFF

cmake --build build-android-arm64 -j8
```

Résultat : `libctranslate2.so` + headers dans `build-android-arm64/install`.

### 2. Convertir le modèle de traduction

Sur une machine de dev (Python) :

```bash
pip install ctranslate2 transformers sentencepiece

ct2-transformers-converter \
  --model Helsinki-NLP/opus-mt-fr-en \
  --output_dir opus-mt-fr-en-ct2 \
  --quantization int8
```

**Important** : le tokenizer doit accompagner `model.bin`.

- **opus-mt (Marian)** : le convertisseur ne copie PAS les fichiers
  SentencePiece — il produit `shared_vocabulary.json` (vocabulaire texte,
  inutilisable par notre pont). Téléchargez depuis le repo HF et placez
  dans le dossier converti :
  - `source.spm` (~800 ko) : encodage,
  - `target.spm` (~780 ko) : décodage.
  Il n'existe PAS de `sentencepiece.bpe.model` sur ces repos — c'est le
  nom utilisé par NLLB, pas par Marian.
- **NLLB** : `sentencepiece.bpe.model`, copié automatiquement.

Le dossier final doit contenir : `model.bin`, `config.json`,
`source.spm`, `target.spm` (`shared_vocabulary.json` peut rester, sans
effet). À défaut de `target.spm`, l'app retombe sur `source.spm`.

Pour 10+ langues (roadmap) : `facebook/nllb-200-distilled-600M` en int8 (~600 Mo).

### 3. Lier la bibliothèque au build Flutter

- Copier `libctranslate2.so` dans `android/app/src/main/jniLibs/arm64-v8a/`
- Copier `engine/jni/ct2_bridge.cpp` + `engine/CMakeLists.txt` dans le projet Android et activer `externalNativeBuild` dans `android/app/build.gradle` :

```gradle
android {
    externalNativeBuild {
        cmake { path "src/main/cpp/CMakeLists.txt" }
    }
}
```

### 4. Enregistrer le plugin

Dans `android/app/src/main/kotlin/com/radjtech/youssira_reader/MainActivity.kt` :

```kotlin
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(NativeTranslationPlugin())
    }
}
```

### 5. Charger le modèle dans l'app

Ne pas bundler le modèle dans l'APK.

**Option simple (déjà implémentée)** : dans l'app, **Réglages →
« Importer un modèle converti »** → choisis le dossier
`opus-mt-fr-en-ct2` (ex. depuis `Download/`) ; il est copié dans
`<appSupport>/models/opus-mt-fr-en-ct2/` et `NativeTranslationEngine`
passe ce chemin à `initialize` (`modelDir`).

**Option production (roadmap)** : Play Asset Delivery, asset pack
`on-demand`.

# Chat local — llama.cpp (assistant du document)

Assistant 100 % hors-ligne (résumé, grandes lignes, questions-réponses)
propulsé par Qwen2.5-0.5B-Instruct GGUF quantisé (~470 Mo), téléchargé
à la demande depuis l'app (écran Assistant) — jamais dans l'APK.

### 1. Compiler llama.cpp pour Android

```bash
git clone https://github.com/ggml-org/llama.cpp
cmake -S llama.cpp -B llama-android \
  -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake \
  -DANDROID_ABI=arm64-v8a \
  -DANDROID_PLATFORM=android-26 \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON \
  -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_SERVER=OFF
cmake --build llama-android -j8
cmake --install llama-android --prefix llama-android/install
```

Résultat : `libllama.so` (+ `libggml*.so`) et `include/` dans `install/`.

### 2. Lier au build Flutter

Comme pour CTranslate2 (§3) : copier les `.so` dans
`android/app/src/main/jniLibs/arm64-v8a/`, reprendre
`engine/CMakeLists.txt` avec `-DLLAMA_ROOT=<...>/install` pour produire
`libyoussira_llama.so`.

### 3. Enregistrer le plugin

Dans `MainActivity.kt`, ajouter :

```kotlin
flutterEngine.plugins.add(LlamaChatPlugin())
```

### 4. Modèle

Dans l'app : icône robot → « Télécharger le modèle » (barre de
progression) ou « Importer un GGUF ». D'autres GGUF fonctionnent
(recommandé : Q4_K_M, 0.5B à 1.5B pour un téléphone ; renommer le
fichier importé en `qwen2.5-0.5b-instruct-q4_k_m.gguf` ou écraser
celui-ci dans `<appSupport>/models/llm/`).
