import 'package:flutter/material.dart';

import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/features/auth/presentation/widgets/auth_widgets.dart';
import 'package:repo_partage_plus/features/offers/presentation/widgets/offer_widgets.dart';

/// Nombre maximal de créneaux par offre (comme le serveur).
const maxPickupSlots = 6;

/// Créneau en cours de modification ; [id] null : nouveau créneau.
typedef EditableSlot = ({int? id, DateTime start, DateTime end});

/// Créneaux au format attendu par PATCH /offers/:id/slots.
List<Map<String, Object?>> slotsPayload(List<EditableSlot> slots) => [
  for (final slot in slots)
    {
      'id': ?slot.id,
      'start': slot.start.toUtc().toIso8601String(),
      'end': slot.end.toUtc().toIso8601String(),
    },
];

/// Date puis heure ; null si l'utilisateur annule. Une date passée est
/// proposée à partir d'aujourd'hui.
Future<DateTime?> pickSlotDateTime(
  BuildContext context,
  DateTime initial,
  String help,
) async {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final date = await showDatePicker(
    context: context,
    initialDate: initial.isBefore(today) ? today : initial,
    firstDate: today,
    lastDate: now.add(const Duration(days: 60)),
    helpText: help,
  );
  if (date == null || !context.mounted) return null;
  final time = await showTimePicker(
    context: context,
    initialTime: TimeOfDay.fromDateTime(initial),
    helpText: help,
  );
  if (time == null) return null;
  return DateTime(date.year, date.month, date.day, time.hour, time.minute);
}

/// Ouvre l'éditeur des créneaux de [offer] ; renvoie les créneaux à
/// enregistrer, ou null si l'utilisateur annule.
Future<List<EditableSlot>?> editPickupSlots(BuildContext context, Json offer) {
  return showModalBottomSheet<List<EditableSlot>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: AppColors.surface,
    builder: (context) => _SlotsEditor(offer: offer),
  );
}

/// Créneaux d'une offre déjà publiée, réservée ou non : déplacer, ajouter,
/// retirer. Un créneau réservé se déplace (les bénéficiaires sont prévenus)
/// mais ne se supprime pas : le serveur le refuse.
class _SlotsEditor extends StatefulWidget {
  const _SlotsEditor({required this.offer});

  final Json offer;

  @override
  State<_SlotsEditor> createState() => _SlotsEditorState();
}

class _SlotsEditorState extends State<_SlotsEditor> {
  late final List<EditableSlot> _slots = [
    for (final slot in offerSlots(widget.offer))
      (id: slot.id, start: slot.start, end: slot.end),
  ];

  Future<void> _edit(int index) async {
    final slot = _slots[index];
    final start = await pickSlotDateTime(
      context,
      slot.start,
      'Début du créneau',
    );
    if (start == null || !mounted) return;
    final end = await pickSlotDateTime(
      context,
      slot.end.isAfter(start) ? slot.end : start.add(const Duration(hours: 2)),
      'Fin du créneau',
    );
    if (end == null || !mounted) return;
    if (!end.isAfter(start)) {
      showMessage(context, 'La fin doit être après le début', error: true);
      return;
    }
    setState(() => _slots[index] = (id: slot.id, start: start, end: end));
  }

  Future<void> _add() async {
    final last = _slots.isEmpty
        ? DateTime.now()
        : _slots.map((s) => s.end).reduce((a, b) => a.isAfter(b) ? a : b);
    final start = await pickSlotDateTime(
      context,
      last.add(const Duration(hours: 1)),
      'Début du créneau',
    );
    if (start == null || !mounted) return;
    final end = await pickSlotDateTime(
      context,
      start.add(const Duration(hours: 2)),
      'Fin du créneau',
    );
    if (end == null || !mounted) return;
    if (!end.isAfter(start)) {
      showMessage(context, 'La fin doit être après le début', error: true);
      return;
    }
    setState(() => _slots.add((id: null, start: start, end: end)));
  }

  @override
  Widget build(BuildContext context) {
    final reserved =
        widget.offer['quantity_available'] != widget.offer['initial_quantity'];
    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        0,
        24,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Créneaux de « ${widget.offer['title']} »',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              reserved
                  ? 'Offre déjà réservée : les bénéficiaires d’un créneau '
                        'déplacé sont prévenus. Un créneau réservé ne peut pas '
                        'être supprimé.'
                  : 'Touchez un créneau pour le modifier.',
              style: const TextStyle(color: AppColors.textMuted),
            ),
            const SizedBox(height: 12),
            for (final (index, slot) in _slots.indexed)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: const Icon(Icons.schedule),
                  title: Text(formatPeriod(slot.start, slot.end)),
                  subtitle: slot.id == null ? const Text('Nouveau') : null,
                  onTap: () => _edit(index),
                  trailing: IconButton(
                    tooltip: 'Retirer ce créneau',
                    icon: const Icon(
                      Icons.delete_outline,
                      color: AppColors.danger,
                    ),
                    onPressed: _slots.length <= 1
                        ? null
                        : () => setState(() => _slots.removeAt(index)),
                  ),
                ),
              ),
            TextButton.icon(
              onPressed: _slots.length >= maxPickupSlots ? null : _add,
              icon: const Icon(Icons.add_circle_outline),
              label: const Text('Ajouter un créneau'),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(_slots),
              child: const Text('Enregistrer les créneaux'),
            ),
          ],
        ),
      ),
    );
  }
}
