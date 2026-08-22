import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Moteurs de traduction disponibles.
enum TranslationEngineKind {
  /// Mode léger : ML Kit On-Device Translation (~30 Mo par langue).
  mlkitLight,

  /// Mode qualité : CTranslate2 + opus-mt/NLLB int8 via le module natif.
  ct2Quality,
}

extension TranslationEngineKindId on TranslationEngineKind {
  /// Identifiant stable du moteur (clé de registre et de cache).
  String get id => switch (this) {
        TranslationEngineKind.mlkitLight => 'mlkit-light',
        TranslationEngineKind.ct2Quality => 'ct2-quality',
      };
}

/// Mode de lecture de la page.
enum ReadingMode {
  /// PDF original seul.
  original,

  /// Calque de traduction superposé au texte original (style Google Lens :
  /// patch si fond uni, texte avec halo si fond complexe, adaptation
  /// automatique au débordement).
  translated,

  /// Mode lecture : traduction retypographiée comme un ebook.
  reflow,

  /// « Document traduit » (façon Xodo) : le document est recomposé —
  /// pages originales en image + texte traduit reflowé par-dessus — puis
  /// rouvert comme un PDF à part entière dans le viewer.
  document,
}

/// Réglages de lecture et de traduction.
class ReaderSettings {
  const ReaderSettings({
    this.sourceBcp = 'fr',
    this.targetBcp = 'en',
    this.engine = TranslationEngineKind.mlkitLight,
    this.mode = ReadingMode.original,
    this.overlayOpacity = 1.0,
  });

  /// Langue source (code BCP-47 court, ex. 'fr').
  final String sourceBcp;

  /// Langue cible (code BCP-47 court, ex. 'en').
  final String targetBcp;

  final TranslationEngineKind engine;

  final ReadingMode mode;

  /// Opacité du fond du calque de traduction (0..1).
  final double overlayOpacity;

  /// Identifiant du moteur, utilisé comme clé de cache et par TranslationService.
  String get engineId => engine.id;

  ReaderSettings copyWith({
    String? sourceBcp,
    String? targetBcp,
    TranslationEngineKind? engine,
    ReadingMode? mode,
    double? overlayOpacity,
  }) {
    return ReaderSettings(
      sourceBcp: sourceBcp ?? this.sourceBcp,
      targetBcp: targetBcp ?? this.targetBcp,
      engine: engine ?? this.engine,
      mode: mode ?? this.mode,
      overlayOpacity: overlayOpacity ?? this.overlayOpacity,
    );
  }

  Map<String, dynamic> toJson() => {
        'sourceBcp': sourceBcp,
        'targetBcp': targetBcp,
        'engine': engine.index,
        'mode': mode.index,
        'overlayOpacity': overlayOpacity,
      };

  static ReaderSettings fromJson(Map<String, dynamic> json) {
    return ReaderSettings(
      sourceBcp: json['sourceBcp'] as String? ?? 'fr',
      targetBcp: json['targetBcp'] as String? ?? 'en',
      engine: TranslationEngineKind
          .values[json['engine'] as int? ?? TranslationEngineKind.mlkitLight.index],
      mode: ReadingMode.values[json['mode'] as int? ?? ReadingMode.original.index],
      overlayOpacity: (json['overlayOpacity'] as num?)?.toDouble() ?? 1.0,
    );
  }
}

/// Langues proposées dans l'UI (v1). ML Kit en supporte ~60 ; la liste sera
/// étendue avec l'arrivée de NLLB (roadmap).
class LanguageCatalog {
  static const Map<String, String> supported = {
    'fr': 'Français',
    'en': 'English',
    'es': 'Español',
    'de': 'Deutsch',
    'pt': 'Português',
    'ar': 'العربية',
  };
}

/// Persistance des réglages.
class SettingsStore {
  static const _key = 'reader_settings';

  static Future<ReaderSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return const ReaderSettings();
    try {
      return ReaderSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const ReaderSettings();
    }
  }

  static Future<void> save(ReaderSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(settings.toJson()));
  }
}
