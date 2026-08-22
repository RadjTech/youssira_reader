import 'dart:convert';

import 'package:flutter/services.dart';

/// Span de texte extrait par MuPDF : police réelle, taille réelle (les
/// matrices de texte agrandies sont déjà corrigées par MuPDF), boîte en
/// points PDF (origine bas-gauche, convention du projet).
class MupdfSpan {
  const MupdfSpan({
    required this.text,
    required this.font,
    required this.fontSize,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final String text;
  final String font;
  final double fontSize;
  final double left;
  final double top;
  final double right;
  final double bottom;

  double get centerX => (left + right) / 2;
  double get centerY => (top + bottom) / 2;

  /// Heuristiques fiables sur le vrai nom de police PostScript.
  bool get isBold =>
      RegExp(r'bold|black|heavy|semib|demib', caseSensitive: false)
          .hasMatch(font);
  bool get isItalic =>
      RegExp(r'italic|oblique', caseSensitive: false).hasMatch(font);
  bool get isMono => RegExp(
        r'mono|courier|consolas|menlo|cascadia|inconsolata|dejavu|fira ?code|jetbrains|source ?code|typewriter',
        caseSensitive: false,
      ).hasMatch(font);

  /// Serif détecté sur le vrai nom de police (Times, Garamond, Cambria…).
  /// Attention : « sans-serif » contient « serif » → on exclut d'abord.
  bool get isSerif {
    final f = font.toLowerCase();
    if (f.contains('sans')) return false;
    if (isMono) return false;
    return RegExp(
      r'serif|times|georgia|garamond|antiqua|palatino|cambria|minion|bodoni|didot|bookman|schoolbook|rockwell|goudy|calisto|caslon|baskerville',
    ).hasMatch(f);
  }

  /// Clé de famille (nom nettoyé des jetons de style) : deux polices avec
  /// la même clé sont la même famille (ex. TimesNewRomanPS-BoldMT et
  /// TimesNewRomanPSMT → « timesnewroman »).
  String get familyKey => font
      .toLowerCase()
      .replaceAll(
        RegExp(
          r'[,.\-\s]?(bold|black|heavy|semibold|demibold|demi|light|medium|thin|condensed|compressed|narrow|regular|italic|oblique|mt|ps|std|cy|ce|ee|w\d+)',
        ),
        '',
      )
      .replaceAll(RegExp(r'\s+'), '');

  static MupdfSpan? fromJson(Map<String, dynamic> j) {
    final size = (j['size'] as num?)?.toDouble() ?? 0;
    if (size <= 0) return null;
    return MupdfSpan(
      text: (j['text'] as String?) ?? '',
      font: (j['font'] as String?) ?? '',
      fontSize: size,
      left: (j['left'] as num?)?.toDouble() ?? 0,
      top: (j['top'] as num?)?.toDouble() ?? 0,
      right: (j['right'] as num?)?.toDouble() ?? 0,
      bottom: (j['bottom'] as num?)?.toDouble() ?? 0,
    );
  }
}

/// Client Dart du plugin natif MuPDF. Toute erreur → null : l'app retombe
/// alors sur PDFium FFI puis sur les heuristiques bitmap.
class MupdfStyledText {
  static const _channel = MethodChannel('mupdf_extractor');

  /// Spans stylés de la page [pageIndex] (0-based), ou null si MuPDF est
  /// indisponible / la page sans texte.
  static Future<List<MupdfSpan>?> extractPage(
    String filePath,
    int pageIndex,
  ) async {
    try {
      final raw = await _channel
          .invokeMethod<String>('extractPage', {
        'path': filePath,
        'pageIndex': pageIndex,
      })
          .timeout(const Duration(seconds: 20));
      if (raw == null) return null;
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final spans = <MupdfSpan>[];
      for (final line in (json['lines'] as List? ?? const [])) {
        for (final s in ((line as Map<String, dynamic>)['spans'] as List? ??
            const [])) {
          final span = MupdfSpan.fromJson(s as Map<String, dynamic>);
          if (span != null && span.text.trim().isNotEmpty) spans.add(span);
        }
      }
      return spans.isEmpty ? null : spans;
    } catch (_) {
      return null;
    }
  }
}
