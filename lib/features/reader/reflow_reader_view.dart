import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:provider/provider.dart';

import '../../core/models/text_block.dart';
import '../../core/services/monetization/limits_service.dart';
import 'reader_controller.dart';

/// Mode lecture : le document est retypographié comme un ebook — confort
/// maximal, aucune contrainte de la mise en page fixe du PDF.
///
/// Chaque page devient une section ; les blocs traduits s'affichent en
/// typographie propre, les blocs non traduits (code, en attente) en original.
class ReflowReaderView extends StatelessWidget {
  const ReflowReaderView({super.key, required this.document});

  final PdfDocument document;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 48),
      itemCount: document.pages.length,
      itemBuilder: (context, index) =>
          _ReflowPage(pageNumber: index + 1),
    );
  }
}

class _ReflowPage extends StatefulWidget {
  const _ReflowPage({required this.pageNumber});

  final int pageNumber;

  @override
  State<_ReflowPage> createState() => _ReflowPageState();
}

class _ReflowPageState extends State<_ReflowPage> {
  String? _error;

  @override
  void initState() {
    super.initState();
    // Traduction automatique de la page quand elle apparaît.
    Future.microtask(() async {
      if (!mounted) return;
      final controller = context.read<ReaderController>();
      await controller.ensureBlocks(widget.pageNumber);
      try {
        await controller.translatePage(widget.pageNumber);
      } on QuotaExceededException {
        // Quota gratuit atteint : arrêt silencieux en mode lecture
        // (l'utilisateur repassera par le mode superposé pour débloquer).
      } catch (e) {
        if (mounted) setState(() => _error = '$e');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ReaderController>();
    final blocks = controller.blocksForPage(widget.pageNumber);
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(
          child: Text(
            '— page ${widget.pageNumber} —',
            style: theme.textTheme.bodySmall,
          ),
        ),
        const SizedBox(height: 12),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'Traduction indisponible : $_error',
              style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
            ),
          ),
        for (final block in blocks) _paragraph(controller, block),
        const SizedBox(height: 32),
        const Divider(),
      ],
    );
  }

  Widget _paragraph(ReaderController controller, TextBlock block) {
    final progress = controller.progressFor(block.id);

    // Code laissé intact : affichage monospace.
    if (progress?.state == BlockState.skipped) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(
          block.text,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 13,
            height: 1.5,
          ),
        ),
      );
    }

    final translated =
        progress?.state == BlockState.done ? progress!.translatedText : null;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: translated != null
          ? Text(
              translated,
              style: TextStyle(
                fontSize: block.bold ? 20 : 16,
                fontWeight: block.bold ? FontWeight.w700 : FontWeight.normal,
                height: 1.6,
              ),
            )
          : Text(
              block.text,
              style: TextStyle(
                fontSize: 14,
                height: 1.5,
                fontStyle: FontStyle.italic,
                color: Colors.grey.shade600,
              ),
            ),
    );
  }
}
