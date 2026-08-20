import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';

import 'app.dart';
import 'core/app_services.dart';
import 'core/services/cache/translation_cache.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // v1 : portrait uniquement pour garder un mapping de coordonnées d'overlay
  // simple (le PDF gère sa propre rotation). À lever plus tard.
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

  // Initialise le moteur PDFium de pdfrx avant tout usage des APIs document.
  await pdfrxFlutterInitialize();

  // Pré-chauffe le cache de traductions et les services globaux.
  await TranslationCache.init();
  await AppServices.instance.init();

  runApp(const YoussiraApp());
}
