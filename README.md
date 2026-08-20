# **Youssira Reader**
`Lecture PDF + Traduction 100% on-device par superposition — Android first`

Une app mobile Flutter qui lit des PDF et traduit le texte directement par-dessus, sans casser la mise en page. 100% offline, aucune donnée ne quitte le téléphone, modèles légers quantifiés.

---

### **1. Le Problème**
- Les lecteurs PDF classiques ne traduisent pas.
- Les apps IA cloud cassent la mise en page, nécessitent internet et envoient tes documents sur des serveurs.

### **2. La Solution**
**Youssira Reader** garde le PDF original intact et ajoute un calque de traduction par-dessus chaque bloc de texte, aux coordonnées exactes du bloc d'origine.

`PDF Original` + `Calque IA Traduit` = `Lecture bilingue instantanée`

#### **Features clés**
- **100% On-Device** : aucune donnée ne quitte le téléphone
- **Mise en page préservée** : la traduction se superpose à l'emplacement exact du texte
- **APK léger** : les modèles se téléchargent à la demande (Play Asset Delivery), l'APK reste < 30 Mo
- **Deux modes de traduction** : mode léger (ML Kit, ~30 Mo/paire de langues) et mode qualité (réseau neuronal int8)
- **Rapide** : < 2 s par page A4 en mode qualité sur un smartphone milieu de gamme récent
- **Support PDF natif + scanné** : extraction texte pdfium + OCR ML Kit

---

### **3. Stack technique (cible Android)**

| Couche | Techno | Rôle | Pourquoi ce choix |
| --- | --- | --- | --- |
| **UI + Rendu PDF** | Flutter 3.24+ / Dart | Interface, rendu, overlay | Multi-plateforme, UI réactive |
| **Moteur PDF** | `pdfrx` (basé sur **pdfium**) | Rendu + extraction texte **avec coordonnées x,y,w,h** | pdfium expose les bounding boxes exactes (FPDFText), rendu natif rapide |
| **OCR (PDF scannés)** | **ML Kit Text Recognition v2** | Texte des pages images, on-device | Gratuit, intégré Android, pas de modèle à gérer soi-même |
| **Traduction — mode léger** | **ML Kit Translation API** | FR ⇄ EN, ~30 Mo par paire de langues | Zéro friction, tourne dès 2 Go de RAM, géré par Google Play Services |
| **Traduction — mode qualité** | **CTranslate2** (C++ via JNI) + **opus-mt** ou **NLLB-600M** quantifiés int8 | Meilleure qualité, 10+ langues | Moteur C++ optimisé mobile, ~100–600 Mo selon modèle, inférence très rapide |
| **LLM QA / Résumé** (optionnel) | **llama.cpp** via JNI (plugin `fllama`) ou **MediaPipe LLM Inference** | Résumer, répondre sur le document | **Gemma 2B** ou **Qwen2.5 1.5B** plutôt que Phi-3 (voir §7) |
| **Cache des traductions** | **drift** (SQLite) | Réutiliser les traductions déjà calculées | Hit-rate élevé sur docs répétés, gain de vitesse massif |
| **Livraison des modèles** | **Play Asset Delivery** / téléchargement à la demande | Ne pas alourdir l'APK | Pas de 1,8 Go embarqué à l'installation |
| **Composant natif** | Kotlin + NDK/JNI | Pont Flutter ↔ CTranslate2 / llama.cpp | Appel direct, pas de serveur interprocess |

#### **Changements majeurs vs la v1 du projet — et pourquoi**

1. **Le backend Go est retiré.** `go-llama.cpp` n'est plus maintenu, et Go sur Android (gomobile + cgo) ajoute un runtime lourd, un build pénible et de la latence, sans aucun bénéfice par rapport à un appel natif. Kotlin + NDK appelle directement CTranslate2 et llama.cpp : plus simple, plus petit, plus rapide.
2. **`pdf_render` remplacé par `pdfrx`/pdfium.** pdfium est le moteur de Chrome pour le PDF : extraction de texte avec coordonnées fiable, rendu rapide, et c'est la base pour un overlay précis.
3. **Deux modes de traduction.** Le mode léger ML Kit couvre le besoin dès l'installation (modèles ~30 Mo, téléchargés par Google Play Services). Le mode qualité neuronal se télécharge à la demande. L'utilisateur choisit vitesse ou qualité.
4. **Phi-3 mini corrigé : c'est un modèle 3,8 B** (≈ 2,2 Go en Q4), pas 2 B — trop lourd pour la cible 4 Go de RAM. Pour le QA/résumé sur Android : **Gemma 2B** ou **Qwen2.5 1.5B** (~1–1,5 Go en Q4), supportés par llama.cpp et MediaPipe.
5. **Modèles hors de l'APK.** Bundler 1,8 Go est rédhibitoire sur le Play Store et pour les forfaits data ; Play Asset Delivery / téléchargement incrémental avec reprise.

---

### **4. Architecture**

```
[Flutter UI]
 ├─ pdfrx (pdfium) ──────► rendu page + blocs texte {texte, x, y, w, h}
 ├─ ML Kit OCR ──────────► blocs texte (si page scannée)
 ├─ Cache SQLite (drift) ► hash(texte + paire + version modèle) → hit ? → overlay direct
 └─ sinon → [Module natif Kotlin/JNI]
      ├─ CTranslate2 int8 (opus-mt / NLLB) ──► traduction
      └─ llama.cpp (optionnel) ──────────────► résumé / QA
                    │
                    ▼
[Overlay Flutter] Stack + Positioned : calque traduit aux coordonnées exactes
```

Principes :
- **Traduction paresseuse** : uniquement la page visible ± 1, blocs visibles en premier.
- **Isolats** : extraction et inférence hors de l'UI thread.
- **Mémoire** : modèles chargés en mmap, LLM déchargé quand inactif.

---

### **5. Installation & Build**

#### **Prérequis**
- Flutter 3.24+ / Dart 3.5+
- Android Studio (le projet cible Android en priorité)
- `minSdkVersion 26` (Android 8+)

#### **1. Cloner**
```bash
git clone https://github.com/RadjTech/youssira_reader.git
cd youssira_reader
```

#### **2. Générer les dossiers plateformes** (première fois uniquement)
Le dépôt contient le code Dart + le module natif ; les dossiers `android/`
sont générés par Flutter :
```bash
flutter create --org com.radjtech --project-name youssira_reader --platforms android .
```
Pense à aligner `minSdkVersion` sur 26 dans `android/app/build.gradle`.

#### **3. Dépendances + génération de code (cache drift)**
```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs
```

#### **4. Lancer**
```bash
flutter run
```
Au premier lancement, le mode léger (ML Kit) fonctionne immédiatement : les
modèles de langues (~30 Mo chacun) sont téléchargés par Google Play Services.
Le mode qualité CTranslate2 est optionnel — voir `engine/README.md`.

#### **Structure du projet**
```
lib/
├── main.dart / app.dart
├── core/
│   ├── app_services.dart              # singletons globaux
│   ├── models/
│   │   ├── text_block.dart            # bloc texte + coordonnées PDF
│   │   └── reader_settings.dart       # réglages + persistance
│   ├── services/
│   │   ├── pdf_block_extractor.dart   # PDFium → blocs {texte, x,y,w,h}
│   │   ├── ocr_service.dart           # ML Kit OCR (pages scannées)
│   │   ├── translation_service.dart   # orchestration cache → moteur → cache
│   │   ├── cache/translation_cache.dart  # SQLite (drift)
│   │   └── translation/
│   │       ├── translation_engine.dart    # interface commune
│   │       ├── mlkit_translation_engine.dart  # mode léger
│   │       └── native_translation_engine.dart # mode qualité (JNI)
│   └── utils/coords.dart              # repère PDF → repère Flutter
└── features/
    ├── home/home_screen.dart          # ouvrir un PDF, récents
    ├── reader/
    │   ├── reader_controller.dart     # état : blocs, traductions, modes
    │   ├── reader_screen.dart         # PdfDocumentViewBuilder + AppBar
    │   └── translation_page_view.dart # page + overlay Positioned
    └── settings/settings_screen.dart

engine/                                # module natif CTranslate2 (optionnel)
├── kotlin/NativeTranslationPlugin.kt  # MethodChannel
├── jni/ct2_bridge.{h,cpp}             # JNI → ctranslate2::Translator
└── CMakeLists.txt
```

---

### **6. Comment ça marche**

1. **Ouvre un PDF** : pdfium extrait chaque bloc de texte avec ses coordonnées `x, y, w, h` (OCR ML Kit si la page est une image).
2. **Sélectionne / fais défiler** : les blocs de la page visible sont envoyés au moteur — le cache SQLite est consulté d'abord.
3. **Traduction on-device** : ML Kit (~50 ms/bloc) ou CTranslate2 int8 (< 2 s/page A4).
4. **Overlay** : `Positioned` aux coordonnées exactes du bloc, fond adapté, trois modes de lecture : *Original / Traduit / Bilingue (tap pour basculer)*.

---

### **7. Roadmap**
- [x] Rendu PDF + extraction texte & coordonnées (pdfrx/pdfium)
- [ ] Overlay de traduction + 3 modes de lecture
- [ ] Traduction FR ⇄ EN mode léger (ML Kit), 100% offline
- [ ] Cache des traductions (drift/SQLite) ← *à faire tôt, gros ROI*
- [ ] Téléchargement des modèles à la demande (Play Asset Delivery)
- [ ] OCR PDF scannés (ML Kit Text Recognition v2)
- [ ] Mode qualité : CTranslate2 int8 (opus-mt) puis NLLB 600M (10 langues)
- [ ] « Résumer ce paragraphe » / QA (Gemma 2B via llama.cpp, optionnel)
- [ ] Export PDF traduit
- [ ] Portage iOS (pdfium et llama.cpp sont déjà compatibles)

### **8. Contraintes & Perf**
- **RAM cible** : 2 Go mini pour le mode léger, 4 Go pour le mode qualité, 6 Go+ avec le LLM.
- **Quantification int8 systématique** sur les modèles de traduction.
- **Repère** (Snapdragon 8 Gen 2) : page A4 ≈ 200–400 ms en mode léger, ≈ 1,5 s en mode qualité.
- **Batterie** : inférence uniquement sur les pages visibles, aucun travail en arrière-plan.
- Si l'espace est critique : rester sur opus-mt int8 (~100 Mo) plutôt que NLLB (~600 Mo).

### **9. Contribuer**
Les PR sont bienvenues. Axes prioritaires : optimisation mémoire (mmap/déchargement), gestion des tableaux, qualité de l'OCR sur photos de documents.

### **10. Licence**
MIT License
