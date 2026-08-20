/// Détecte les blocs qui sont du code source (ou des commandes shell) : ils
/// ne doivent PAS être traduits, le calque les laisse intacts.
class CodeDetector {
  static final RegExp _keywords = RegExp(
    r'\b(?:import|package|func|def|class|public|private|static|void|return|'
    r'const|var|let|println|printf|include|using|namespace|SELECT|FROM|'
    r'WHERE|CREATE|TABLE)\b',
  );
  static final RegExp _symbols = RegExp(r'[{};]|=>|->|==|!=|\(\)|\[\]');
  static final RegExp _identifiers = RegExp(r'[a-z_]+[A-Z]|\w+_\w+');
  static final RegExp _quotes = RegExp('["\'][^"\']*["\']');
  static final RegExp _shellPrompt = RegExp(r'^\s*[\$#>]\s', multiLine: true);

  /// Heuristique par score : >= 3 signaux => code.
  static bool looksLikeCode(String text) {
    var score = 0;
    if (_keywords.hasMatch(text)) score += 2;
    if (_symbols.hasMatch(text)) score += 2;
    if (_identifiers.hasMatch(text)) score += 1;
    if (_quotes.hasMatch(text)) score += 1;
    if (_shellPrompt.hasMatch(text)) score += 1;
    return score >= 3;
  }
}
