import 'package:flutter/material.dart';

import '../../core/app_services.dart';
import '../../core/services/monetization/entitlements_service.dart';

/// Paywall : version Pro (abonnement mensuel ou achat à vie).
/// Pro = aucune publicité + limites gratuites levées.
class ProScreen extends StatefulWidget {
  const ProScreen({super.key});

  @override
  State<ProScreen> createState() => _ProScreenState();
}

class _ProScreenState extends State<ProScreen> {
  EntitlementsService get _entitlements => AppServices.instance.entitlements;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _entitlements.addListener(_onChange);
  }

  @override
  void dispose() {
    _entitlements.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  Future<void> _buy(String id) async {
    setState(() => _busy = true);
    try {
      await _entitlements.buy(id);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Achat impossible : $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pro = _entitlements.isPro;
    return Scaffold(
      appBar: AppBar(title: const Text('Version Pro')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Icon(
                    Icons.workspace_premium,
                    size: 48,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Youssira Pro',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '• Aucune publicité\n'
                    '• Pages traduites illimitées\n'
                    '• Exports PDF illimités\n'
                    '• Assistant illimité',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (pro)
            const Card(
              child: ListTile(
                leading: Icon(Icons.check_circle, color: Colors.green),
                title: Text('Pro actif'),
                subtitle: Text('Merci pour votre soutien !'),
              ),
            )
          else if (!_entitlements.storeAvailable)
            const Card(
              child: ListTile(
                leading: Icon(Icons.store_outlined),
                title: Text('Boutique indisponible'),
                subtitle: Text(
                  "Google Play n'est pas joignable sur cet appareil "
                  '(émulateur ou hors-ligne).',
                ),
              ),
            )
          else ...[
            _productTile(EntitlementsService.monthlyId, 'Abonnement mensuel'),
            const SizedBox(height: 8),
            _productTile(EntitlementsService.lifetimeId, 'Achat à vie'),
            const SizedBox(height: 16),
            Center(
              child: TextButton(
                onPressed: _busy ? null : _entitlements.restore,
                child: const Text('Restaurer mes achats'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _productTile(String id, String fallbackTitle) {
    final product = _entitlements.product(id);
    return Card(
      child: ListTile(
        title: Text(product?.title ?? fallbackTitle),
        subtitle: Text(product?.description ?? ''),
        trailing: _busy
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : FilledButton(
                onPressed: () => _buy(id),
                child: Text(product?.price ?? '—'),
              ),
      ),
    );
  }
}
