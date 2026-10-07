/**
 * Recherche d'offres à la voix ou au texte par une IA ouverte, via une API
 * compatible OpenAI : Groq par défaut (palier gratuit, Whisper pour la
 * retranscription, Llama pour le filtrage), ou tout autre service du même
 * format (Ollama, serveur Whisper local…) réglé dans le .env.
 */

/** Limites des entrées envoyées au modèle. */
export const VOICE_LIMITS = {
  audioBytes: 3 * 1024 * 1024,
  text: 500,
  candidates: 100,
};

/** Erreur du service d'IA (réseau, quota, réponse illisible). */
export class VoiceAiError extends Error {}

const EXTENSIONS = {
  'audio/mp4': 'm4a',
  'audio/m4a': 'm4a',
  'audio/aac': 'm4a',
  'audio/wav': 'wav',
  'audio/x-wav': 'wav',
  'audio/webm': 'webm',
  'audio/ogg': 'ogg',
  'audio/mpeg': 'mp3',
  'audio/flac': 'flac',
};

/** « data:audio/mp4;base64,… » → { mime, buffer } ; null si invalide. */
export function decodeAudio(dataUrl) {
  const match = /^data:(audio\/[a-z0-9.+-]+)(?:;[a-z0-9=.-]+)*;base64,([A-Za-z0-9+/]+=*)$/i.exec(
    dataUrl ?? '',
  );
  if (!match) return null;
  const mime = match[1].toLowerCase();
  if (!EXTENSIONS[mime]) return null;
  return { mime, buffer: Buffer.from(match[2], 'base64') };
}

async function call(fetchImpl, url, options) {
  let response;
  try {
    response = await fetchImpl(url, { ...options, signal: AbortSignal.timeout(30_000) });
  } catch (error) {
    throw new VoiceAiError(`injoignable : ${error.message}`);
  }
  if (!response.ok) {
    const detail = await response.text().catch(() => '');
    throw new VoiceAiError(`HTTP ${response.status} ${detail.slice(0, 200)}`);
  }
  return response.json();
}

/** Retranscrit l'audio (Whisper) en français. */
export async function transcribe({ audio, settings, fetchImpl = fetch }) {
  const form = new FormData();
  form.append(
    'file',
    new Blob([audio.buffer], { type: audio.mime }),
    `demande.${EXTENSIONS[audio.mime]}`,
  );
  form.append('model', settings.sttModel);
  form.append('language', 'fr');
  form.append('response_format', 'json');
  const data = await call(fetchImpl, `${settings.baseUrl}/audio/transcriptions`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${settings.apiKey}` },
    body: form,
  });
  const text = `${data?.text ?? ''}`.trim();
  if (!text) throw new VoiceAiError('retranscription vide');
  return text;
}

const INSTRUCTIONS = `Tu es l'assistant de Partage+, une application de lutte contre le
gaspillage alimentaire au Burkina Faso (prix en francs CFA). Tu reçois la demande
d'un utilisateur et des offres candidates (JSON).
Garde UNIQUEMENT les offres qui répondent à la demande : produit ou plat demandé
(synonymes et plats locaux compris : riz gras, tô, attiéké, soumbala…), prix,
gratuité, distance, date limite. Exclus les offres d'un autre produit. N'invente
jamais d'identifiant. Si la demande est générale (« quelque chose à manger »),
garde les offres pertinentes.
Réponds uniquement en JSON : {"keep_ids": [id, …] du plus pertinent au moins
pertinent, "summary": "une phrase courte en français décrivant la sélection"}.`;

/** Filtre les offres selon la demande (modèle de langage, réponse JSON). */
export async function filterOffers({ request, candidates, settings, fetchImpl = fetch }) {
  const data = await call(fetchImpl, `${settings.baseUrl}/chat/completions`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${settings.apiKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      model: settings.llmModel,
      temperature: 0.1,
      response_format: { type: 'json_object' },
      messages: [
        { role: 'system', content: INSTRUCTIONS },
        {
          role: 'user',
          content: `Demande : ${request}\nOffres candidates : ${JSON.stringify(candidates)}`,
        },
      ],
    }),
  });
  let parsed;
  try {
    parsed = JSON.parse(data?.choices?.[0]?.message?.content ?? '');
  } catch {
    throw new VoiceAiError('réponse du modèle illisible');
  }
  const allowed = new Set(candidates.map((candidate) => candidate.id));
  const keepIds = [
    ...new Set(
      (Array.isArray(parsed?.keep_ids) ? parsed.keep_ids : [])
        .map(Number)
        .filter((offerId) => allowed.has(offerId)),
    ),
  ];
  return {
    keepIds,
    summary: typeof parsed?.summary === 'string' ? parsed.summary.slice(0, 300) : null,
  };
}
