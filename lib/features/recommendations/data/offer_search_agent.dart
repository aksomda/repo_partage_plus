import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:firebase_ai/firebase_ai.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/core/firebase/firebase_init.dart';
import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/network/api_endpoints.dart';
import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/features/recommendations/data/voice_recorder.dart';

/// Résultat de l'agent : la demande retranscrite et les offres retenues,
/// dans l'ordre de pertinence.
class OfferSearchResult {
  const OfferSearchResult({
    required this.request,
    required this.keepIds,
    required this.engine,
    this.summary,
  });

  /// Demande de l'utilisateur (retranscrite si elle était dictée).
  final String request;
  final List<int> keepIds;

  /// Qui a filtré : « Gemini » ou « l’appareil ».
  final String engine;

  /// Phrase courte de l'agent (« 2 plats de riz gras à moins d'1 km »).
  final String? summary;
}

/// L'agent n'a pas pu répondre (hors ligne, service non activé…).
class OfferSearchUnavailable implements Exception {
  const OfferSearchUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Agent qui comprend une demande (voix ou texte) et filtre les offres.
abstract class OfferSearchAgent {
  /// Comprend l'audio (sinon, la dictée de l'appareil retranscrit d'abord).
  bool get understandsAudio;

  Future<OfferSearchResult> search({
    RecordedAudio? audio,
    String? text,
    required List<Json> candidates,
  });
}

/// Informations publiques d'une offre envoyées à l'agent (jamais de donnée
/// personnelle de l'utilisateur).
Map<String, Object?> candidateSummary(Json offer, {double? distanceKm}) {
  final description = '${offer['description'] ?? ''}';
  return {
    'id': offer['id'],
    'titre': offer['title'],
    if (description.isNotEmpty)
      'description': description.length > 160
          ? '${description.substring(0, 160)}…'
          : description,
    'categorie': offer['category_name'],
    'prix_fcfa': offer['price'] ?? 0,
    'unite': offer['unit'],
    'date_limite': offer['expiry_date'],
    'publieur': offer['publisher_type'],
    if (distanceKm != null)
      'distance_km': double.parse(distanceKm.toStringAsFixed(1)),
  };
}

const _instructions = '''
Tu es l'assistant de Partage+, une application de lutte contre le gaspillage
alimentaire au Burkina Faso (prix en francs CFA). Un utilisateur exprime ce
qu'il cherche, à l'oral (audio joint) ou par écrit.
1. Retranscris fidèlement sa demande en français dans "transcript" (pour une
   demande écrite, recopie-la).
2. Parmi les offres candidates (JSON), garde UNIQUEMENT celles qui répondent à
   la demande : produit ou plat demandé (synonymes et plats locaux compris :
   riz gras, tô, attiéké, soumbala…), prix, gratuité, distance, date limite.
   Exclus les offres d'un autre produit. N'invente jamais d'identifiant.
   Si la demande est générale (« quelque chose à manger »), garde les offres
   pertinentes.
3. Classe "keep_ids" de la plus pertinente à la moins pertinente.
4. "summary" : une phrase courte en français décrivant la sélection.
''';

/// IA ouverte du serveur (Groq par défaut : Whisper puis Llama) : toutes
/// les plateformes, clé gardée dans le .env du serveur. Seuls les id et
/// distances des offres partent ; le serveur relit le reste dans MySQL.
class ServerOfferSearchAgent implements OfferSearchAgent {
  ServerOfferSearchAgent(this.dio);

  final Dio dio;

  @override
  bool get understandsAudio => true;

  @override
  Future<OfferSearchResult> search({
    RecordedAudio? audio,
    String? text,
    required List<Json> candidates,
  }) async {
    try {
      final response = await dio.post<Map<String, dynamic>>(
        ApiEndpoints.voiceSearch,
        data: {
          if (audio != null)
            'audio': 'data:${audio.mime};base64,${base64Encode(audio.bytes)}',
          if (audio == null) 'text': text,
          'candidates': [
            for (final c in candidates)
              {'id': c['id'], 'distance_km': ?c['distance_km']},
          ],
        },
        options: Options(receiveTimeout: const Duration(seconds: 45)),
      );
      final data = response.data ?? const {};
      final transcript = '${data['transcript'] ?? text ?? ''}'.trim();
      return OfferSearchResult(
        request: transcript.isEmpty ? (text ?? '') : transcript,
        keepIds: [
          for (final id in data['keep_ids'] as List? ?? const [])
            if (id is num) id.toInt(),
        ],
        engine: data['engine'] as String? ?? 'l’IA',
        summary: data['summary'] as String?,
      );
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      throw OfferSearchUnavailable(switch (status) {
        null => 'Serveur injoignable',
        429 => 'Limite d’appels à l’IA atteinte pour l’heure',
        400 => ApiException.fromDio(error).message,
        _ => 'Service d’IA vocale indisponible',
      });
    }
  }
}

/// Gemini (Firebase AI Logic) : comprend directement l'audio, retranscrit
/// et filtre en un seul appel. La clé reste côté Firebase.
class GeminiOfferSearchAgent implements OfferSearchAgent {
  /// Seul modèle Flash ouvert aux nouveaux projets (gemini-2.5-* retirés).
  static const model = 'gemini-3.8-flash';
  static const timeout = Duration(seconds: 30);

  @override
  bool get understandsAudio =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  Future<OfferSearchResult> search({
    RecordedAudio? audio,
    String? text,
    required List<Json> candidates,
  }) async {
    await ensureFirebase();
    if (Firebase.apps.isEmpty) {
      throw const OfferSearchUnavailable('IA non configurée sur cet appareil');
    }
    final ids = {for (final c in candidates) c['id']};
    try {
      final gemini = FirebaseAI.googleAI().generativeModel(
        model: model,
        systemInstruction: Content.system(_instructions),
        generationConfig: GenerationConfig(
          temperature: 0.1,
          responseMimeType: 'application/json',
          responseSchema: Schema.object(
            properties: {
              'transcript': Schema.string(),
              'keep_ids': Schema.array(items: Schema.integer()),
              'summary': Schema.string(),
            },
            optionalProperties: ['summary'],
          ),
        ),
      );
      final response = await gemini
          .generateContent([
            Content.multi([
              TextPart(
                'Offres candidates : ${jsonEncode(candidates)}\n'
                '${audio == null ? 'Demande écrite : $text' : 'Demande : voir l’audio joint.'}',
              ),
              if (audio != null) InlineDataPart(audio.mime, audio.bytes),
            ]),
          ])
          .timeout(timeout);
      final data = jsonDecode(response.text ?? '');
      if (data is! Map) throw const FormatException('réponse non JSON');
      final keep = [
        for (final id in data['keep_ids'] as List? ?? const [])
          if (id is num && ids.contains(id.toInt())) id.toInt(),
      ];
      final transcript = '${data['transcript'] ?? text ?? ''}'.trim();
      return OfferSearchResult(
        request: transcript.isEmpty ? (text ?? '') : transcript,
        keepIds: keep,
        engine: 'Gemini',
        summary: data['summary'] as String?,
      );
    } on TimeoutException {
      throw const OfferSearchUnavailable('L’IA met trop de temps à répondre');
    } on QuotaExceeded catch (error) {
      debugPrint('Gemini : ${error.message}');
      throw const OfferSearchUnavailable('Quota de l’IA épuisé');
    } on FirebaseAIException catch (error) {
      debugPrint('Gemini : ${error.message}');
      throw const OfferSearchUnavailable('Service d’IA indisponible');
    } catch (error) {
      debugPrint('Gemini : $error');
      throw const OfferSearchUnavailable('Service d’IA indisponible');
    }
  }
}

/// Mots sans valeur pour la recherche (« je veux du riz gras » → riz, gras).
const _stopWords = {
  'je',
  'veux',
  'voudrais',
  'cherche',
  'recherche',
  'besoin',
  'aimerais',
  'du',
  'de',
  'des',
  'la',
  'le',
  'les',
  'un',
  'une',
  'pour',
  'avec',
  'sans',
  'moi',
  'mon',
  'ma',
  'mes',
  'ce',
  'cette',
  'soir',
  'midi',
  'matin',
  'pas',
  'trop',
  'cher',
  'chere',
  'quelque',
  'chose',
  'manger',
  'svp',
  'stp',
  'il',
  'y',
  'a',
  'est',
  'qui',
  'que',
  'et',
  'ou',
  'en',
  'au',
  'aux',
  'peu',
  'plat',
  'plats',
  'offre',
  'offres',
  'bonjour',
  'merci',
  'please',
};

/// Minuscules sans accents.
String _normalize(String value) {
  const from = 'àâäáãéèêëíìîïóòôöõúùûüçñ';
  const to = 'aaaaaeeeeiiiiooooouuuucn';
  final buffer = StringBuffer();
  for (final char in value.toLowerCase().split('')) {
    final index = from.indexOf(char);
    buffer.write(index < 0 ? char : to[index]);
  }
  return buffer.toString();
}

/// Repli sur l'appareil (hors ligne, sans IA) : mots-clés de la demande,
/// « gratuit » compris ; garde les offres qui en contiennent le plus.
class KeywordOfferSearchAgent implements OfferSearchAgent {
  const KeywordOfferSearchAgent();

  @override
  bool get understandsAudio => false;

  @override
  Future<OfferSearchResult> search({
    RecordedAudio? audio,
    String? text,
    required List<Json> candidates,
  }) async {
    final request = (text ?? '').trim();
    var words = _normalize(request)
        .split(RegExp(r'[^a-z0-9]+'))
        .where((w) => w.length >= 2 && !_stopWords.contains(w))
        .toSet();
    final freeOnly = words.remove('gratuit') | words.remove('gratuits');
    // Pluriels simples : « mangues » trouve « mangue ».
    words = {
      for (final w in words)
        w.length > 3 && w.endsWith('s') ? w.substring(0, w.length - 1) : w,
    };

    final scored = <(Json, int)>[];
    for (final offer in candidates) {
      if (freeOnly && (offer['price'] as num? ?? 0) > 0) continue;
      final haystack = _normalize(
        [
          offer['title'],
          offer['description'],
          offer['category_name'],
        ].whereType<String>().join(' '),
      );
      final score = words.where(haystack.contains).length;
      if (words.isEmpty || score > 0) scored.add((offer, score));
    }
    final best = scored.fold<int>(0, (max, e) => e.$2 > max ? e.$2 : max);
    final keep = [
      for (final (offer, score) in scored)
        if (score == best) offer['id'] as int,
    ];
    return OfferSearchResult(
      request: request,
      keepIds: keep,
      engine: 'l’appareil',
    );
  }
}

/// Chaque IA dans l'ordre (la première qui répond l'emporte) ; une demande
/// écrite finit par les mots-clés de l'appareil. Une demande audio que
/// personne ne comprend remonte l'erreur : l'écran passe alors par la
/// dictée de l'appareil.
class FallbackOfferSearchAgent implements OfferSearchAgent {
  const FallbackOfferSearchAgent(this.agents, this.local);

  final List<OfferSearchAgent> agents;
  final OfferSearchAgent local;

  @override
  bool get understandsAudio => agents.any((agent) => agent.understandsAudio);

  @override
  Future<OfferSearchResult> search({
    RecordedAudio? audio,
    String? text,
    required List<Json> candidates,
  }) async {
    var last = const OfferSearchUnavailable('Service d’IA indisponible');
    for (final agent in agents) {
      if (audio != null && !agent.understandsAudio) continue;
      try {
        return await agent.search(
          audio: audio,
          text: text,
          candidates: candidates,
        );
      } on OfferSearchUnavailable catch (error) {
        last = error;
      }
    }
    if (audio != null) throw last;
    return local.search(text: text, candidates: candidates);
  }
}

/// IA ouverte du serveur (toutes plateformes), puis Gemini (Android, iOS),
/// puis mots-clés sur l'appareil.
final offerSearchAgentProvider = Provider<OfferSearchAgent>(
  (ref) => FallbackOfferSearchAgent([
    ServerOfferSearchAgent(ref.watch(dioProvider)),
    GeminiOfferSearchAgent(),
  ], const KeywordOfferSearchAgent()),
);
