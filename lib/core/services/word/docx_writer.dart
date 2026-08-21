import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../../ir/document_ir.dart';
import 'docx_parser.dart';

/// Écrivain DOCX traduit : **édition XML chirurgicale** — seuls les nœuds
/// `w:t` des paragraphes traduits sont modifiés ; styles, tableaux,
/// images, numérotation, en-têtes/pieds et relations restent intacts,
/// donc la mise en forme est préservée par construction.
///
/// Le parcours XML est strictement identique à celui du parseur
/// (mêmes règles, même ordre) : chaque paragraphe traduisible consomme la
/// traduction suivante de la file de sa partie.
class DocxWriter {
  static Future<List<int>> writeTranslated(
    List<int> original,
    IrDocument ir,
    String lang,
  ) async {
    final archive = ZipDecoder().decodeBytes(original);
    final modified = <String, List<int>>{};

    for (final entry in ir.translatableByPart.entries) {
      final part = entry.key;
      final file = archive.findFile(part);
      if (file == null) continue;

      final xml = XmlDocument.parse(
        String.fromCharCodes(file.content as List<int>),
      );
      final root = part == 'word/document.xml'
          ? xml.findAllElements('w:body').first
          : xml.rootElement;

      final iterator = entry.value.iterator;
      _walk(root, (p) {
        if (!iterator.moveNext()) return;
        final element = iterator.current;
        final translation = element.translationFor(lang) ?? element.sourceText;
        _applyTranslation(p, translation);
      });

      modified[part] = utf8.encode(xml.toXmlString());
    }

    final out = Archive();
    for (final file in archive.files) {
      final data = modified[file.name];
      if (data != null) {
        out.addFile(ArchiveFile(file.name, data.length, data));
      } else {
        out.addFile(ArchiveFile(file.name, file.size, file.content));
      }
    }
    return ZipEncoder().encode(out);
  }

  /// Même parcours que le parseur : w:p du conteneur, puis paragraphes des
  /// cellules de chaque w:tbl (un niveau, comme le parseur).
  static void _walk(XmlElement container, void Function(XmlElement) onP) {
    for (final child in container.childElements) {
      final name = child.name.qualified;
      if (name == 'w:p') {
        if (DocxRules.isTranslatable(DocxRules.paragraphText(child))) {
          onP(child);
        }
      } else if (name == 'w:tbl') {
        for (final tr
            in child.childElements.where((e) => e.name.qualified == 'w:tr')) {
          for (final tc in tr.childElements
              .where((e) => e.name.qualified == 'w:tc')) {
            for (final p in tc.childElements
                .where((e) => e.name.qualified == 'w:p')) {
              if (DocxRules.isTranslatable(DocxRules.paragraphText(p))) {
                onP(p);
              }
            }
          }
        }
      }
    }
  }

  /// Toute la traduction dans le premier w:t, les autres vidés : la
  /// structure des runs et leurs propriétés de style restent en place.
  static void _applyTranslation(XmlElement p, String translation) {
    final textNodes = <XmlElement>[
      for (final run in p.findAllElements('w:r'))
        ...run.findAllElements('w:t'),
    ];
    if (textNodes.isEmpty) return;
    var first = true;
    for (final t in textNodes) {
      // xml ≥ 6.5 : pas de setter text — on remplace l'enfant texte.
      t.children.clear();
      t.addChild(XmlText(first ? translation : ''));
      t.setAttribute('xml:space', 'preserve');
      first = false;
    }
  }
}
