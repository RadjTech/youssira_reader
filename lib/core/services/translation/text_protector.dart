/// Texte passé à travers [TextProtector.mask] : les éléments protégés sont
/// remplacés par des placeholders `[[n]]` que le moteur de traduction laisse
/// tranquilles, puis restaurés après traduction.
class MaskedText {
  const MaskedText(this.masked, this.remaining, this.mapping);

  /// Texte avec placeholders, à envoyer au moteur.
  final String masked;

  /// Ce qui reste à traduire une fois les placeholders retirés.
  final String remaining;

  final Map<int, String> mapping;
}

/// Protège de la traduction les éléments qui ne doivent JAMAIS être traduits :
/// URLs, emails, versions, noms de marques / entreprises / technologies /
/// langages de programmation.
class TextProtector {
  /// Noms à préserver tels quels (ordre : les plus longs d'abord pour
  /// l'alternance regex).
  static const List<String> _specialNames = [
    'Node.js', 'VS Code', 'Visual Studio', 'C++', 'C#', '.NET', 'UTF-8',
    'Raspberry Pi',
  ];

  static const List<String> _wordNames = [
    // Langages de programmation
    'JavaScript', 'TypeScript', 'Python', 'Kotlin', 'Swift', 'Dart', 'Ruby',
    'Rust', 'PHP', 'Java', 'SQL', 'HTML', 'CSS', 'JSON', 'YAML', 'XML', 'Go',
    // Frameworks / technos / outils
    'Flutter', 'React', 'Angular', 'Vue', 'TensorFlow', 'PyTorch', 'Docker',
    'Kubernetes', 'PostgreSQL', 'MySQL', 'MongoDB', 'SQLite', 'Redis',
    'GraphQL', 'Markdown', 'WebSocket', 'OAuth', 'Gradle', 'Maven', 'npm',
    'pip', 'Linux', 'Windows', 'macOS', 'Android', 'iOS', 'Git', 'GitHub',
    'GitLab', 'AWS', 'Azure', 'OpenAI', 'Arduino', 'IntelliJ', 'Eclipse',
    // Entreprises / marques
    'Google', 'Apple', 'Microsoft', 'Amazon', 'Meta', 'IBM', 'Oracle',
    'Intel', 'NVIDIA', 'AMD',
    // Sigles techniques
    'API', 'APIs', 'HTTP', 'HTTPS', 'URL', 'SDK', 'IDE', 'CLI', 'REST',
    'JWT', 'CSV', 'PDF', 'ASCII', 'ARM',
  ];

  static final RegExp _protected = RegExp(
    [
      r'https?://\S+', // URLs
      r'[\w.+-]+@[\w-]+\.[A-Za-z]{2,}', // emails
      r'\bv?\d+(?:\.\d+)+\b', // numéros de version : 4.21, v1.2.3
      r'[.…]{4,}\s*\S{0,8}', // points de conduite de sommaire + n° de page
      r'\b(?:' + _wordNames.map(RegExp.escape).join('|') + r')\b',
      _specialNames.map(RegExp.escape).join('|'),
    ].join('|'),
  );

  static final RegExp _placeholder = RegExp(r'\[\[\s*(\d+)\s*\]\]');

  /// Remplace les éléments protégés par des placeholders `[[n]]`.
  static MaskedText mask(String text) {
    final mapping = <int, String>{};
    var index = 0;
    final masked = text.replaceAllMapped(_protected, (match) {
      mapping[index] = match[0]!;
      final placeholder = '[[$index]]';
      index++;
      return placeholder;
    });
    final remaining = masked
        .replaceAll(_placeholder, ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return MaskedText(masked, remaining, mapping);
  }

  /// Restaure les placeholders dans la traduction. Tolérant : certains
  /// moteurs altèrent les crochets (`[[3]]` → `[ 3 ]`, `{3}`…) ; on accepte
  /// une famille de délimiteurs autour de l'identifiant.
  static String restore(String translated, MaskedText masked) {
    return translated.replaceAllMapped(_loosePlaceholder, (match) {
      final id = int.tryParse(match[1]!);
      if (id == null || !masked.mapping.containsKey(id)) return match[0]!;
      return masked.mapping[id]!;
    });
  }

  static final RegExp _loosePlaceholder =
      RegExp(r'[\[⟦{(<«]{1,2}\s*(\d+)\s*[\]⟧})>»]{1,2}');

  /// true si le bloc ne contient quasiment rien à traduire (que des éléments
  /// protégés) : on le laisse alors tel quel, sans calque.
  static bool shouldSkip(String text) => mask(text).remaining.length < 3;
}
