import 'package:shared_preferences/shared_preferences.dart';

import 'monetization_config.dart';

/// Levée quand une limite gratuite journalière est atteinte.
class QuotaExceededException implements Exception {
  const QuotaExceededException(this.kind);

  /// 'pages' | 'exports' | 'questions'
  final String kind;

  @override
  String toString() => 'Limite gratuite atteinte ($kind)';
}

/// Compteurs gratuits journaliers (pages traduites, exports, questions de
/// l'assistant). La version Pro contourne toutes les limites ; les pubs
/// récompensées ajoutent du crédit.
class LimitsService {
  static const _kDay = 'limits_day';
  static const _kPages = 'limits_pages_left';
  static const _kExports = 'limits_exports_left';
  static const _kQuestions = 'limits_questions_left';

  int pagesLeft = MonetizationConfig.freePagesPerDay;
  int exportsLeft = MonetizationConfig.freeExportsPerDay;
  int questionsLeft = MonetizationConfig.freeQuestionsPerDay;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final today = DateTime.now().toIso8601String().substring(0, 10);
    if (prefs.getString(_kDay) != today) {
      pagesLeft = MonetizationConfig.freePagesPerDay;
      exportsLeft = MonetizationConfig.freeExportsPerDay;
      questionsLeft = MonetizationConfig.freeQuestionsPerDay;
      await _persist(prefs, today);
    } else {
      pagesLeft = prefs.getInt(_kPages) ?? MonetizationConfig.freePagesPerDay;
      exportsLeft =
          prefs.getInt(_kExports) ?? MonetizationConfig.freeExportsPerDay;
      questionsLeft =
          prefs.getInt(_kQuestions) ?? MonetizationConfig.freeQuestionsPerDay;
    }
  }

  Future<void> _persist(SharedPreferences prefs, String day) async {
    await prefs.setString(_kDay, day);
    await prefs.setInt(_kPages, pagesLeft);
    await prefs.setInt(_kExports, exportsLeft);
    await prefs.setInt(_kQuestions, questionsLeft);
  }

  Future<void> _save() async {
    await _persist(
      await SharedPreferences.getInstance(),
      DateTime.now().toIso8601String().substring(0, 10),
    );
  }

  /// Consomme une page traduite. Lève [QuotaExceededException] à 0.
  /// (La vérification Pro est faite par l'appelant via EntitlementsService.)
  bool tryConsumePage() {
    if (MonetizationConfig.devMode) return true; // illimité en dev
    if (pagesLeft <= 0) throw const QuotaExceededException('pages');
    pagesLeft--;
    _save();
    return true;
  }

  bool tryConsumeExport() {
    if (MonetizationConfig.devMode) return true; // illimité en dev
    if (exportsLeft <= 0) throw const QuotaExceededException('exports');
    exportsLeft--;
    _save();
    return true;
  }

  bool tryConsumeQuestion() {
    if (MonetizationConfig.devMode) return true; // illimité en dev
    if (questionsLeft <= 0) throw const QuotaExceededException('questions');
    questionsLeft--;
    _save();
    return true;
  }

  /// Consomme un nombre de pages équivalent à [chars] caractères
  /// (~1 800 caractères ≈ 1 page A4) — utilisé par les documents Word.
  void consumeCharPages(int chars) {
    if (MonetizationConfig.devMode) return; // illimité en dev
    final pages = chars <= 0 ? 1 : (chars / 1800).ceil();
    if (pagesLeft < pages) throw const QuotaExceededException('pages');
    pagesLeft -= pages;
    _save();
  }

  /// Crédits ajoutés par une pub récompensée.
  Future<void> addReward(String kind) async {
    switch (kind) {
      case 'pages':
        pagesLeft += MonetizationConfig.rewardPages;
      case 'exports':
        exportsLeft += MonetizationConfig.rewardExports;
      case 'questions':
        questionsLeft += MonetizationConfig.rewardQuestions;
    }
    await _save();
  }
}
