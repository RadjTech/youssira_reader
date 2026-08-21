import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../../core/app_services.dart';
import '../../core/ir/document_ir.dart';
import '../../core/models/reader_settings.dart';
import '../../core/services/language_detector.dart';
import '../../core/services/word/docx_parser.dart';
import '../../core/services/word/docx_writer.dart';

/// État d'un document Word ouvert : IR + traduction + export .docx.
class WordController extends ChangeNotifier {
  WordController({
    required this.fileName,
    required this.originalBytes,
    ReaderSettings settings = const ReaderSettings(),
  }) : _settings = settings;

  final String fileName;
  final List<int> originalBytes;

  final ReaderSettings _settings;
  ReaderSettings get settings => _settings;

  final LanguageDetector _detector = LanguageDetector();

  IrDocument? _ir;
  IrDocument? get ir => _ir;

  String? _detected;
  bool _loading = true;
  bool get loading => _loading;
  bool translating = false;
  double progress = 0;
  String? error;

  Future<void> load() async {
    try {
      _ir = await DocxParser.parse(originalBytes, id: fileName);
      final sample =
          _ir!.translatable.take(3).map((e) => e.sourceText).join(' ');
      _detected = await _detector.detect(sample);
    } catch (e) {
      error = '$e';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Paire effective : détection de langue + correction de direction,
  /// comme pour le PDF.
  ({String from, String to}) get pair {
    final detected = _detected;
    if (detected != null && detected == _settings.targetBcp) {
      return (from: detected, to: _settings.sourceBcp);
    }
    return (from: _settings.sourceBcp, to: _settings.targetBcp);
  }

  bool get hasTranslations =>
      _ir?.translatable.any((e) => e.translationFor(pair.to) != null) ??
      false;

  /// Traduit tout le document (corps + en-têtes/pieds), avec progression.
  /// Lève QuotaExceededException si la limite gratuite est atteinte.
  Future<void> translateAll() async {
    final ir = _ir;
    if (ir == null || translating) return;
    translating = true;
    progress = 0;
    error = null;
    notifyListeners();
    try {
      final p = pair;
      await AppServices.instance.translationService.prepareEngine(
        _settings.engine,
        fromBcp: p.from,
        toBcp: p.to,
      );

      if (!AppServices.instance.entitlements.isPro) {
        final chars =
            ir.translatable.fold<int>(0, (a, e) => a + e.sourceText.length);
        AppServices.instance.limits.consumeCharPages(chars);
      }

      final all = [
        ...ir.translatable,
        ...ir.headerElements,
        ...ir.footerElements,
      ];
      final targets = [
        for (final e in all)
          if (e.translationFor(p.to) == null &&
              DocxRules.isTranslatable(e.sourceText))
            e,
      ];
      var done = 0;
      for (final e in targets) {
        final res = await AppServices.instance.translationService
            .translateText(
          e.sourceText,
          engine: _settings.engine,
          fromBcp: p.from,
          toBcp: p.to,
        );
        e.translations[p.to] = res.translated;
        done++;
        if (done % 3 == 0 || done == targets.length) {
          progress = targets.isEmpty ? 1 : done / targets.length;
          notifyListeners();
        }
      }
      progress = 1;
    } finally {
      translating = false;
      notifyListeners();
    }
  }

  /// Exporte le .docx traduit (mise en forme 100 % préservée).
  Future<String?> exportTranslated() async {
    final ir = _ir;
    if (ir == null) return null;
    final bytes = await DocxWriter.writeTranslated(originalBytes, ir, pair.to);

    final base =
        fileName.replaceAll(RegExp(r'\.docx$', caseSensitive: false), '');
    final outPath = await FilePicker.saveFile(
      dialogTitle: 'Enregistrer le document traduit',
      fileName: '$base-traduit.docx',
      type: FileType.custom,
      allowedExtensions: const ['docx'],
    );
    if (outPath == null) return null;
    final target =
        outPath.toLowerCase().endsWith('.docx') ? outPath : '$outPath.docx';
    await File(target).writeAsBytes(bytes);
    return target;
  }

  @override
  void dispose() {
    _detector.dispose();
    super.dispose();
  }
}
