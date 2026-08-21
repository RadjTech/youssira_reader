import 'package:flutter/material.dart';

import '../../core/app_services.dart';
import '../settings/pro_screen.dart';

enum _LimitAction { reward, pro, cancel }

/// Dialogue « limite gratuite atteinte » : pub récompensée (déblocage)
/// ou passage Pro. Retourne true si l'utilisateur a débloqué du crédit.
class LimitDialog {
  static const _labels = {
    'pages': ('pages traduites', 'pages'),
    'exports': ('exports de PDF traduit', 'exports'),
    'questions': ('questions à l\'assistant', 'questions'),
  };

  static Future<bool> show(BuildContext context, String kind) async {
    final label = _labels[kind] ?? ('cette action', kind);
    final action = await showDialog<_LimitAction>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Limite gratuite atteinte'),
        content: Text(
          'Vous avez utilisé votre quota gratuit du jour pour '
          '${label.$1}.\n\n'
          'Regardez une courte pub pour continuer, ou passez en version '
          'Pro (sans pub, illimité).',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(_LimitAction.cancel),
            child: const Text('Plus tard'),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.workspace_premium_outlined),
            label: const Text('Passer Pro'),
            onPressed: () => Navigator.of(context).pop(_LimitAction.pro),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.play_circle_outline),
            label: const Text('Voir une pub'),
            onPressed: () => Navigator.of(context).pop(_LimitAction.reward),
          ),
        ],
      ),
    );

    if (!context.mounted) return false;
    if (action == _LimitAction.pro) {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ProScreen()),
      );
      return AppServices.instance.entitlements.isPro;
    }
    if (action == _LimitAction.reward) {
      final earned = await AppServices.instance.ads.showRewarded();
      if (earned) {
        await AppServices.instance.limits.addReward(label.$2);
        return true;
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Aucune pub disponible pour le moment '
                '(connexion requise).'),
          ),
        );
      }
    }
    return false;
  }
}
