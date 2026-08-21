import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/app_services.dart';
import '../../core/services/assistant/llama_chat_service.dart';
import '../../core/services/monetization/limits_service.dart';
import '../../core/services/model_paths.dart';
import '../monetization/limit_dialog.dart';
import '../reader/reader_controller.dart';

class _ChatMessage {
  const _ChatMessage({required this.fromUser, required this.text});
  final bool fromUser;
  final String text;
}

/// Chat local 100 % hors-ligne sur le document ouvert : résumé, grandes
/// lignes, questions-réponses. Propulsé par llama.cpp (Qwen2.5-0.5B
/// quantisé) quand le module natif est compilé (engine/README.md).
class AssistantScreen extends StatefulWidget {
  const AssistantScreen({super.key, required this.controller});

  final ReaderController controller;

  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen> {
  final LlamaChatService _llama = LlamaChatService();
  final List<_ChatMessage> _messages = [];
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  bool _checked = false;
  bool _nativeAvailable = false;
  bool _modelPresent = false;
  bool _downloading = false;
  double _downloadProgress = 0;
  int _bytesDone = 0;
  int? _bytesTotal;
  bool _busy = false;
  String? _docText;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final available = await _llama.isAvailable();
    final present = await ModelPaths.llmModelExists();
    if (!mounted) return;
    setState(() {
      _nativeAvailable = available;
      _modelPresent = present;
      _checked = true;
    });
  }

  Future<void> _download() async {
    setState(() {
      _downloading = true;
      _downloadProgress = 0;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      await LlamaChatService.downloadModel((p, done, total) {
        if (!mounted) return;
        setState(() {
          _downloadProgress = p;
          _bytesDone = done;
          _bytesTotal = total;
        });
      });
      await _check();
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Modèle LLM installé.')),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Téléchargement impossible : $e')),
      );
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  Future<void> _importGguf() async {
    final messenger = ScaffoldMessenger.of(context);
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['gguf', 'bin'],
    );
    if (picked == null) return;
    try {
      final target = File(await ModelPaths.llmModelPath());
      await target.parent.create(recursive: true);
      await File(picked.path).copy(target.path);
      await _check();
      messenger.showSnackBar(
        const SnackBar(content: Text('Modèle GGUF importé.')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Import impossible : $e')),
      );
    }
  }

  /// Lit tout le document (extraction des blocs) et construit le texte
  /// fourni au modèle (tronqué à ~24 000 caractères, début du document).
  Future<void> _ensureDocText() async {
    if (_docText != null) return;
    final buffer = StringBuffer();
    for (var page = 1; page <= widget.controller.pageCount; page++) {
      await widget.controller.ensureBlocks(page);
      for (final block in widget.controller.blocksForPage(page)) {
        buffer.writeln(block.text);
        if (buffer.length > 24000) break;
      }
      if (buffer.length > 24000) break;
    }
    _docText = buffer.toString();
  }

  Future<void> _send(String userText) async {
    if (userText.trim().isEmpty || _busy) return;

    // Quota gratuit de questions (Pro = illimité) : dialogue pub/Pro.
    if (!AppServices.instance.entitlements.isPro) {
      try {
        AppServices.instance.limits.tryConsumeQuestion();
      } on QuotaExceededException {
        final unlocked = await LimitDialog.show(context, 'questions');
        if (!unlocked) return;
      }
    }

    _input.clear();
    setState(() {
      _messages.add(_ChatMessage(fromUser: true, text: userText));
      _busy = true;
    });
    _scrollToBottom();

    try {
      await _ensureDocText();
      await _llama.initialize();
      final system = "Tu es l'assistant de lecture Youssira, 100 % hors-ligne. "
          'Réponds en français, de façon concise et fidèle au document. '
          'Voici un extrait du document :\n<<<\n$_docText\n>>>';
      final answer = await _llama.chat(system: system, user: userText);
      if (!mounted) return;
      setState(() => _messages.add(_ChatMessage(fromUser: false, text: answer)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _messages.add(_ChatMessage(
            fromUser: false,
            text: 'Erreur : $e',
          )));
    } finally {
      if (mounted) setState(() => _busy = false);
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  String _mo(int bytes) => '${(bytes / 1048576).toStringAsFixed(0)} Mo';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Assistant du document')),
      body: !_checked
          ? const Center(child: CircularProgressIndicator())
          : !_nativeAvailable
              ? _unavailableCard()
              : !_modelPresent
                  ? _modelCard()
                  : _chat(),
    );
  }

  Widget _unavailableCard() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.smart_toy_outlined, size: 40),
                SizedBox(height: 12),
                Text(
                  'Assistant local indisponible',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                SizedBox(height: 8),
                Text(
                  "Le module natif llama.cpp n'est pas compilé dans ce "
                  'build. Voir engine/README.md (section « Chat local »).',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _modelCard() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.download_for_offline_outlined, size: 40),
                const SizedBox(height: 12),
                const Text(
                  'Modèle de langue local',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Qwen2.5-0.5B-Instruct quantisé (~470 Mo), téléchargé une '
                  'seule fois, 100 % hors-ligne ensuite.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                if (_downloading) ...[
                  LinearProgressIndicator(value: _downloadProgress),
                  const SizedBox(height: 8),
                  Text(
                    _bytesTotal == null
                        ? '${_mo(_bytesDone)}…'
                        : '${_mo(_bytesDone)} / ${_mo(_bytesTotal!)} '
                            '(${(_downloadProgress * 100).toStringAsFixed(0)} %)',
                  ),
                ] else ...[
                  FilledButton.icon(
                    onPressed: _download,
                    icon: const Icon(Icons.download),
                    label: const Text('Télécharger le modèle'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _importGguf,
                    icon: const Icon(Icons.folder_open),
                    label: const Text('Importer un GGUF'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _chat() {
    return Column(
      children: [
        Expanded(
          child: _messages.isEmpty
              ? const Center(
                  child: Text(
                    'Posez une question sur ce document,\n'
                    'ou utilisez un raccourci ci-dessous.',
                    textAlign: TextAlign.center,
                  ),
                )
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(12),
                  itemCount: _messages.length,
                  itemBuilder: (context, i) {
                    final m = _messages[i];
                    return Align(
                      alignment: m.fromUser
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        padding: const EdgeInsets.all(12),
                        constraints: BoxConstraints(
                          maxWidth:
                              MediaQuery.of(context).size.width * 0.85,
                        ),
                        decoration: BoxDecoration(
                          color: m.fromUser
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          m.text,
                          style: TextStyle(
                            color: m.fromUser
                                ? Theme.of(context).colorScheme.onPrimary
                                : null,
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.all(8),
            child: LinearProgressIndicator(),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Wrap(
            spacing: 8,
            children: [
              for (final entry in const {
                'Résumé': 'Fais un résumé complet du document.',
                'Grandes lignes': 'Donne les grandes lignes du document.',
                'Points clés': 'Quels sont les points clés à retenir ?',
              }.entries)
                ActionChip(
                  label: Text(entry.key),
                  onPressed: _busy ? null : () => _send(entry.value),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: 'Question sur le document…',
                  ),
                  onSubmitted: _busy ? null : (t) => _send(t),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                tooltip: 'Envoyer',
                icon: const Icon(Icons.send),
                onPressed: _busy ? null : () => _send(_input.text),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
