import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// Enregistrement audio d'une demande, envoyé tel quel à l'agent IA.
typedef RecordedAudio = ({Uint8List bytes, String mime});

/// Enregistre la voix de l'utilisateur (micro). Remplaçable dans les tests.
abstract class VoiceRecorder {
  /// false si le micro est refusé ou l'enregistrement indisponible.
  Future<bool> start();

  /// Fin de l'enregistrement ; null si rien n'a été enregistré.
  Future<RecordedAudio?> stop();

  /// Abandon : l'enregistrement est jeté.
  Future<void> cancel();
}

/// Format d'enregistrement : encodeur, extension du fichier, type MIME.
typedef _Format = (AudioEncoder, String, String);

/// Formats acceptés par Whisper et Gemini, par ordre de préférence :
/// AAC (Android, iOS, macOS, Windows, Linux), Opus/WebM (navigateurs),
/// WAV en dernier recours (plus lourd).
const _nativeFormats = <_Format>[
  (AudioEncoder.aacLc, 'm4a', 'audio/mp4'),
  (AudioEncoder.wav, 'wav', 'audio/wav'),
];
const _webFormats = <_Format>[
  (AudioEncoder.opus, 'webm', 'audio/webm'),
  (AudioEncoder.aacLc, 'm4a', 'audio/mp4'),
  (AudioEncoder.wav, 'wav', 'audio/wav'),
];

/// Micro de l'appareil, sur toutes les plateformes (Linux : `parecord` et
/// `ffmpeg` doivent être installés). Mono 16 kHz : léger, suffisant pour
/// la voix.
class DeviceVoiceRecorder implements VoiceRecorder {
  AudioRecorder? _recorder;
  String? _path;
  _Format? _format;

  Future<_Format?> _pickFormat(AudioRecorder recorder) async {
    for (final format in kIsWeb ? _webFormats : _nativeFormats) {
      if (await recorder.isEncoderSupported(format.$1)) return format;
    }
    return null;
  }

  @override
  Future<bool> start() async {
    try {
      final recorder = _recorder ??= AudioRecorder();
      if (!await recorder.hasPermission()) return false;
      final format = _format = await _pickFormat(recorder);
      if (format == null) return false;
      // Navigateur : enregistrement en mémoire (URL blob), pas de fichier.
      if (kIsWeb) {
        _path = '';
      } else {
        final dir = await getTemporaryDirectory();
        _path =
            '${dir.path}/demande_${DateTime.now().millisecondsSinceEpoch}.${format.$2}';
      }
      await recorder.start(
        RecordConfig(
          encoder: format.$1,
          sampleRate: 16000,
          numChannels: 1,
          bitRate: 32000,
        ),
        path: _path!,
      );
      return true;
    } catch (error) {
      debugPrint('Enregistrement impossible : $error');
      return false;
    }
  }

  @override
  Future<RecordedAudio?> stop() async {
    final format = _format;
    try {
      final path = await _recorder?.stop();
      if (path == null || format == null) return null;
      final Uint8List bytes;
      if (kIsWeb) {
        // URL blob du navigateur, lue en mémoire.
        final response = await Dio().get<List<int>>(
          path,
          options: Options(responseType: ResponseType.bytes),
        );
        bytes = Uint8List.fromList(response.data ?? const []);
      } else {
        final file = File(path);
        if (!file.existsSync()) return null;
        bytes = await file.readAsBytes();
        await file.delete();
      }
      return bytes.isEmpty ? null : (bytes: bytes, mime: format.$3);
    } catch (error) {
      debugPrint('Enregistrement illisible : $error');
      return null;
    }
  }

  @override
  Future<void> cancel() async {
    try {
      await _recorder?.cancel();
    } catch (_) {}
  }
}

final voiceRecorderProvider = Provider<VoiceRecorder>((ref) {
  final recorder = DeviceVoiceRecorder();
  ref.onDispose(() => recorder.cancel());
  return recorder;
});
