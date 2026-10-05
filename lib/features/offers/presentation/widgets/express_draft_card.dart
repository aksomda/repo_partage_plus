import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/features/auth/presentation/widgets/auth_widgets.dart';
import 'package:repo_partage_plus/features/offers/data/offer_draft.dart';
import 'package:repo_partage_plus/features/recommendations/data/voice_input.dart';

/// « Publication express » (restaurateurs) : le restaurateur décrit ses
/// invendus en une phrase, l'IA pré-remplit le formulaire, qu'il relit.
class ExpressDraftCard extends ConsumerStatefulWidget {
  const ExpressDraftCard({super.key, required this.onDraft});

  final void Function(Json draft) onDraft;

  @override
  ConsumerState<ExpressDraftCard> createState() => _ExpressDraftCardState();
}

class _ExpressDraftCardState extends ConsumerState<ExpressDraftCard> {
  final _text = TextEditingController();
  var _loading = false;
  var _listening = false;
  late final VoiceInput _voice;

  @override
  void initState() {
    super.initState();
    _voice = ref.read(voiceInputProvider);
  }

  @override
  void dispose() {
    if (_listening) _voice.stop();
    _text.dispose();
    super.dispose();
  }

  Future<void> _fill() async {
    final text = _text.text.trim();
    if (text.length < 5) {
      showMessage(context, 'Décrivez votre offre en quelques mots', error: true);
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _loading = true);
    try {
      final draft = await ref.read(offerDraftRepositoryProvider).draft(text);
      if (!mounted) return;
      widget.onDraft(draft);
      showMessage(context, 'Formulaire pré-rempli : vérifiez avant de publier');
    } catch (error) {
      if (mounted) {
        showMessage(
          context,
          '$error : remplissez le formulaire ci-dessous',
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggleVoice() async {
    if (_listening) {
      await _voice.stop();
      setState(() => _listening = false);
      return;
    }
    final started = await _voice.start(
      onResult: (text, done) {
        if (!mounted) return;
        _text.text = text;
        if (done) {
          setState(() => _listening = false);
          _fill();
        }
      },
    );
    if (!mounted) return;
    if (started) {
      setState(() => _listening = true);
    } else {
      showMessage(
        context,
        'Dictée indisponible : autorisez le micro ou saisissez le texte',
        error: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      color: AppColors.primarySoft,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Row(
              children: [
                Icon(Icons.auto_awesome, color: AppColors.primary, size: 20),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Publication express',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'Décrivez vos invendus en une phrase : le formulaire est '
              'rempli pour vous, il ne reste qu’à vérifier.',
              style: TextStyle(color: AppColors.textMuted, fontSize: 13),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _text,
              minLines: 1,
              maxLines: 3,
              maxLength: 600,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText:
                    'Ex. : 5 plats de riz gras de midi, gratuit, '
                    'à récupérer avant 20h',
                counterText: '',
                suffixIcon: IconButton(
                  tooltip: _listening ? 'Arrêter la dictée' : 'Dicter',
                  icon: Icon(
                    _listening ? Icons.stop_circle_outlined : Icons.mic_none,
                    color: _listening ? AppColors.danger : null,
                  ),
                  onPressed: _loading ? null : _toggleVoice,
                ),
              ),
              onSubmitted: (_) => _fill(),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: _loading ? null : _fill,
                icon: _loading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome),
                label: const Text('Remplir avec l’IA'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
