import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'translation_cache.g.dart';

/// Table des traductions mises en cache.
@DataClassName('TranslationEntry')
class Translations extends Table {
  /// sha256(texte normalisé | langue source | langue cible | moteur).
  TextColumn get cacheKey => text()();
  TextColumn get sourceText => text()();
  TextColumn get translatedText => text()();
  TextColumn get fromLang => text()();
  TextColumn get toLang => text()();
  TextColumn get engine => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {cacheKey};
}

@DriftDatabase(tables: [Translations])
class TranslationCacheDb extends _$TranslationCacheDb {
  TranslationCacheDb(super.executor);

  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (migrator, from, to) async {
          if (from < 2) {
            // v2 : nouvelles règles de « traduction intelligente » (code
            // laissé intact, points de conduite protégés, couleurs
            // dominantes). Les entrées antérieures sont obsolètes.
            await delete(translations).go();
          }
          if (from < 3) {
            // v3 : purge des entrées contaminées pendant la mise au point
            // (traductions stockées égales au texte source, en anglais).
            await delete(translations).go();
          }
        },
      );
}

/// Singleton d'accès au cache des traductions.
///
/// Le cache est LA grosse optimisation de l'app : les documents répétés
/// (cours, notices, rapports) réutilisent massivement les mêmes phrases.
class TranslationCache {
  TranslationCache._(this._db);

  static TranslationCache? _instance;
  final TranslationCacheDb _db;

  /// À appeler une fois au démarrage (main.dart).
  static Future<TranslationCache> init() async {
    final existing = _instance;
    if (existing != null) return existing;

    final db = TranslationCacheDb(
      LazyDatabase(() async {
        final dir = await getApplicationSupportDirectory();
        final file = File(p.join(dir.path, 'translation_cache.sqlite'));
        return NativeDatabase.createInBackground(file);
      }),
    );
    _instance = TranslationCache._(db);
    return _instance!;
  }

  static TranslationCache get instance {
    final existing = _instance;
    if (existing == null) {
      throw StateError('TranslationCache.init() doit être appelé avant usage.');
    }
    return existing;
  }

  /// Clé de cache stable pour un texte / paire de langues / moteur donnés.
  static String keyFor({
    required String text,
    required String fromBcp,
    required String toBcp,
    required String engineId,
  }) {
    final normalized = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    return sha256
        .convert(utf8.encode('$normalized|$fromBcp|$toBcp|$engineId'))
        .toString();
  }

  Future<String?> get(String key) async {
    final query = _db.select(_db.translations)
      ..where((t) => t.cacheKey.equals(key));
    final row = await query.getSingleOrNull();
    return row?.translatedText;
  }

  Future<void> put({
    required String key,
    required String sourceText,
    required String translatedText,
    required String fromBcp,
    required String toBcp,
    required String engineId,
  }) async {
    await _db.into(_db.translations).insertOnConflictUpdate(
          TranslationsCompanion.insert(
            cacheKey: key,
            sourceText: sourceText,
            translatedText: translatedText,
            fromLang: fromBcp,
            toLang: toBcp,
            engine: engineId,
          ),
        );
  }

  Future<int> count() async {
    final row = await _db
        .customSelect('SELECT COUNT(*) AS c FROM translations')
        .getSingle();
    return row.read<int>('c');
  }

  Future<void> clear() => _db.delete(_db.translations).go();

  Future<void> close() => _db.close();
}
