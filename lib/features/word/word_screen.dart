import 'package:flutter/material.dart';

import '../../core/app_services.dart';
import '../../core/ir/document_ir.dart';
import '../../core/services/monetization/limits_service.dart';
import '../monetization/limit_dialog.dart';
import 'word_controller.dart';

enum _WordMode { original, parallel }

/// Lecture d'un document Word : rendu stylé fidèle (titres, gras, italique,
/// tableaux, images) + vue parallèle original/traduction + export .docx
/// traduit à mise en forme préservée.
class WordScreen extends StatefulWidget {
  const WordScreen({super.key, required this.controller});

  final WordController controller;

  @override
  State<WordScreen> createState() => _WordScreenState();
}

class _WordScreenState extends State<WordScreen> {
  _WordMode _mode = _WordMode.original;

  WordController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _controller.load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _translateAll() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _controller.translateAll();
    } on QuotaExceededException {
      if (!mounted) return;
      final unlocked = await LimitDialog.show(context, 'pages');
      if (unlocked && mounted) {
        try {
          await _controller.translateAll();
        } catch (e) {
          messenger.showSnackBar(
            SnackBar(content: Text('Traduction impossible : $e')),
          );
        }
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Traduction impossible : $e')),
      );
    }
  }

  Future<void> _export() async {
    final messenger = ScaffoldMessenger.of(context);
    if (!_controller.hasTranslations) {
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text("Traduire d'abord ?"),
          content: const Text(
            "Le document n'est pas encore traduit. Traduire avant "
            "l'export ?",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Traduire puis exporter'),
            ),
          ],
        ),
      );
      if (go != true) return;
      await _translateAll();
      if (!_controller.hasTranslations) return;
    }

    if (!AppServices.instance.entitlements.isPro) {
      try {
        AppServices.instance.limits.tryConsumeExport();
      } on QuotaExceededException {
        if (!mounted) return;
        final unlocked = await LimitDialog.show(context, 'exports');
        if (!unlocked) return;
      }
    }

    try {
      final path = await _controller.exportTranslated();
      if (!mounted) return;
      if (!AppServices.instance.entitlements.isPro) {
        await AppServices.instance.ads.showInterstitial();
      }
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            path == null
                ? 'Export annulé.'
                : 'Document traduit enregistré :\n$path',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Export impossible : $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final ir = _controller.ir;
        return Scaffold(
          appBar: AppBar(
            title: Text(
              _controller.fileName,
              overflow: TextOverflow.ellipsis,
            ),
            actions: [
              PopupMenuButton<_WordMode>(
                tooltip: 'Mode de lecture',
                icon: Icon(
                  _mode == _WordMode.parallel
                      ? Icons.view_agenda_outlined
                      : Icons.article_outlined,
                ),
                onSelected: (m) => setState(() => _mode = m),
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: _WordMode.original,
                    child: Text('Document original'),
                  ),
                  PopupMenuItem(
                    value: _WordMode.parallel,
                    child: Text('Original + traduction'),
                  ),
                ],
              ),
              IconButton(
                tooltip: 'Traduire tout le document',
                icon: _controller.translating
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.done_all),
                onPressed:
                    _controller.translating ? null : () => _translateAll(),
              ),
              IconButton(
                tooltip: 'Exporter le .docx traduit',
                icon: const Icon(Icons.file_download_outlined),
                onPressed: _controller.loading ? null : _export,
              ),
            ],
          ),
          body: _controller.loading
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 12),
                      Text('Ouverture du document…'),
                    ],
                  ),
                )
              : _controller.error != null
                  ? Center(child: Text('Ouverture impossible :\n'
                      '${_controller.error}'))
                  : Stack(
                      children: [
                        ListView(
                          padding: const EdgeInsets.all(16),
                          children: [
                            for (final item in ir?.nodes.first.items ??
                                const <Object>[])
                              _buildItem(item),
                            const SizedBox(height: 48),
                          ],
                        ),
                        if (_controller.translating)
                          Positioned(
                            left: 8,
                            right: 8,
                            bottom: 8,
                            child: Card(
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Text('Traduction du document…'),
                                    const SizedBox(height: 8),
                                    LinearProgressIndicator(
                                      value: _controller.progress,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
        );
      },
    );
  }

  Widget _buildItem(Object item) {
    if (item is IrTextElement) return _buildText(item);
    if (item is IrTable) return _buildTable(item);
    if (item is IrImage) return _buildImage(item);
    return const SizedBox.shrink();
  }

  Widget _buildText(IrTextElement e) {
    final translation =
        _mode == _WordMode.parallel ? e.translationFor(_controller.pair.to) : null;

    InlineSpan spanFor(IrSpan s) {
      final size = s.style.fontSize ?? 11;
      return TextSpan(
        text: s.text,
        style: TextStyle(
          fontSize: e.role == IrRole.heading
              ? (28 - 3 * e.headingLevel).clamp(15, 28).toDouble()
              : e.role == IrRole.caption
                  ? 11
                  : size,
          fontWeight: (s.style.bold || e.role == IrRole.heading)
              ? FontWeight.w700
              : FontWeight.normal,
          fontStyle:
              s.style.italic || e.role == IrRole.caption
                  ? FontStyle.italic
                  : FontStyle.normal,
          fontFamily: e.role == IrRole.code ? 'monospace' : null,
        ),
      );
    }

    final original = RichText(
      text: TextSpan(
        children: [
          for (final line in e.lines) ...[
            for (final s in line.spans) spanFor(s),
            const TextSpan(text: ' '),
          ],
        ],
      ),
    );

    return Padding(
      padding: EdgeInsets.symmetric(
        vertical: e.role == IrRole.heading ? 10 : 4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          original,
          if (translation != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                translation,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTable(IrTable t) {
    final rows = <TableRow>[
      for (var r = 0; r < t.rows; r++)
        TableRow(
          children: [
            for (var c = 0; c < t.columns; c++) _cellWidget(t, r, c),
          ],
        ),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Table(
        border: TableBorder.all(width: 0.5),
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        children: rows,
      ),
    );
  }

  Widget _cellWidget(IrTable t, int row, int column) {
    final cell = t.cells
        .where((c) => c.row == row && c.column == column)
        .cast<IrTableCell?>()
        .firstWhere((_) => true, orElse: () => null);
    final ir = _controller.ir;
    final buffer = StringBuffer();
    if (cell != null) {
      for (final id in cell.paragraphIds) {
        final e = ir?.byId(id);
        if (e == null) continue;
        buffer.writeln(
          (_mode == _WordMode.parallel
                  ? e.translationFor(_controller.pair.to)
                  : null) ??
              e.sourceText,
        );
      }
    }
    return Padding(
      padding: const EdgeInsets.all(6),
      child: Text(buffer.toString().trim(), style: const TextStyle(fontSize: 11)),
    );
  }

  Widget _buildImage(IrImage img) {
    final bytes = img.mediaName == null
        ? null
        : _controller.ir?.media[img.mediaName];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: bytes == null
          ? const Center(child: Icon(Icons.image_outlined, size: 40))
          : Center(child: Image.memory(bytes)),
    );
  }
}
