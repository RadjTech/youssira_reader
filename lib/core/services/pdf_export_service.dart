import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;
// PdfDocument vient de pdfrx ; on masque celui du package pdf.
import 'package:pdf/pdf.dart' hide PdfDocument;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';

import '../../features/reader/reader_controller.dart';
import '../models/text_block.dart';

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
    final source = await PdfDocument.openFile(sourcePath);
    final doc = pw.Document();
    final pages = source.pages.length;

      for (var n = 1; n <= pages; n++) {
        onProgress(((n - 1) / pages) * 0.9, 'Export — page $n/$pages');
        final page = source.pages[n - 1];
        final format = PdfPageFormat(page.width, page.height);
        final blocks = controller.blocksForPage(n);

        pw.Widget background = pw.SizedBox();
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
          }
        }

        doc.addPage(
          pw.Page(
            pageFormat: format,
            build: (context) => pw.Stack(
              children: [
                background,
                for (final block in blocks)
                  ..._blockWidgets(block, controller, imageBased, page.height),
              ],
            ),
          ),
        );
      }

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

  /// Patch + texte traduit d'un bloc (ou texte original en mode léger si le
  /// bloc n'est pas traduit / a été volontairement ignoré).
  static List<pw.Widget> _blockWidgets(
    TextBlock block,
    ReaderController controller,
    bool imageBased,
    double pageHeight,
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

    return [
      pw.Positioned(
        left: block.left,
        top: pageHeight - block.top,
        child: pw.SizedBox(
          width: block.width,
          child: pw.Container(
            // En mode fidèle, le patch recouvre le texte original de l'image.
            color: done && imageBased ? patch : null,
            child: pw.Text(
              text,
              textAlign: pw.TextAlign.left,
              style: pw.TextStyle(
                font:
                    block.bold ? pw.Font.helveticaBold() : pw.Font.helvetica(),
                fontSize: block.fontSizeHint,
                color: color,
              ),
            ),
          ),
        ),
      ),
    ];
  }
}
