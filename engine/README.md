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

**Important** : copie aussi le tokenizer depuis le repo HF d'origine dans le
même dossier (indispensable, Marian = SentencePiece) :

```bash
# depuis https://huggingface.co/Helsinki-NLP/opus-mt-fr-en/tree/main
# -> sentencepiece.bpe.model
cp sentencepiece.bpe.model opus-mt-fr-en-ct2/
```

Le dossier final doit contenir : `model.bin`, `config.json`,
`sentencepiece.bpe.model`.

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
