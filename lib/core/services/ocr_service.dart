import 'dart:io';

// NB : ML Kit définit aussi une classe `TextBlock` — on la masque pour
// utiliser notre modèle métier (core/models/text_block.dart).
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart'
    hide TextBlock;
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import '../models/text_block.dart';

/// OCR on-device (ML Kit Text Recognition v2) pour les pages sans texte natif
/// (PDF scannés, photos de documents).
///
/// Pipeline : rendu bitmap de la page (~150 dpi) → reconnaissance ML Kit →
/// conversion des bounding boxes pixels vers les coordonnées PDF (points).
class OcrService {
  OcrService({TextRecognitionScript script = TextRecognitionScript.latin})
      : _recognizer = TextRecognizer(script: script);

  final TextRecognizer _recognizer;

  static const _renderDpi = 150.0;

  Future<List<TextBlock>> recognizePage(PdfPage page) async {
    const scale = _renderDpi / 72.0; // points → pixels
    final width = (page.width * scale).round();
    final height = (page.height * scale).round();

    // 1. Rendu de la page en image.
    final rendered = await page.render(width: width, height: height);
    if (rendered == null) return const [];
    final image = rendered.createImageNF();
    rendered.dispose();

    // 2. ML Kit lit depuis un fichier : on écrit un PNG temporaire.
    final tmp = await getTemporaryDirectory();
    final file = File('${tmp.path}/youssira_ocr_p${page.pageNumber}.png');
    await file.writeAsBytes(img.encodePng(image), flush: true);

    final blocks = <TextBlock>[];
    try {
      final inputImage = InputImage.fromFilePath(file.path);
      final recognized = await _recognizer.processImage(inputImage);

      // 3. Conversion pixels (origine haut-gauche) → points PDF (bas-gauche).
      for (final textBlock in recognized.blocks) {
        for (final line in textBlock.lines) {
          final text = line.text.trim();
          final px = line.boundingBox;
          if (text.isEmpty) continue;

          blocks.add(
            TextBlock(
              id: TextBlock.computeId(text),
              pageNumber: page.pageNumber,
              text: text,
              left: px.left / scale,
              right: px.right / scale,
              top: page.height - px.top / scale,
              bottom: page.height - px.bottom / scale,
              source: BlockSource.ocr,
              fontSizeHint: px.height / scale,
            ),
          );
        }
      }
    } finally {
      if (await file.exists()) {
        await file.delete();
      }
    }
    return blocks;
  }

  Future<void> dispose() => _recognizer.close();
}
