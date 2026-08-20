import 'dart:io';

// NB : ML Kit définit aussi une classe `TextBlock` — on la masque pour
// utiliser notre modèle métier (core/models/text_block.dart).
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart'
    hide TextBlock;
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import '../models/text_block.dart';
import 'style_extractor.dart';

/// OCR on-device (ML Kit Text Recognition v2) pour les pages sans texte natif
/// (PDF scannés, photos de documents).
///
/// Pipeline : rendu bitmap de la page (~150 dpi) → reconnaissance ML Kit →
/// conversion des bounding boxes pixels vers les coordonnées PDF (points) →
/// analyse de style sur le même rendu.
class OcrService {
  OcrService({TextRecognitionScript script = TextRecognitionScript.latin})
      : _recognizer = TextRecognizer(script: script);

  final TextRecognizer _recognizer;

  static const _renderDpi = 150.0;

  Future<List<TextBlock>> recognizePage(PdfPage page) async {
    const scale = _renderDpi / 72.0; // points → pixels
    final width = (page.width * scale).round();
    final height = (page.height * scale).round();

    // 1. Rendu de la page en image (sert à l'OCR ET à l'analyse de style).
    final rendered = await page.render(width: width, height: height);
    if (rendered == null) return const [];
    final image = rendered.createImageNF();
    rendered.dispose();

    // 2. ML Kit lit depuis un fichier : on écrit un PNG temporaire.
    final tmp = await getTemporaryDirectory();
    final file = File('${tmp.path}/youssira_ocr_p${page.pageNumber}.png');
    await file.writeAsBytes(img.encodePng(image), flush: true);

    List<TextBlock> blocks;
    try {
      final inputImage = InputImage.fromFilePath(file.path);
      final recognized = await _recognizer.processImage(inputImage);

      // 3. Conversion pixels (origine haut-gauche) → points PDF (bas-gauche).
      blocks = [
        for (final textBlock in recognized.blocks)
          for (final line in textBlock.lines)
            if (line.text.trim().isNotEmpty)
              TextBlock(
                id: TextBlock.computeId(line.text),
                pageNumber: page.pageNumber,
                text: line.text.trim(),
                left: line.boundingBox.left / scale,
                right: line.boundingBox.right / scale,
                top: page.height - line.boundingBox.top / scale,
                bottom: page.height - line.boundingBox.bottom / scale,
                source: BlockSource.ocr,
                fontSizeHint: line.boundingBox.height / scale,
              ),
      ];
    } finally {
      if (await file.exists()) {
        await file.delete();
      }
    }

    // 4. Styles échantillonnés sur le même rendu.
    final styles = StyleExtractor.analyze(
      image,
      blocks,
      pageWidthPt: page.width,
      pageHeightPt: page.height,
    );
    return [
      for (var i = 0; i < blocks.length; i++)
        blocks[i].copyWithStyle(
          textColor: styles[i].textColor,
          backgroundColor: styles[i].backgroundColor,
          bold: styles[i].bold,
        ),
    ];
  }

  Future<void> dispose() => _recognizer.close();
}
