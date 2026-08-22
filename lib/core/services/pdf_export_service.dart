import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;
// PdfDocument vient de pdfrx ; on masque celui du package pdf.
import 'package:pdf/pdf.dart' hide PdfDocument;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';

import '../../features/reader/reader_controller.dart';
import '../models/text_block.dart';
import 'pdf/block_layout.dart';

/// Export du document traduit en PDF, deux formats :
/// - **fidèle** (imageBased) : chaque page originale rendue en image, avec
///   patch + texte traduit posés par-dessus, comme le calque à l'écran ;
/// - **léger** : reconstruction texte seule (blocs traduits positionnés
///   comme l'original ; blocs ignorés remis en texte original).
class PdfExportService {
  /// Langues cibles supportées par les polices intégrées (v1 : latin).
  static const Set<String> _latinTargets = {'fr', 'en', 'es', 'de', 'pt'};

  static bool supportsTarget(String bcp) => _latinTargets.contains(bcp);

  /// Génère le PDF traduit et propose l'emplacement d'enregistrement.
  /// Retourne le chemin final, ou null si l'utilisateur annule.
  static Future<String?> exportTranslatedPdf({
    required String sourcePath,
    required ReaderController controller,
    required bool imageBased,
    required void Function(double? progress, String label) onProgress,
  }) async {
    final doc = await _compose(
      sourcePath: sourcePath,
      controller: controller,
      imageBased: imageBased,
      onProgress: onProgress,
    );

    onProgress(0.95, 'Enregistrement…');
    final bytes = await doc.save();

    final base = sourcePath
        .split(Platform.pathSeparator)
        .last
        .replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '');
    final outUri = await FilePicker.saveFile(
      fileName: '$base-traduit.pdf',
      bytes: bytes,
      mimeType: 'application/pdf',
      dialogTitle: 'Enregistrer le PDF traduit',
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
    );
    if (outUri == null) return null;
    onProgress(1.0, 'Terminé');
    // file_picker écrit déjà les bytes (SAF). On renvoie un chemin lisible.
    return outUri.scheme == 'file' ? outUri.toFilePath() : outUri.toString();
  }

  /// Mode « document traduit » (Xodo) : compose le PDF recomposé et
  /// l'enregistre sur disque pour ouverture directe dans le viewer.
  static Future<String> buildTranslatedPdfToFile({
    required String sourcePath,
    required ReaderController controller,
    required String outPath,
    required void Function(double? progress, String label) onProgress,
  }) async {
    final doc = await _compose(
      sourcePath: sourcePath,
      controller: controller,
      imageBased: true,
      onProgress: onProgress,
    );
    onProgress(0.95, 'Enregistrement…');
    final bytes = await doc.save();
    await File(outPath).writeAsBytes(bytes);
    onProgress(1.0, 'Terminé');
    return outPath;
  }

  /// Compose le document traduit : page originale en image (mode fidèle) +
  /// patchs + texte traduit reflowé par le moteur de mise en page du
  /// package pdf (pleine largeur utile, titres centrés).
  static Future<pw.Document> _compose({
    required String sourcePath,
    required ReaderController controller,
    required bool imageBased,
    required void Function(double? progress, String label) onProgress,
  }) async {
    final source = await PdfDocument.openFile(sourcePath);
    try {
      final doc = pw.Document();
      final pages = source.pages.length;

      for (var n = 1; n <= pages; n++) {
        onProgress(((n - 1) / pages) * 0.9, 'Composition — page $n/$pages');
        final page = source.pages[n - 1];
        final format = PdfPageFormat(page.width, page.height);
        final blocks = controller.blocksForPage(n);

        // Mêmes « marges de page » que le calque à l'écran (BlockLayout).
        final margins = BlockLayout.pageMargins(blocks, page.width);

        pw.Widget background;
        if (imageBased) {
          final rendered = await page.render(
            width: (page.width * 1.5).round(),
            height: (page.height * 1.5).round(),
          );
          if (rendered != null) {
            final image = rendered.createImageNF();
            rendered.dispose();
            final jpeg = img.encodeJpg(image, quality: 85);
            background = pw.Positioned.fill(
              child: pw.Image(pw.MemoryImage(jpeg), fit: pw.BoxFit.fill),
            );
          } else {
            background =
                pw.SizedBox(width: page.width, height: page.height);
          }
        } else {
          // IMPORTANT : enfant NON positionné aux dimensions de la page,
          // sinon le Stack se replie sur 0×0 et tout le contenu positionné
          // sort de la page (bug du « document tout blanc »).
          background = pw.SizedBox(width: page.width, height: page.height);
        }

        doc.addPage(
          pw.Page(
            pageFormat: format,
            build: (context) => pw.Stack(
              children: [
                background,
                for (final block in blocks)
                  ..._blockWidgets(
                    block,
                    controller,
                    imageBased,
                    page.height,
                    page.width,
                    margins.left,
                    margins.right,
                    blocks,
                  ),
              ],
            ),
          ),
        );
      }
      return doc;
    } finally {
      await source.dispose();
    }
  }

  /// Patch + texte traduit d'un bloc (ou texte original en mode léger si le
  /// bloc n'est pas traduit / a été volontairement ignoré).
  static List<pw.Widget> _blockWidgets(
    TextBlock block,
    ReaderController controller,
    bool imageBased,
    double pageHeight,
    double pageWidth,
    double leftMargin,
    double rightMargin,
    List<TextBlock> allBlocks,
  ) {
    final progress = controller.progressFor(block.id);
    final translated = progress?.translatedText;
    final done = progress?.state == BlockState.done && translated != null;

    String? text;
    if (done) {
      text = translated;
    } else if (!imageBased) {
      // Mode léger : le document doit rester lisible partout — les blocs
      // ignorés (code, marques…) et non traduits gardent l'original.
      text = block.text;
    }
    if (text == null) return const [];

    final color = PdfColor.fromInt(block.textColor & 0xFFFFFF);
    final patch = PdfColor.fromInt(block.backgroundColor & 0xFFFFFF);

    // Largeur étendue jusqu'aux marges/obstacles ; titres centrés (même
    // logique que le calque à l'écran).
    final layout = BlockLayout.forBlock(
      block,
      pageWidth: pageWidth,
      leftMargin: leftMargin,
      rightMargin: rightMargin,
      allBlocks: allBlocks,
    );

    final textWidget = pw.Text(
      text,
      textAlign: layout.centered ? pw.TextAlign.center : pw.TextAlign.left,
      style: pw.TextStyle(
        font: _blockFont(block),
        fontSize: block.fontSizeHint,
        color: color,
      ),
    );

    return [
      pw.Positioned(
        left: layout.left,
        top: pageHeight - block.top,
        child: pw.SizedBox(
          width: layout.width,
          child: pw.Stack(
            overflow: pw.Overflow.visible,
            children: [
              // En mode fidèle, le patch recouvre le texte original de
              // l'image — limité à la boîte d'origine pour ne jamais
              // effacer traits/logos situés sous le bloc.
              if (done && imageBased)
                pw.Positioned(
                  left: 0,
                  top: 0,
                  right: 0,
                  child: pw.SizedBox(
                    height: block.height,
                    child: pw.Container(color: patch),
                  ),
                ),
              textWidget,
            ],
          ),
        ),
      ),
    ];
  }

  /// Police d'export la plus proche de la famille d'origine (polices
  /// standard du package pdf : Times pour serif, Courier pour mono,
  /// Helvetica pour sans).
  static pw.Font _blockFont(TextBlock block) {
    switch (block.family) {
      case TextFamily.serif:
        if (block.bold && block.italic) return pw.Font.timesBoldItalic();
        if (block.bold) return pw.Font.timesBold();
        if (block.italic) return pw.Font.timesItalic();
        return pw.Font.times();
      case TextFamily.mono:
        if (block.bold && block.italic) return pw.Font.courierBoldOblique();
        if (block.bold) return pw.Font.courierBold();
        if (block.italic) return pw.Font.courierOblique();
        return pw.Font.courier();
      case TextFamily.sans:
        if (block.bold && block.italic) return pw.Font.helveticaBoldOblique();
        if (block.bold) return pw.Font.helveticaBold();
        if (block.italic) return pw.Font.helveticaOblique();
        return pw.Font.helvetica();
    }
  }
}
