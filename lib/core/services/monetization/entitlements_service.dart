import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'monetization_config.dart';

/// Version Pro (achat intégré Google Play) : aucune pub, limites levées.
/// Deux produits : abonnement mensuel et achat à vie.
///
/// À créer dans Play Console (README §Monétisation) :
/// - abonnement : `youssira_pro_monthly` ;
/// - produit unique (non consommable) : `youssira_pro_lifetime`.
class EntitlementsService extends ChangeNotifier {
  static const monthlyId = 'youssira_pro_monthly';
  static const lifetimeId = 'youssira_pro_lifetime';
  static const _kPro = 'entitlement_pro';

  bool _pro = false;
  bool _storeAvailable = false;
  List<ProductDetails> _products = [];
  StreamSubscription<List<PurchaseDetails>>? _sub;

  bool get isPro => MonetizationConfig.devMode ? true : _pro;
  bool get storeAvailable => _storeAvailable;
  List<ProductDetails> get products => _products;

  ProductDetails? product(String id) {
    for (final p in _products) {
      if (p.id == id) return p;
    }
    return null;
  }

  Future<void> init() async {
    if (MonetizationConfig.devMode) return; // pas de Play Billing en dev
    final prefs = await SharedPreferences.getInstance();
    _pro = prefs.getBool(_kPro) ?? false;

    if (!await InAppPurchase.instance.isAvailable()) return;
    _storeAvailable = true;

    _sub = InAppPurchase.instance.purchaseStream.listen((details) {
      for (final d in details) {
        _handlePurchase(d);
      }
    });

    await _loadProducts();
    await _restore();
    notifyListeners();
  }

  Future<void> _loadProducts() async {
    final response = await InAppPurchase.instance
        .queryProductDetails({monthlyId, lifetimeId});
    _products = response.productDetails;
  }

  /// Restaure les achats : les achats possédés remontent via
  /// [purchaseStream] (gérés par [_handlePurchase]).
  Future<void> _restore() async {
    try {
      await InAppPurchase.instance.restorePurchases();
    } catch (_) {
      // Jamais bloquant.
    }
  }

  void _handlePurchase(PurchaseDetails details) {
    if (details.status == PurchaseStatus.purchased ||
        details.status == PurchaseStatus.restored) {
      if (details.productID == lifetimeId || details.productID == monthlyId) {
        _pro = true;
        SharedPreferences.getInstance().then((prefs) async {
          await prefs.setBool(_kPro, true);
          notifyListeners();
        });
      }
    }
    if (details.pendingCompletePurchase) {
      InAppPurchase.instance.completePurchase(details);
    }
  }

  /// Lance l'achat (abonnement ou à vie) via Google Play.
  Future<void> buy(String productId) async {
    final p = product(productId);
    if (p == null) {
      throw StateError('Produit $productId indisponible dans le store.');
    }
    await InAppPurchase.instance
        .buyNonConsumable(purchaseParam: PurchaseParam(productDetails: p));
  }

  Future<void> restore() async {
    await InAppPurchase.instance.restorePurchases();
    await _restore();
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
