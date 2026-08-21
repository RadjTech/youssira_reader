import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../../ir/document_ir.dart';
import '../translation/code_detector.dart';
import '../translation/text_protector.dart';

/// Règles partagées parseur/écrivain : le parcours DOCX est déterministe,
/// l'écrivain retrouve exactement les mêmes paragraphes traduisibles dans
/// le même ordre (édition chirurgicale des w:t).
class DocxRules {
  static final _captionRe = RegExp(
    r'^(figure|fig\.|tableau|table|annexe|appendix)\b',
    caseSensitive: false,
  );

  /// Texte d'un paragraphe (ou d'un run) : w:t + tabulations/retours.
  static String paragraphText(XmlElement element) {
    final buffer = StringBuffer();
    for (final node in element.descendantElements) {
      final name = node.name.qualified;
      if (name == 'w:t') {
        buffer.write(node.innerText);
      } else if (name == 'w:tab' || name == 'w:br') {
        buffer.write(' ');
      }
    }
    return buffer.toString();
  }

  static bool isTranslatable(String text) {
    final t = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.isEmpty) return false;
    if (CodeDetector.looksLikeCode(t)) return false;
    if (TextProtector.shouldSkip(t)) return false;
    return true;
  }

  static IrRole roleFor(String text, int headingLevel) {
    if (headingLevel > 0) return IrRole.heading;
    if (CodeDetector.looksLikeCode(text)) return IrRole.code;
    if (_captionRe.hasMatch(text.trim())) return IrRole.caption;
    return IrRole.paragraph;
  }
}

/// Parseur DOCX → Document IR (pur Dart, 100 % hors-ligne).
///
/// DOCX = ZIP de XML : le format porte déjà contenu + sémantique
/// (styles nommés, tableaux natifs, en-têtes/pieds séparés) — l'IR est
/// renseigné en ground-truth, sans heuristiques.
class DocxParser {
  DocxParser._(this.ir);

  final IrDocument ir;
  int _counter = 0;
  String? _lastImageId;

  static Future<IrDocument> parse(List<int> bytes, {required String id}) async {
    return DocxParser._(IrDocument(id: id))._parse(bytes);
  }

  String _nextId(String prefix) => '$prefix${_counter++}';

  IrDocument _parse(List<int> bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);

    String? read(String name) {
      final file = archive.findFile(name);
      if (file == null) return null;
      return String.fromCharCodes(file.content as List<int>);
    }

    // Médias embarqués (images).
    for (final file in archive.files) {
      if (file.name.startsWith('word/media/')) {
        ir.media[file.name] = Uint8List.fromList(file.content as List<int>);
      }
    }

    final styles = _parseStyles(read('word/styles.xml'));
    final rels = _parseRels(read('word/_rels/document.xml.rels'));

    final documentXml = read('word/document.xml');
    if (documentXml == null) {
      throw const FormatException('document.xml introuvable : pas un DOCX ?');
    }

    // --- Corps ------------------------------------------------------
    final bodyItems = <Object>[];
    final body = XmlDocument.parse(documentXml).findAllElements('w:body').first;
    _walkContainer(body, styles, rels, bodyItems, 'word/document.xml', null);
    ir.nodes.add(IrNode(number: 1, items: bodyItems));

    // --- En-têtes / pieds --------------------------------------------
    for (final file in archive.files) {
      final isHeader = RegExp(r'^word/header\d*\.xml$').hasMatch(file.name);
      final isFooter = RegExp(r'^word/footer\d*\.xml$').hasMatch(file.name);
      if (!isHeader && !isFooter) continue;
      final root = XmlDocument.parse(
        String.fromCharCodes(file.content as List<int>),
      ).rootElement;
      _walkContainer(
        root,
        styles,
        rels,
        null,
        file.name,
        isHeader ? IrRole.header : IrRole.footer,
      );
    }

    return ir;
  }

  /// Parcours déterministe : paragraphes, tableaux, images en ordre.
  void _walkContainer(
    XmlElement container,
    Map<String, int> styles,
    Map<String, String> rels,
    List<Object>? items,
    String part,
    IrRole? scopeRole,
  ) {
    for (final child in container.childElements) {
      final name = child.name.qualified;
      if (name == 'w:p') {
        final parsed = _parseParagraph(child, styles, rels, scopeRole, part);
        if (parsed.image != null) items?.add(parsed.image!);
        if (parsed.text != null) {
          items?.add(parsed.text!);
          if (parsed.text!.role == IrRole.caption && _lastImageId != null) {
            ir.relations.add(
              IrRelation('caption_of', parsed.text!.id, _lastImageId!),
            );
          }
        }
      } else if (name == 'w:tbl') {
        if (scopeRole == null) {
          items?.add(_parseTable(child, styles, rels, part));
        } else {
          // Tableau dans en-tête/pied : paragraphes lus à plat.
          _walkContainer(child, styles, rels, null, part, scopeRole);
        }
      }
    }
  }

  /// Paragraphe → image éventuelle + élément texte éventuel.
  ({IrImage? image, IrTextElement? text}) _parseParagraph(
    XmlElement p,
    Map<String, int> styles,
    Map<String, String> rels,
    IrRole? scopeRole,
    String part,
  ) {
    IrImage? image;
    final blips = p.findAllElements('a:blip');
    if (blips.isNotEmpty) {
      final relId = blips.first.getAttribute('r:embed');
      final target = relId == null ? null : rels[relId];
      if (target != null) {
        final mediaName = _normalizeMedia(
          target.startsWith('/') ? target.substring(1) : 'word/$target',
        );
        image = IrImage(id: _nextId('img'), mediaName: mediaName);
        _lastImageId = image.id;
      }
    }

    // Rôle sémantique via styles nommés (ground-truth OOXML).
    int headingLevel = 0;
    String? alignment;
    final pPr = p.getElement('w:pPr');
    if (pPr != null) {
      final styleId = pPr.getElement('w:pStyle')?.getAttribute('w:val');
      if (styleId != null) headingLevel = styles[styleId] ?? 0;
      alignment = pPr.getElement('w:jc')?.getAttribute('w:val');
    }

    // Runs → spans (un run peut être niché dans w:hyperlink).
    final spans = <IrSpan>[];
    for (final run in p.findAllElements('w:r')) {
      final text = DocxRules.paragraphText(run);
      if (text.isEmpty) continue;
      var style = _runStyle(run);
      if (alignment != null) style = style.copyWith(alignment: alignment);
      spans.add(IrSpan(text, style));
    }
    if (spans.isEmpty) return (image: image, text: null);

    final text = spans.map((s) => s.text).join();
    final element = IrTextElement(
      id: _nextId('t'),
      role: scopeRole ?? DocxRules.roleFor(text, headingLevel),
      lines: [IrLine(spans)],
      style: spans.first.style,
      headingLevel: headingLevel,
    );

    final translatable = DocxRules.isTranslatable(text);
    if (scopeRole == IrRole.header) {
      ir.headerElements.add(element);
    } else if (scopeRole == IrRole.footer) {
      ir.footerElements.add(element);
    } else {
      ir.registerText(element, translatable: false);
      if (translatable) ir.translatable.add(element);
    }
    if (translatable) {
      (ir.translatableByPart[part] ??= []).add(element);
    }
    return (image: image, text: element);
  }

  static String _normalizeMedia(String target) =>
      target.replaceAll('../', '');

  IrStyle _runStyle(XmlElement run) {
    final rPr = run.getElement('w:rPr');
    bool flag(String tag) {
      final el = rPr?.getElement(tag);
      if (el == null) return false;
      final v = el.getAttribute('w:val');
      return v == null || (v != '0' && v != 'false');
    }

    final sz = rPr?.getElement('w:sz')?.getAttribute('w:val');
    return IrStyle(
      fontSize: sz == null ? null : (double.tryParse(sz) ?? 0) * 0.5,
      bold: flag('w:b'),
      italic: flag('w:i'),
    );
  }

  IrTable _parseTable(
    XmlElement tbl,
    Map<String, int> styles,
    Map<String, String> rels,
    String part,
  ) {
    final cells = <IrTableCell>[];
    var rows = 0;
    var columns = 0;
    for (final tr
        in tbl.childElements.where((e) => e.name.qualified == 'w:tr')) {
      var column = 0;
      for (final tc
          in tr.childElements.where((e) => e.name.qualified == 'w:tc')) {
        final tcPr = tc.getElement('w:tcPr');
        final colSpan = int.tryParse(
                tcPr?.getElement('w:gridSpan')?.getAttribute('w:val') ?? '1') ??
            1;
        final vMerge = tcPr?.getElement('w:vMerge');
        final isContinuation = vMerge != null &&
            (vMerge.getAttribute('w:val') ?? '') != 'restart';
        if (isContinuation) {
          column += colSpan;
          continue;
        }

        final paragraphIds = <String>[];
        for (final p
            in tc.childElements.where((e) => e.name.qualified == 'w:p')) {
          final parsed = _parseParagraph(p, styles, rels, null, part);
          if (parsed.text != null) paragraphIds.add(parsed.text!.id);
        }
        cells.add(IrTableCell(
          row: rows,
          column: column,
          colSpan: colSpan,
          paragraphIds: paragraphIds,
        ));
        column += colSpan;
      }
      columns = column > columns ? column : columns;
      rows++;
    }
    return IrTable(id: _nextId('tbl'), rows: rows, columns: columns, cells: cells);
  }

  /// styleId → niveau de titre (0 sinon), via noms de styles + basedOn.
  static Map<String, int> _parseStyles(String? stylesXml) {
    final out = <String, int>{};
    if (stylesXml == null) return out;
    final doc = XmlDocument.parse(stylesXml);
    final names = <String, String>{};
    final basedOn = <String, String>{};
    for (final style in doc.findAllElements('w:style')) {
      final id = style.getAttribute('w:styleId');
      if (id == null) continue;
      names[id] = style.getElement('w:name')?.getAttribute('w:val') ?? '';
      final bo = style.getElement('w:basedOn')?.getAttribute('w:val');
      if (bo != null) basedOn[id] = bo;
    }
    final levelRe =
        RegExp(r'(?:heading|titre|title)\s*(\d+)', caseSensitive: false);
    int levelOf(String id) {
      var current = id;
      for (var i = 0; i < 5; i++) {
        final m = levelRe.firstMatch(names[current] ?? '') ??
            levelRe.firstMatch(current);
        if (m != null) return int.parse(m.group(1)!);
        final bo = basedOn[current];
        if (bo == null) break;
        current = bo;
      }
      return 0;
    }

    for (final id in names.keys) {
      out[id] = levelOf(id);
    }
    return out;
  }

  static Map<String, String> _parseRels(String? relsXml) {
    final out = <String, String>{};
    if (relsXml == null) return out;
    final doc = XmlDocument.parse(relsXml);
    for (final rel in doc.findAllElements('Relationship')) {
      final id = rel.getAttribute('Id');
      final target = rel.getAttribute('Target');
      if (id != null && target != null) out[id] = target;
    }
    return out;
  }
}
