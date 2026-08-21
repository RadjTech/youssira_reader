import 'dart:typed_data';

/// Représentation interne indépendante du format (Document IR) — cœur du
/// système (docs/ROADMAP_IR.md). Trois couches séparées :
/// - CONTENU : texte (lignes/spans), tableaux, images ;
/// - SÉMANTIQUE : rôle (titre, paragraphe, légende, en-tête…) ;
/// - LAYOUT : bbox (PDF) ou null (formats fluides comme DOCX), style.
///
/// Le texte original est conservé ; les traductions s'ajoutent par langue
/// (`translations`), un même IR peut donc porter N langues.

/// Rectangle englobant en points PDF, origine HAUT-gauche. Null pour les
/// formats fluides (DOCX).
class IrBbox {
  const IrBbox(this.x, this.y, this.width, this.height);
  final double x, y, width, height;
}

/// Couche style (indépendante du contenu et du layout).
class IrStyle {
  const IrStyle({
    this.fontSize,
    this.bold = false,
    this.italic = false,
    this.alignment,
  });

  /// Corps en points.
  final double? fontSize;
  final bool bold;
  final bool italic;

  /// left / center / right / justify.
  final String? alignment;

  IrStyle copyWith({
    double? fontSize,
    bool? bold,
    bool? italic,
    String? alignment,
  }) =>
      IrStyle(
        fontSize: fontSize ?? this.fontSize,
        bold: bold ?? this.bold,
        italic: italic ?? this.italic,
        alignment: alignment ?? this.alignment,
      );
}

/// Fragment de texte homogène en style (un « run »).
class IrSpan {
  const IrSpan(this.text, this.style);
  final String text;
  final IrStyle style;
}

/// Ligne visuelle (PDF) ou logique (DOCX : une ligne = un paragraphe run).
class IrLine {
  const IrLine(this.spans, {this.bbox});
  final List<IrSpan> spans;
  final IrBbox? bbox;

  String get text => spans.map((s) => s.text).join();
}

/// Rôle sémantique d'un élément texte.
enum IrRole { paragraph, heading, caption, header, footer, code }

/// Relation entre éléments (légende ↔ image, contenu ↔ section…).
class IrRelation {
  const IrRelation(this.type, this.sourceId, this.targetId);

  /// 'caption_of' | 'contained_in'
  final String type;
  final String sourceId;
  final String targetId;
}

/// Élément texte traduisible : paragraphe, titre, légende, en-tête, pied,
/// ou paragraphe de cellule de tableau.
class IrTextElement {
  IrTextElement({
    required this.id,
    required this.role,
    required this.lines,
    required this.style,
    this.bbox,
    this.headingLevel = 0,
  });

  final String id;
  final IrRole role;
  final List<IrLine> lines;
  final IrBbox? bbox;

  /// Style dominant de l'élément.
  final IrStyle style;

  /// 1..n si [role] == heading.
  final int headingLevel;

  /// Langue → traduction. L'original reste dans [lines].
  final Map<String, String> translations = {};

  String get sourceText =>
      lines.map((l) => l.text).join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();

  String? translationFor(String bcp) => translations[bcp];
}

/// Cellule de tableau.
class IrTableCell {
  IrTableCell({
    required this.row,
    required this.column,
    this.rowSpan = 1,
    this.colSpan = 1,
    this.paragraphIds = const [],
  });

  final int row, column, rowSpan, colSpan;

  /// IDs des [IrTextElement] (paragraphes) de la cellule, en ordre.
  final List<String> paragraphIds;
}

/// Tableau : objet de première classe, géométrie préservée à la traduction.
class IrTable {
  IrTable({
    required this.id,
    required this.rows,
    required this.columns,
    required this.cells,
    this.bbox,
  });

  final String id;
  final int rows, columns;
  final List<IrTableCell> cells;
  final IrBbox? bbox;
}

/// Image : jamais fondue dans le texte ; légende portée par un
/// [IrTextElement] relié via `caption_of`.
class IrImage {
  IrImage({required this.id, this.bbox, this.mediaName});

  final String id;
  final IrBbox? bbox;

  /// Chemin dans le package DOCX (word/media/…), null pour PDF.
  final String? mediaName;
}

/// Nœud de page (PDF) ou de flux (DOCX : une seule page logique).
class IrNode {
  IrNode({
    required this.number,
    this.width,
    this.height,
    required this.items,
  });

  final int number;
  final double? width, height;

  /// Items en ordre de lecture : IrTextElement / IrTable / IrImage.
  final List<Object> items;
}

/// Le document IR complet.
class IrDocument {
  IrDocument({required this.id});

  final String id;
  String? language;
  final List<IrNode> nodes = [];

  /// En-têtes / pieds de page (scope document), traduisibles ou non.
  final List<IrTextElement> headerElements = [];
  final List<IrTextElement> footerElements = [];

  final List<IrRelation> relations = [];

  /// Médias embarqués (DOCX) : nom d'entrée → octets.
  final Map<String, Uint8List> media = {};

  /// Éléments texte traduisibles, en ordre du document (corps), y compris
  /// les paragraphes de tableaux. C'est LA liste ordonnée qu'utilisent le
  /// traducteur et l'écrivain DOCX (parcours déterministe).
  final List<IrTextElement> translatable = [];

  /// Même listes, par partie du package DOCX (word/document.xml,
  /// word/header1.xml…) : l'écrivain consomme chaque file dans l'ordre de
  /// son propre parcours XML, strictement identique au parseur.
  final Map<String, List<IrTextElement>> translatableByPart = {};

  final Map<String, IrTextElement> _byId = {};

  void registerText(IrTextElement element, {bool translatable = true}) {
    _byId[element.id] = element;
    if (translatable) translatable.add(element);
  }

  IrTextElement? byId(String id) => _byId[id];

  int get translatableCount => translatable.length;
}
