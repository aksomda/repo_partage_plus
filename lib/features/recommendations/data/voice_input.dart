import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Dictée des préférences (reconnaissance vocale du système : Android, iOS,
/// navigateur Chrome/Edge, Windows). Remplaçable dans les tests.
abstract class VoiceInput {
  /// false si le micro est refusé ou la reconnaissance indisponible.
  Future<bool> start({required void Function(String text, bool done) onResult});
  Future<void> stop();
}

class SpeechVoiceInput implements VoiceInput {
  final _speech = SpeechToText();
  bool _ready = false;
  String? _locale;

  @override
  Future<bool> start({
    required void Function(String text, bool done) onResult,
  }) async {
    try {
      if (!_ready) {
        _ready = await _speech.initialize(
          onError: (error) => debugPrint('Dictée : ${error.errorMsg}'),
        );
        if (!_ready) return false;
        // Français si la langue est installée sur l'appareil.
        final locales = await _speech.locales();
        _locale = locales
            .where((locale) => locale.localeId.toLowerCase().startsWith('fr'))
            .firstOrNull
            ?.localeId;
      }
      await _speech.listen(
        onResult: (result) =>
            onResult(result.recognizedWords, result.finalResult),
        listenOptions: SpeechListenOptions(
          localeId: _locale,
          partialResults: true,
          listenMode: ListenMode.dictation,
          listenFor: const Duration(seconds: 30),
          pauseFor: const Duration(seconds: 4),
        ),
      );
      return true;
    } catch (error) {
      debugPrint('Dictée indisponible : $error');
      return false;
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _speech.stop();
    } catch (_) {}
  }
}

final voiceInputProvider = Provider<VoiceInput>((ref) => SpeechVoiceInput());
