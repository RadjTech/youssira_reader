/// Détecte les blocs qui sont du code source (ou des commandes shell) : ils
/// ne doivent PAS être traduits, le calque les laisse intacts.
class CodeDetector {
  static final RegExp _keywords = RegExp(
    r'\b(?:import|package|func|def|class|public|private|static|void|return|'
    r'const|var|let|println|printf|include|using|namespace|SELECT|FROM|'
    r'WHERE|CREATE|TABLE|init|mod|main)\b',
    caseSensitive: false, // fmt.Println, IMPORT, Func…
  );
  static final RegExp _symbols = RegExp(r'[{};]|=>|->|==|!=|\(\)|\[\]');
  static final RegExp _identifiers = RegExp(r'[a-z_]+[A-Z]|\w+_\w+');
  static final RegExp _quotes = RegExp('["\'][^"\']*["\']');
  static final RegExp _shellPrompt = RegExp(r'^\s*[\$#>]\s', multiLine: true);

  /// Ligne de commande : `go mod init …`, `git clone …`, `npm install …`
  static final RegExp _command = RegExp(
    r'^\s*(?:go|git|npm|pip3?|docker|kubectl|cd|mkdir|curl|wget|make|cargo|'
    r'rustc|javac|python3?)\s+\S',
  );

  /// Identifiant nu : commence en minuscule, aucune ponctuation de phrase
  /// (`.`, `,`, `?`, `!`) — typique de `package main`, `go.mod`…
  static final RegExp _bareIdentifier = RegExp(r'^[a-z_][\w.\- ]*$');

  static bool looksLikeCode(String text) {
    final trimmed = text.trim();
    if (trimmed.length > 80) return false; // une vraie ligne de code est courte

    if (_command.hasMatch(trimmed)) return true;
    if (_bareIdentifier.hasMatch(trimmed) &&
        !RegExp(r'[.,;?!]').hasMatch(trimmed)) {
      return true;
    }

    var score = 0;
    if (_keywords.hasMatch(trimmed)) score += 2;
    if (_symbols.hasMatch(trimmed)) score += 2;
    if (_identifiers.hasMatch(trimmed)) score += 1;
    if (_quotes.hasMatch(trimmed)) score += 1;
    if (_shellPrompt.hasMatch(trimmed)) score += 1;
    return score >= 3;
  }
}
