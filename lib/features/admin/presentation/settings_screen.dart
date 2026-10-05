import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/core/widgets/app_menu.dart';
import 'package:repo_partage_plus/features/admin/data/admin_repository.dart';
import 'package:repo_partage_plus/features/auth/presentation/widgets/auth_widgets.dart';

/// Périodes proposées pour les quotas, en heures.
const quotaWindows = {
  1: 'Par heure',
  24: 'Par jour',
  168: 'Par semaine',
  720: 'Par 30 jours',
};

/// Paramètres de la plateforme : nombre de publications et de réservations
/// autorisées sans compte (anti-abus), par téléphone et par adresse IP.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _form = GlobalKey<FormState>();
  final _quotas = {
    'guest_offer': _QuotaState(defaultMax: 10),
    'guest_reservation': _QuotaState(defaultMax: 20),
  };
  var _loaded = false;
  var _saving = false;

  @override
  void dispose() {
    for (final quota in _quotas.values) {
      quota.max.dispose();
    }
    super.dispose();
  }

  /// Remplit le formulaire une fois les paramètres synchronisés.
  void _load(Map<String, dynamic> settings) {
    if (_loaded || settings.isEmpty) return;
    _loaded = true;
    for (final MapEntry(:key, value: quota) in _quotas.entries) {
      quota.load(
        max: settings['${key}_max'] as int?,
        windowHours: settings['${key}_window_hours'] as int?,
      );
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    final result = await ref.read(adminRepositoryProvider).saveSettings({
      for (final MapEntry(:key, value: quota) in _quotas.entries) ...{
        '${key}_max': quota.enabled ? int.parse(quota.max.text.trim()) : 0,
        '${key}_window_hours': quota.windowHours,
      },
    });
    if (!mounted) return;
    setState(() => _saving = false);
    switch (result) {
      case Sent():
        showMessage(context, 'Paramètres enregistrés');
      case Queued():
        showMessage(
          context,
          'Hors ligne : les paramètres seront envoyés plus tard',
        );
      case Rejected(:final message):
        showMessage(context, message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(adminSettingsProvider);
    _load(settings);
    final syncing = ref.watch(syncControllerProvider).syncing;

    return Scaffold(
      appBar: AppBar(title: const Text('Paramètres')),
      drawer: AppMenu(
        currentLocation: GoRouterState.of(context).uri.toString(),
      ),
      body: RefreshIndicator(
        onRefresh: ref.read(syncControllerProvider.notifier).syncNow,
        child: !_loaded
            ? ListView(
                padding: const EdgeInsets.all(32),
                children: [
                  Center(
                    child: syncing
                        ? const CircularProgressIndicator()
                        : const Text(
                            'Paramètres non synchronisés : tirez vers le bas '
                            'pour actualiser.',
                            textAlign: TextAlign.center,
                          ),
                  ),
                ],
              )
            : Form(
                key: _form,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                  children: [
                    const Text(
                      'Usagers sans compte : limitez le nombre d’actions pour '
                      'freiner les abus. Le quota est compté par numéro de '
                      'téléphone et par adresse IP ; les comptes ne sont pas limités.',
                      style: TextStyle(color: AppColors.textMuted),
                    ),
                    const SizedBox(height: 16),
                    _QuotaCard(
                      title: 'Publications sans compte',
                      icon: Icons.add_business_outlined,
                      noun: 'publications',
                      quota: _quotas['guest_offer']!,
                      onChanged: () => setState(() {}),
                    ),
                    const SizedBox(height: 12),
                    _QuotaCard(
                      title: 'Réservations sans compte',
                      icon: Icons.shopping_bag_outlined,
                      noun: 'réservations',
                      quota: _quotas['guest_reservation']!,
                      onChanged: () => setState(() {}),
                    ),
                    const SizedBox(height: 24),
                    LoadingButton(
                      label: 'Enregistrer',
                      loading: _saving,
                      onPressed: _save,
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

/// Valeurs modifiables d'un quota.
class _QuotaState {
  _QuotaState({required this.defaultMax}) : max = TextEditingController();

  final int defaultMax;
  final TextEditingController max;
  var enabled = true;
  var windowHours = 1;

  void load({int? max, int? windowHours}) {
    final value = max ?? defaultMax;
    enabled = value > 0;
    // Désactivé : on propose la valeur par défaut si on le réactive.
    this.max.text = '${enabled ? value : defaultMax}';
    this.windowHours = windowHours ?? 1;
  }
}

class _QuotaCard extends StatelessWidget {
  const _QuotaCard({
    required this.title,
    required this.icon,
    required this.noun,
    required this.quota,
    required this.onChanged,
  });

  final String title;
  final IconData icon;
  final String noun;
  final _QuotaState quota;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    // Valeur réglée hors de la liste (API) : affichée telle quelle.
    final windows = {
      ...quotaWindows,
      if (!quotaWindows.containsKey(quota.windowHours))
        quota.windowHours: 'Par ${quota.windowHours} heures',
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: Icon(icon, color: AppColors.primary),
              title: Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                quota.enabled
                    ? 'Autorisées, avec une limite'
                    : 'Interdites : compte obligatoire',
              ),
              value: quota.enabled,
              onChanged: (value) {
                quota.enabled = value;
                onChanged();
              },
            ),
            if (quota.enabled) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 0,
                crossAxisAlignment: WrapCrossAlignment.end,
                children: [
                  SizedBox(
                    width: 200,
                    child: LabeledField(
                      label: 'Nombre maximal',
                      required: true,
                      child: TextFormField(
                        controller: quota.max,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        decoration: InputDecoration(suffixText: noun),
                        validator: (value) {
                          final number = int.tryParse(value?.trim() ?? '');
                          if (number == null || number < 1 || number > 1000) {
                            return 'Entre 1 et 1000';
                          }
                          return null;
                        },
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 240,
                    child: LabeledField(
                      label: 'Période',
                      required: true,
                      child: DropdownButtonFormField<int>(
                        isExpanded: true,
                        initialValue: quota.windowHours,
                        items: [
                          for (final MapEntry(:key, :value) in windows.entries)
                            DropdownMenuItem(value: key, child: Text(value)),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          quota.windowHours = value;
                          onChanged();
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
