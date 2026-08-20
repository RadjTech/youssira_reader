/// Nettoie le texte extrait du PDF avant traduction.
///
/// Les PDF contiennent des glyphes typographiques que les moteurs de
/// traduction digèrent mal (ligatures, guillemets courbes, espaces
/// insécables…) et qui produisent les « caractères spéciaux » observés.
class TextNormalizer {
  static String normalize(String input) {
    return input
        // Ligatures
        .replaceAll('ﬁ', 'fi')
        .replaceAll('ﬂ', 'fl')
        .replaceAll('ﬀ', 'ff')
        .replaceAll('ﬃ', 'ffi')
        .replaceAll('ﬄ', 'ffl')
        // Guillemets typographiques
        .replaceAll('’', "'")
        .replaceAll('‘', "'")
        .replaceAll('“', '"')
        .replaceAll('”', '"')
        // Tirets
        .replaceAll('–', '-')
        .replaceAll('—', '-')
        // Espaces insécables / soft hyphens
        .replaceAll(' ', ' ')
        .replaceAll('­', '')
        // Blancs multiples
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}
