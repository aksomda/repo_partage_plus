import assert from 'node:assert/strict';
import { after, before, describe, test } from 'node:test';

// Base dédiée, recréée à chaque exécution. Défini avant de charger config.js
// (les valeurs vides empêchent dotenv de reprendre celles du .env).
process.env.NODE_ENV = 'test';
process.env.DATABASE_URL = process.env.TEST_DATABASE_URL ?? '';
// DB_SSL=true du .env vise TiDB, pas le MySQL local des tests.
process.env.DB_SSL = process.env.TEST_DB_SSL ?? 'false';
process.env.DB_NAME = process.env.TEST_DB_NAME ?? 'repas_partage_test';
process.env.JOBS_TOKEN = 'jeton-de-test';

const { default: request } = await import('supertest');
const { app } = await import('../src/app.js');
const { migrate } = await import('../src/db/migrate.js');
const { pool } = await import('../src/db/pool.js');
const { DEMO_PASSWORD, seed } = await import('../src/db/seed.js');
const { setFirebaseGateway } = await import('../src/services/firebase.js');
const { syncFirebaseAccounts } = await import('../src/services/firebase_sync.js');
const { parseAddress, purgeFirebaseMails, sentMails, setMailFetch, setMailStore } = await import(
  '../src/services/mailer.js'
);
const { firestoreMirror, flushFirestoreMirror, setFirestoreStore } = await import(
  '../src/services/firestore_mirror.js'
);
const { config } = await import('../src/config.js');
const { setRodiumFetch, setVoiceFetch, resetAiRateLimit } = await import(
  '../src/routes/ai.js'
);
const { HttpError } = await import('../src/http/errors.js');
const { fillMonths, MONTHS } = await import('../src/routes/impact.js');
const { isDatabaseUnavailable } = await import('../src/db/pool.js');
const { setPushSender } = await import('../src/services/push.js');
const { normalizePhone, setSmsFetch } = await import('../src/services/sms.js');
const { flushCodeExtras } = await import('../src/services/otp.js');
const { resetLoginAttempts, MAX_FAILURES } = await import('../src/http/login_attempts.js');
const rateLimitModule = await import('../src/http/rate_limit.js');

// Faux Firebase : un jeton « fake:<uid>:<email>:… » est accepté tel quel.
const firebaseCalls = [];
const firebaseUsers = new Map();
const fakeFirebase = {
  async verifyIdToken(idToken) {
    const [prefix, uid, email] = idToken.split(':');
    if (prefix !== 'fake') throw new HttpError(401, 'Session Firebase invalide ou expirée');
    return { uid, email };
  },
  async setDisabled(uid, disabled) {
    firebaseCalls.push(['disabled', uid, disabled]);
  },
  async markEmailVerified(uid) {
    firebaseCalls.push(['verified', uid]);
  },
  async setPassword(uid, password) {
    firebaseCalls.push(['password', uid, password]);
  },
  async createUser({ email }) {
    firebaseCalls.push(['created', email]);
    return `uid-${email}`;
  },
  // Comptes Firebase connus du faux Firebase (inscriptions interrompues).
  async findUserByEmail(email) {
    return firebaseUsers.get(email) ?? null;
  },
  async deleteUser(uid) {
    firebaseCalls.push(['deleted', uid]);
    for (const [email, user] of firebaseUsers) {
      if (user.uid === uid) firebaseUsers.delete(email);
    }
  },
};
setFirebaseGateway(fakeFirebase);

// Faux Firestore : documents gardés en mémoire, par collection puis par id.
const firestoreDocs = {};
const firestoreCollection = (name) => (firestoreDocs[name] ??= new Map());
setFirestoreStore({
  async write(collection, rows) {
    for (const row of rows) firestoreCollection(collection).set(row.id, row);
  },
  async remove(collection, ids) {
    for (const id of ids) firestoreCollection(collection).delete(Number(id));
  },
  async listIds(collection) {
    return [...firestoreCollection(collection).keys()].map(String);
  },
  async readDoc(collection, id) {
    return firestoreCollection(collection).get(Number(id)) ?? null;
  },
  async readAll(collection) {
    return [...firestoreCollection(collection).values()];
  },
  async readState() {
    return null;
  },
  async writeState() {},
});

const fakeToken = (uid, email) => `fake:${uid}:${email}:${'x'.repeat(20)}`;

/** Dernier code d'activation envoyé à cette adresse. */
function lastCode(email) {
  const mail = sentMails.findLast((item) => item.to === email);
  return mail?.text.match(/\b(\d{6})\b/)?.[1];
}

const api = request(app);
const tokens = {};

async function login(email) {
  const res = await api.post('/api/auth/login').send({ email, password: DEMO_PASSWORD });
  assert.equal(res.status, 200, res.text);
  return res.body.token;
}

const as = (who) => ({ Authorization: `Bearer ${tokens[who]}` });

function futureIso(hours) {
  return new Date(Date.now() + hours * 3_600_000).toISOString();
}

function tomorrow() {
  return new Date(Date.now() + 86_400_000).toISOString().slice(0, 10);
}

before(async () => {
  await migrate({ reset: true });
  await seed();
  tokens.admin = await login('admin@demo.local');
  tokens.donor = await login('commerce@demo.local');
  tokens.beneficiary = await login('beneficiaire@demo.local');
  tokens.association = await login('association2@demo.local');
});

after(async () => {
  await pool.end();
});

describe('santé et référentiels', () => {
  test('GET /health', async () => {
    const res = await api.get('/health');
    assert.equal(res.status, 200);
    assert.equal(res.body.status, 'ok');
  });

  test('GET /api/categories renvoie les catégories avec leurs facteurs', async () => {
    const res = await api.get('/api/categories');
    assert.equal(res.status, 200);
    assert.ok(res.body.length >= 6);
    assert.ok(res.body.every((category) => category.co2_kg_per_kg !== null));
  });

  test('route inconnue : 404', async () => {
    const res = await api.get('/api/inexistant');
    assert.equal(res.status, 404);
  });
});

describe('impact : calculs', () => {
  test('les mois sans retrait sont présents, à zéro', () => {
    const now = new Date(Date.UTC(2026, 0, 15));
    const months = fillMonths([{ month: '2025-03', pickups: 2, food_kg: 1.25, co2_kg: 0, meals: 3 }], now);
    assert.equal(months.length, 12);
    assert.equal(months[0].month, '2025-02');
    assert.equal(months.at(-1).month, '2026-01');
    assert.equal(months[1].pickups, 2);
    assert.equal(months[1].food_kg, 1.3);
    assert.equal(months[2].pickups, 0);
  });

  test('erreurs de connexion MySQL reconnues', () => {
    assert.ok(isDatabaseUnavailable({ code: 'ECONNREFUSED' }));
    assert.ok(isDatabaseUnavailable({ code: 'PROTOCOL_CONNECTION_LOST' }));
    assert.ok(!isDatabaseUnavailable({ code: 'ER_DUP_ENTRY' }));
    assert.ok(!isDatabaseUnavailable(null));
  });
});

describe('authentification', () => {
  const actors = {};

  before(async () => {
    const res = await api.get('/api/admin/actors').set(as('admin'));
    for (const actor of res.body) actors[actor.code] = actor.id;
  });

  const registration = (overrides = {}) => ({
    id_token: fakeToken('uid-nouveau', 'nouveau@test.local'),
    first_name: 'Awa',
    last_name: 'Traoré',
    gender: 'female',
    age: 28,
    phone: '+226 70 00 00 00',
    actor_id: actors.particulier,
    ...overrides,
  });

  test('inscription copiée dans Firestore, sans le mot de passe', async () => {
    const res = await api.post('/api/auth/register').send(
      registration({
        id_token: undefined,
        email: 'copie.firestore@test.local',
        password: 'motdepasse1',
      }),
    );
    assert.equal(res.status, 201, res.text);
    await flushFirestoreMirror();

    const [{ id }] = await pool
      .query('SELECT id FROM users WHERE email = ?', ['copie.firestore@test.local'])
      .then(([rows]) => rows);
    const doc = firestoreCollection('users').get(id);
    assert.ok(doc, 'compte absent de Firestore');
    assert.equal(doc.email, 'copie.firestore@test.local');
    assert.equal(doc.first_name, 'Awa');
    assert.equal(doc.status, 'pending');
    assert.equal('password_hash' in doc, false);

    // Toutes les tables métier sont copiées, jamais les secrets.
    for (const table of ['actors', 'categories', 'impact_factors']) {
      assert.ok(firestoreCollection(table).size > 0, table);
    }
    for (const secret of ['email_otps', 'guest_tokens', 'idempotency_keys']) {
      assert.equal(firestoreDocs[secret], undefined, secret);
    }
  });

  test("les acteurs proposés à l'inscription excluent l'administrateur", async () => {
    const res = await api.get('/api/actors');
    assert.equal(res.status, 200);
    assert.deepEqual(
      res.body.map((actor) => actor.code).sort(),
      ['association', 'commercant', 'particulier', 'restaurateur'],
    );
  });

  test('inscription : compte en attente et code envoyé par e-mail', async () => {
    const created = await api.post('/api/auth/register').send(registration());
    assert.equal(created.status, 201, created.text);
    assert.equal(created.body.token, undefined);
    assert.equal(created.body.user.status, 'pending');
    assert.equal(created.body.user.role, 'beneficiary');
    assert.equal(created.body.user.actor_code, 'particulier');
    assert.equal(created.body.user.name, 'Awa Traoré');
    assert.equal(created.body.user.password_hash, undefined);
    assert.match(lastCode('nouveau@test.local'), /^\d{6}$/);
  });

  test("connexion refusée tant que le compte n'est pas activé", async () => {
    const res = await api
      .post('/api/auth/firebase')
      .send({ id_token: fakeToken('uid-nouveau', 'nouveau@test.local') });
    assert.equal(res.status, 403);
    assert.equal(res.body.details.code, 'account_pending');
  });

  test('renvoi du code trop rapide : 429', async () => {
    const res = await api.post('/api/auth/resend-code').send({ email: 'nouveau@test.local' });
    assert.equal(res.status, 429);
  });

  test('mauvais code : 400, puis activation avec le bon code', async () => {
    const code = lastCode('nouveau@test.local');
    const wrong = await api
      .post('/api/auth/verify-email')
      .send({ email: 'nouveau@test.local', code: code === '000000' ? '111111' : '000000' });
    assert.equal(wrong.status, 400);
    assert.match(wrong.body.error, /4 essai/);

    const ok = await api.post('/api/auth/verify-email').send({ email: 'nouveau@test.local', code });
    assert.equal(ok.status, 200, ok.text);
    assert.ok(ok.body.token);
    assert.equal(ok.body.user.status, 'active');
    assert.ok(firebaseCalls.some(([kind, uid]) => kind === 'verified' && uid === 'uid-nouveau'));

    const again = await api
      .post('/api/auth/verify-email')
      .send({ email: 'nouveau@test.local', code });
    assert.equal(again.status, 409);
  });

  test('connexion Firebase une fois le compte activé', async () => {
    const res = await api
      .post('/api/auth/firebase')
      .send({ id_token: fakeToken('uid-nouveau', 'nouveau@test.local') });
    assert.equal(res.status, 200, res.text);
    assert.equal(res.body.user.email, 'nouveau@test.local');
  });

  test('jeton Firebase invalide : 401 ; sans profil : 404', async () => {
    const invalid = await api.post('/api/auth/firebase').send({ id_token: 'x'.repeat(40) });
    assert.equal(invalid.status, 401);

    const missing = await api
      .post('/api/auth/firebase')
      .send({ id_token: fakeToken('uid-inconnu', 'inconnu@test.local') });
    assert.equal(missing.status, 404);
    assert.equal(missing.body.details.code, 'profile_missing');
  });

  test('doublon : 409 ; nouvel essai du même compte en attente limité à 1/min', async () => {
    const duplicate = await api
      .post('/api/auth/register')
      .send(registration({ id_token: fakeToken('uid-autre', 'nouveau@test.local') }));
    assert.equal(duplicate.status, 409);

    const payload = registration({
      id_token: fakeToken('uid-resto', 'resto@test.local'),
      actor_id: actors.restaurateur,
    });
    const first = await api.post('/api/auth/register').send(payload);
    assert.equal(first.status, 201, first.text);
    assert.equal(first.body.user.role, 'donor');

    const retry = await api.post('/api/auth/register').send({ ...payload, first_name: 'Ali' });
    assert.equal(retry.status, 429);
  });

  test("impossible de s'inscrire administrateur", async () => {
    const res = await api.post('/api/auth/register').send(
      registration({
        id_token: fakeToken('uid-pirate', 'pirate@test.local'),
        actor_id: actors.administrateur,
      }),
    );
    assert.equal(res.status, 400);
  });

  test('inscription invalide : 400 avec détails', async () => {
    const res = await api
      .post('/api/auth/register')
      .send({ id_token: 'court', first_name: 'X', gender: 'autre', age: 5, phone: 'abc' });
    assert.equal(res.status, 400);
    assert.ok(res.body.details.length >= 5);
  });

  test('mauvais mot de passe : 401', async () => {
    const res = await api
      .post('/api/auth/login')
      .send({ email: 'admin@demo.local', password: 'faux' });
    assert.equal(res.status, 401);
  });

  test('GET /api/auth/me exige un jeton', async () => {
    assert.equal((await api.get('/api/auth/me')).status, 401);
    const res = await api.get('/api/auth/me').set(as('donor'));
    assert.equal(res.status, 200);
    assert.equal(res.body.role, 'donor');
    assert.equal(res.body.actor_code, 'commercant');
  });

  test('mot de passe oublié : code par e-mail, nouveau mot de passe dans Firebase', async () => {
    const unknown = await api
      .post('/api/auth/password/forgot')
      .send({ email: 'inconnu@test.local' });
    assert.equal(unknown.status, 204);

    const sent = await api
      .post('/api/auth/password/forgot')
      .send({ email: 'nouveau@test.local' });
    assert.equal(sent.status, 204);
    const code = lastCode('nouveau@test.local');
    assert.match(sentMails.at(-1).subject, /réinitialisation/);

    const weak = await api
      .post('/api/auth/password/reset')
      .send({ email: 'nouveau@test.local', code, password: 'court' });
    assert.equal(weak.status, 400);

    const wrong = await api
      .post('/api/auth/password/reset')
      .send({ email: 'nouveau@test.local', code: code === '000000' ? '111111' : '000000', password: 'nouveau123' });
    assert.equal(wrong.status, 400);
    assert.equal(wrong.body.details.code, 'otp_invalid');

    const res = await api
      .post('/api/auth/password/reset')
      .send({ email: 'nouveau@test.local', code, password: 'nouveau123' });
    assert.equal(res.status, 204, res.text);
    assert.deepEqual(firebaseCalls.at(-1), ['password', 'uid-nouveau', 'nouveau123']);

    // Code à usage unique.
    const again = await api
      .post('/api/auth/password/reset')
      .send({ email: 'nouveau@test.local', code, password: 'nouveau123' });
    assert.equal(again.status, 400);
  });
});

describe('parcours offre → réservation → retrait', () => {
  let offerId;
  let reservationId;
  let pickupCode;

  test('le donateur publie une offre, visible tout de suite', async () => {
    const [category] = (await api.get('/api/categories')).body;
    const res = await api
      .post('/api/offers')
      .set(as('donor'))
      .send({
        category_id: category.id,
        title: 'Offre de test',
        quantity: 5,
        weight_kg: 2.5,
        expiry_date: tomorrow(),
        pickup_start: futureIso(-1),
        pickup_end: futureIso(5),
        address: '1 rue du Test',
        latitude: 12.3714,
        longitude: -1.5197,
        contact_email: 'Donateur@Test.local',
        country_code: 'bf',
        country_name: 'Burkina Faso',
      });
    assert.equal(res.status, 201, res.text);
    assert.equal(res.body.status, 'published');
    assert.equal(res.body.country_code, 'BF');
    assert.equal(res.body.country_name, 'Burkina Faso');
    // L'e-mail de contact n'est rendu qu'au publieur.
    assert.equal(res.body.contact_email, 'donateur@test.local');
    offerId = res.body.id;

    const list = await api.get('/api/offers?limit=100');
    const listed = list.body.find((offer) => offer.id === offerId);
    assert.ok(listed);
    assert.equal(listed.contact_email, undefined);
    const detail = await api.get(`/api/offers/${offerId}`);
    assert.equal(detail.body.contact_email, undefined);
  });

  test('poids total facultatif, e-mail de contact vérifié', async () => {
    const [category] = (await api.get('/api/categories')).body;
    const body = {
      category_id: category.id,
      title: 'Sans poids',
      quantity: 1,
      weight_kg: '',
      expiry_date: tomorrow(),
      pickup_start: futureIso(-1),
      pickup_end: futureIso(5),
      address: '1 rue du Test',
      latitude: 12.3714,
      longitude: -1.5197,
    };
    const res = await api.post('/api/offers').set(as('donor')).send(body);
    assert.equal(res.status, 201, res.text);
    assert.equal(res.body.weight_kg, null);

    const badEmail = await api
      .post('/api/offers')
      .set(as('donor'))
      .send({ ...body, contact_email: 'pas-un-email' });
    assert.equal(badEmail.status, 400);
  });

  test('une offre incomplète est refusée', async () => {
    const res = await api.post('/api/offers').set(as('beneficiary')).send({});
    assert.equal(res.status, 400);
  });

  test("l'offre apparaît à proximité et dans la liste de l'admin", async () => {
    const visible = await api.get('/api/admin/offers').set(as('admin'));
    assert.ok(visible.body.some((offer) => offer.id === offerId));

    const nearby = await api.get('/api/offers/nearby?lat=12.3714&lng=-1.5197&radius_km=1');
    const found = nearby.body.find((offer) => offer.id === offerId);
    assert.ok(found);
    assert.ok(found.distance_km < 0.1);
  });

  test('un refus sans motif est rejeté', async () => {
    const res = await api
      .patch(`/api/admin/offers/${offerId}/moderation`)
      .set(as('admin'))
      .send({ decision: 'reject' });
    assert.equal(res.status, 400);
  });

  test('une association réserve dès l’activation, sans validation par l’admin', async () => {
    const [category] = (await api.get('/api/categories')).body;
    const offer = await api.post('/api/offers').set(as('donor')).send({
      category_id: category.id,
      title: 'Pour une association',
      quantity: 4,
      expiry_date: tomorrow(),
      pickup_start: futureIso(-1),
      pickup_end: futureIso(5),
      address: '1 rue du Test',
      latitude: 12.3714,
      longitude: -1.5197,
    });
    assert.equal(offer.status, 201, offer.text);
    const res = await api
      .post('/api/reservations')
      .set(as('association'))
      .send({ offer_id: offer.body.id, quantity: 2 });
    assert.equal(res.status, 201, res.text);
  });

  test('le bénéficiaire réserve, le donateur ne voit pas le code', async () => {
    const tooMany = await api
      .post('/api/reservations')
      .set(as('beneficiary'))
      .send({ offer_id: offerId, quantity: 50 });
    assert.equal(tooMany.status, 409);

    const res = await api
      .post('/api/reservations')
      .set(as('beneficiary'))
      .send({ offer_id: offerId, quantity: 2 });
    assert.equal(res.status, 201, res.text);
    assert.match(res.body.pickup_code, /^\d{6}$/);
    reservationId = res.body.id;
    pickupCode = res.body.pickup_code;

    const offer = await api.get(`/api/offers/${offerId}`);
    assert.equal(offer.body.quantity_available, 3);

    const received = await api.get('/api/reservations/received').set(as('donor'));
    const mine = received.body.find((reservation) => reservation.id === reservationId);
    assert.equal(mine.pickup_code, undefined);
  });

  test('le donateur confirme, le bénéficiaire est notifié', async () => {
    const res = await api
      .patch(`/api/reservations/${reservationId}/confirm`)
      .set(as('donor'));
    assert.equal(res.status, 200, res.text);
    assert.equal(res.body.status, 'confirmed');

    const notifications = await api.get('/api/notifications').set(as('beneficiary'));
    assert.ok(notifications.body.some((n) => n.type === 'reservation_confirmed'));
  });

  test('la tâche planifiée envoie le rappel de retrait une seule fois', async () => {
    const unauthorized = await api.post('/api/jobs/run');
    assert.equal(unauthorized.status, 401);

    const first = await api.post('/api/jobs/run').set('X-Jobs-Token', 'jeton-de-test');
    assert.equal(first.status, 200);
    assert.ok(first.body.pickup_reminders >= 1);
    assert.ok(first.body.expiry_alerts >= 1);

    const second = await api.post('/api/admin/jobs/run').set(as('admin'));
    assert.equal(second.body.pickup_reminders, 0);

    const notifications = await api.get('/api/notifications').set(as('beneficiary'));
    assert.ok(notifications.body.some((n) => n.type === 'pickup_reminder'));
  });

  test('retrait avec le code, puis impact calculé', async () => {
    const wrong = await api
      .post(`/api/reservations/${reservationId}/pickup`)
      .set(as('donor'))
      .send({ pickup_code: pickupCode === '000000' ? '111111' : '000000' });
    assert.equal(wrong.status, 400);

    const res = await api
      .post(`/api/reservations/${reservationId}/pickup`)
      .set(as('donor'))
      .send({ pickup_code: pickupCode });
    assert.equal(res.status, 200, res.text);
    assert.equal(res.body.status, 'picked_up');

    const impact = await api.get('/api/impact/me').set(as('beneficiary'));
    assert.equal(impact.body.pickups, 1);
    assert.equal(impact.body.food_kg, 1);
  });

  test('tableau de bord : compteurs, 12 mois complets, catégories, indicateurs sociaux', async () => {
    const res = await api.get('/api/impact/me/dashboard').set(as('beneficiary'));
    assert.equal(res.status, 200, res.text);
    assert.equal(res.body.source, 'mysql');
    assert.equal(res.body.impact.pickups, 1);
    // Produits = unités retirées (la réservation du test en compte 2).
    assert.equal(res.body.impact.items, 2);

    // 12 mois consécutifs, le dernier étant le mois en cours.
    const months = res.body.impact_monthly;
    assert.equal(months.length, MONTHS);
    assert.equal(months.at(-1).month, new Date().toISOString().slice(0, 7));
    assert.equal(months.at(-1).pickups, 1);
    assert.equal(months.reduce((sum, m) => sum + m.pickups, 0), 1);

    assert.equal(res.body.impact_by_category.length, 1);
    assert.equal(res.body.impact_by_category[0].food_kg, 1);

    // Bénéficiaire : 1 retrait reçu d'1 donateur. Donateur : 1 personne aidée.
    assert.equal(res.body.impact_social.pickups_received, 1);
    assert.equal(res.body.impact_social.donors_met, 1);
    const donor = await api.get('/api/impact/me/dashboard').set(as('donor'));
    assert.equal(donor.body.impact_social.people_helped, 1);
    assert.equal(donor.body.impact_social.pickups_given, 1);
    assert.ok(donor.body.impact_social.offers_shared >= 1);

    // Même contenu dans l'instantané hors ligne.
    const sync = await api.get('/api/sync').set(as('beneficiary'));
    for (const key of ['impact', 'impact_monthly', 'impact_by_category', 'impact_social']) {
      assert.deepEqual(sync.body[key], res.body[key], key);
    }
  });

  test('MySQL indisponible : tableau de bord servi depuis la copie Firestore', async () => {
    await api.get('/api/impact/me/dashboard').set(as('beneficiary'));
    await flushFirestoreMirror();

    const realQuery = pool.query;
    pool.query = async () => {
      throw Object.assign(new Error('connect ECONNREFUSED'), { code: 'ECONNREFUSED' });
    };
    try {
      const res = await api.get('/api/impact/me/dashboard').set(as('beneficiary'));
      assert.equal(res.status, 200, res.text);
      assert.equal(res.body.source, 'firestore');
      assert.equal(res.body.impact.pickups, 1);

      // Les autres routes répondent proprement au lieu de planter.
      const offers = await api.get('/api/offers').set(as('beneficiary'));
      assert.equal(offers.status, 503);
      assert.match(offers.body.error, /indisponible/);
    } finally {
      pool.query = realQuery;
    }
    assert.equal((await api.get('/health')).status, 200);
  });

  test('les recommandations privilégient la catégorie déjà réservée', async () => {
    const res = await api.get('/api/recommendations').set(as('beneficiary'));
    assert.equal(res.status, 200);
    assert.ok(res.body.length > 0);
    assert.ok(res.body[0].affinity >= 1);
  });
});

describe('invités (sans compte) et paiement hors application', () => {
  const guest = { first_name: 'Moussa', last_name: 'Kaboré', phone: '+226 76 11 22 33' };
  let categoryId;
  let guestOffer;
  let paidOffer;
  let guestReservation;

  const offerBody = (overrides = {}) => ({
    category_id: categoryId,
    title: 'Offre invité',
    quantity: 4,
    weight_kg: 2,
    expiry_date: tomorrow(),
    pickup_start: futureIso(-1),
    pickup_end: futureIso(6),
    address: 'Marché central',
    latitude: 12.372,
    longitude: -1.52,
    ...overrides,
  });

  before(async () => {
    [{ id: categoryId }] = (await api.get('/api/categories')).body;
  });

  test('instantané public sans compte : catégories et offres disponibles', async () => {
    const res = await api.get('/api/sync/public');
    assert.equal(res.status, 200);
    assert.ok(res.body.categories.length >= 6);
    assert.ok(res.body.offers.length > 0);
    assert.equal(res.body.profile, undefined);
  });

  test('offre sans compte copiée dans Firestore, avec les colonnes MySQL', async () => {
    const res = await api.post('/api/offers').send(offerBody({ guest, title: 'Copie Firestore' }));
    assert.equal(res.status, 201, res.text);
    await flushFirestoreMirror();

    const doc = firestoreCollection('offers').get(res.body.id);
    assert.ok(doc, 'offre absente de Firestore');
    assert.equal(doc.title, 'Copie Firestore');
    assert.equal(doc.donor_id, null);
    assert.equal(doc.guest_first_name, 'Moussa');
    assert.equal(doc.guest_last_name, 'Kaboré');
    assert.equal(doc.guest_phone, guest.phone);
    assert.equal(doc.status, 'published');
    assert.equal(doc.quantity_available, 4);

    // Le retrait par l'administrateur est répercuté sur la copie.
    const withdrawn = await api
      .patch(`/api/admin/offers/${res.body.id}/moderation`)
      .set(as('admin'))
      .send({ decision: 'reject', reason: 'Abus' });
    assert.equal(withdrawn.status, 200, withdrawn.text);
    await flushFirestoreMirror();
    assert.equal(firestoreCollection('offers').get(res.body.id).status, 'rejected');
  });

  test('photo jointe : enregistrée, servie, refusée si ce n’est pas une image', async () => {
    const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46]);
    const photo = `data:image/jpeg;base64,${jpeg.toString('base64')}`;

    const res = await api.post('/api/offers').send(offerBody({ guest, photo }));
    assert.equal(res.status, 201, res.text);
    assert.equal(res.body.photo_path.split('?')[0], `/offers/${res.body.id}/photo`);

    const image = await api.get(`/api/offers/${res.body.id}/photo`);
    assert.equal(image.status, 200);
    assert.equal(image.type, 'image/jpeg');
    assert.deepEqual(image.body, jpeg);

    const without = await api.post('/api/offers').send(offerBody({ guest }));
    assert.equal(without.body.photo_path, null);
    assert.equal((await api.get(`/api/offers/${without.body.id}/photo`)).status, 404);

    const fake = `data:image/png;base64,${Buffer.from('pas une image').toString('base64')}`;
    const refused = await api.post('/api/offers').send(offerBody({ guest, photo: fake }));
    assert.equal(refused.status, 400);
  });

  test('un invité publie : identité obligatoire, jeton remis une seule fois', async () => {
    const missing = await api.post('/api/offers').send(offerBody());
    assert.equal(missing.status, 400);

    const res = await api.post('/api/offers').send(offerBody({ guest }));
    assert.equal(res.status, 201, res.text);
    assert.equal(res.body.status, 'published');
    assert.equal(res.body.donor_id, null);
    assert.equal(res.body.is_guest, 1);
    assert.equal(res.body.donor_name, 'Moussa Kaboré');
    assert.equal(res.body.publisher_type, 'invite');
    assert.equal(res.body.contact_phone, guest.phone);
    assert.ok(res.body.guest_token.length > 20);
    guestOffer = res.body;

    // Visible de tous tout de suite ; le jeton n'est jamais renvoyé.
    assert.equal((await api.get(`/api/offers/${guestOffer.id}`)).status, 200);
    const own = await api
      .get(`/api/offers/${guestOffer.id}`)
      .set('X-Guest-Token', guestOffer.guest_token);
    assert.equal(own.status, 200);
    assert.equal(own.body.guest_token, undefined);
  });

  test('offre payante : instructions de paiement obligatoires', async () => {
    const without = await api
      .post('/api/offers')
      .set(as('beneficiary'))
      .send(offerBody({ title: 'Jus de fruits', price: 500 }));
    assert.equal(without.status, 400);

    // Un particulier connecté peut publier (tous les acteurs publient).
    const res = await api
      .post('/api/offers')
      .set(as('beneficiary'))
      .send(
        offerBody({ title: 'Jus de fruits', price: 500, payment_info: 'Orange Money 70 00 00 00' }),
      );
    assert.equal(res.status, 201, res.text);
    assert.equal(res.body.price, 500);
    assert.equal(res.body.publisher_type, 'particulier');
    paidOffer = res.body;
  });

  test('un invité réserve une offre payante avec la référence de sa transaction', async () => {
    const noReference = await api
      .post('/api/reservations')
      .send({ offer_id: paidOffer.id, quantity: 2, guest });
    assert.equal(noReference.status, 400);
    assert.match(noReference.body.error, /Référence de paiement/);

    const res = await api
      .post('/api/reservations')
      .send({ offer_id: paidOffer.id, quantity: 2, payment_reference: 'OM240929.1234', guest });
    assert.equal(res.status, 201, res.text);
    assert.equal(res.body.amount, 1000);
    assert.equal(res.body.status, 'pending');
    assert.equal(res.body.beneficiary_name, 'Moussa Kaboré');
    assert.match(res.body.pickup_code, /^\d{6}$/);
    assert.ok(res.body.guest_token);
    guestReservation = res.body;

    const again = await api
      .post('/api/reservations')
      .send({ offer_id: paidOffer.id, payment_reference: 'OM240929.9999', guest });
    assert.equal(again.status, 409);
  });

  test('le publieur voit la référence de paiement mais pas le code, puis confirme', async () => {
    const received = await api.get('/api/reservations/received').set(as('beneficiary'));
    const row = received.body.find((item) => item.id === guestReservation.id);
    assert.equal(row.payment_reference, 'OM240929.1234');
    assert.equal(row.beneficiary_phone, guest.phone);
    assert.equal(row.pickup_code, undefined);

    const confirmed = await api
      .patch(`/api/reservations/${guestReservation.id}/confirm`)
      .set(as('beneficiary'));
    assert.equal(confirmed.status, 200, confirmed.text);
  });

  test("l'invité suit sa réservation avec son jeton, et elle seule", async () => {
    const path = `/api/reservations/guest/${guestReservation.id}`;
    assert.equal((await api.get(path)).status, 404);
    assert.equal((await api.get(path).set('X-Guest-Token', 'mauvais-jeton')).status, 404);

    const res = await api.get(path).set('X-Guest-Token', guestReservation.guest_token);
    assert.equal(res.status, 200);
    assert.equal(res.body.status, 'confirmed');
    assert.equal(res.body.pickup_code, guestReservation.pickup_code);
  });

  test("l'offre d'un invité ne se réserve pas : on appelle son numéro", async () => {
    const withAccount = await api
      .post('/api/reservations')
      .set(as('beneficiary'))
      .send({ offer_id: guestOffer.id, quantity: 1 });
    assert.equal(withAccount.status, 409, withAccount.text);
    assert.equal(withAccount.body.details.code, 'guest_offer_call');
    assert.equal(withAccount.body.details.phone, guest.phone);

    const asGuest = await api
      .post('/api/reservations')
      .send({ offer_id: guestOffer.id, quantity: 1, guest: { ...guest, phone: '+226 70 11 22 33' } });
    assert.equal(asGuest.status, 409, asGuest.text);
    assert.equal(asGuest.body.details.code, 'guest_offer_call');

    const offer = await api.get(`/api/offers/${guestOffer.id}`);
    assert.equal(offer.body.quantity_available, guestOffer.quantity_available);
  });

  test("l'invité annule sa réservation avec son jeton ; la quantité est rendue", async () => {
    const path = `/api/reservations/${guestReservation.id}/cancel`;
    assert.equal((await api.patch(path)).status, 404);

    const res = await api.patch(path).set('X-Guest-Token', guestReservation.guest_token);
    assert.equal(res.status, 200, res.text);
    assert.equal(res.body.status, 'cancelled');

    const offer = await api.get(`/api/offers/${paidOffer.id}`);
    assert.equal(offer.body.quantity_available, paidOffer.quantity_available);
  });

  test("l'invité retire son offre avec son jeton, personne d'autre", async () => {
    const path = `/api/offers/${guestOffer.id}`;
    assert.equal((await api.delete(path)).status, 403);
    assert.equal((await api.delete(path).set(as('donor'))).status, 403);

    const res = await api.delete(path).set('X-Guest-Token', guestOffer.guest_token);
    assert.equal(res.status, 204);
  });

  test("l'administrateur ne publie pas", async () => {
    const res = await api.post('/api/offers').set(as('admin')).send(offerBody());
    assert.equal(res.status, 403);
  });
  test('quota sans compte réglé par l’administrateur', async () => {
    const settings = await api.get('/api/admin/settings').set(as('admin'));
    assert.equal(settings.status, 200);
    assert.deepEqual(settings.body, {
      guest_offer_max: 10,
      guest_offer_window_hours: 1,
      guest_reservation_max: 20,
      guest_reservation_window_hours: 1,
    });

    const invalid = await api
      .put('/api/admin/settings')
      .set(as('admin'))
      .send({ guest_offer_max: -1 });
    assert.equal(invalid.status, 400);
    const unknown = await api.put('/api/admin/settings').set(as('admin')).send({ autre: 1 });
    assert.equal(unknown.status, 400);
    const forbidden = await api.put('/api/admin/settings').set(as('donor')).send({});
    assert.equal(forbidden.status, 403);

    // Des publications sans compte ont déjà été faites depuis cette adresse.
    const saved = await api
      .put('/api/admin/settings')
      .set(as('admin'))
      .send({ guest_offer_max: 1, guest_offer_window_hours: 24 });
    assert.equal(saved.status, 200, saved.text);
    assert.equal(saved.body.guest_offer_max, 1);
    assert.equal(saved.body.guest_reservation_max, 20);

    const limited = await api
      .post('/api/offers')
      .send(offerBody({ guest: { ...guest, phone: '+226 70 99 88 77' } }));
    assert.equal(limited.status, 429, limited.text);
    assert.equal(limited.body.details.code, 'guest_limit');
    assert.match(limited.body.error, /1 publication sans compte par jour/);

    // Avec un compte : pas de quota.
    const withAccount = await api.post('/api/offers').set(as('donor')).send(offerBody());
    assert.equal(withAccount.status, 201, withAccount.text);

    await api.put('/api/admin/settings').set(as('admin')).send({ guest_offer_max: 0 });
    const disabled = await api.post('/api/offers').send(offerBody({ guest }));
    assert.equal(disabled.status, 403);
    assert.equal(disabled.body.details.code, 'guest_disabled');

    const sync = await api.get('/api/sync').set(as('admin'));
    assert.equal(sync.body.admin.settings.guest_offer_max, 0);

    await api
      .put('/api/admin/settings')
      .set(as('admin'))
      .send({ guest_offer_max: 10, guest_offer_window_hours: 1 });
  });
});

describe('mode hors ligne', () => {
  /** Rejoue une requête comme la file d'attente de l'app (503 = premier envoi pas fini). */
  async function replay(send) {
    for (let attempt = 0; attempt < 20; attempt += 1) {
      const res = await send();
      if (res.status !== 503) return res;
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    throw new Error('toujours en cours');
  }

  test("une réservation rejouée avec la même Idempotency-Key n'est appliquée qu'une fois", async () => {
    const offers = (await api.get('/api/offers?limit=100')).body;
    const offer = offers.find((o) => o.title === 'Pains et viennoiseries du jour');
    const key = 'reservation-test-0001';

    const send = () =>
      api
        .post('/api/reservations')
        .set(as('beneficiary'))
        .set('Idempotency-Key', key)
        .send({ offer_id: offer.id, quantity: 3 });

    const first = await send();
    assert.equal(first.status, 201, first.text);

    const second = await replay(send);
    assert.equal(second.status, 201);
    assert.equal(second.headers['idempotent-replayed'], 'true');
    assert.equal(second.body.id, first.body.id);

    const after = await api.get(`/api/offers/${offer.id}`);
    assert.equal(after.body.quantity_available, offer.quantity_available - 3);
  });

  test('un refus est lui aussi rejoué à l’identique', async () => {
    const send = () =>
      api
        .post('/api/reservations')
        .set(as('beneficiary'))
        .set('Idempotency-Key', 'reservation-test-0002')
        .send({ offer_id: 999999, quantity: 1 });

    assert.equal((await send()).status, 409);
    const again = await replay(send);
    assert.equal(again.status, 409);
    assert.equal(again.headers['idempotent-replayed'], 'true');
  });

  test('la même clé sur une autre route est refusée', async () => {
    const res = await api
      .patch('/api/notifications/read-all')
      .set(as('beneficiary'))
      .set('Idempotency-Key', 'reservation-test-0001');
    assert.equal(res.status, 422);
  });

  test('GET /api/sync renvoie tout le nécessaire en une requête', async () => {
    const beneficiary = await api.get('/api/sync').set(as('beneficiary'));
    assert.equal(beneficiary.status, 200);
    for (const key of ['profile', 'categories', 'offers', 'reservations', 'notifications', 'impact']) {
      assert.ok(key in beneficiary.body, key);
    }
    assert.ok(beneficiary.body.reservations.every((r) => r.pickup_code));
    assert.equal(beneficiary.body.admin, null);

    const donor = await api.get('/api/sync').set(as('donor'));
    assert.ok(donor.body.my_offers.length > 0);
    assert.ok(donor.body.received.every((r) => r.pickup_code === undefined));

    const admin = await api.get('/api/sync').set(as('admin'));
    assert.ok(Array.isArray(admin.body.admin.moderation_offers));
  });
});

describe('administration', () => {
  test('retrait d’une offre abusive : notifiée, e-mail si laissé', async () => {
    const [category] = (await api.get('/api/categories')).body;
    const body = {
      category_id: category.id,
      title: 'Offre abusive',
      quantity: 1,
      expiry_date: tomorrow(),
      pickup_start: futureIso(-1),
      pickup_end: futureIso(5),
      address: '1 rue du Test',
      latitude: 12.3714,
      longitude: -1.5197,
    };
    const withEmail = await api
      .post('/api/offers')
      .set(as('donor'))
      .send({ ...body, contact_email: 'contact@test.local' });
    const withoutEmail = await api
      .post('/api/offers')
      .send({ ...body, guest: { first_name: 'Ali', last_name: 'Ouédraogo', phone: '+226 70 55 44 33' } });
    assert.equal(withoutEmail.status, 201, withoutEmail.text);

    const before = sentMails.length;
    const res = await api
      .patch(`/api/admin/offers/${withEmail.body.id}/moderation`)
      .set(as('admin'))
      .send({ decision: 'reject', reason: 'Contenu trompeur' });
    assert.equal(res.status, 200, res.text);
    assert.equal(res.body.status, 'rejected');
    const mail = sentMails.at(-1);
    assert.equal(mail.to, 'contact@test.local');
    assert.match(mail.text, /Motif : Contenu trompeur/);

    const notifications = await api.get('/api/notifications').set(as('donor'));
    assert.ok(notifications.body.some((item) => item.title === 'Offre retirée'));

    // Invité sans e-mail : retrait sans message.
    const guestRes = await api
      .patch(`/api/admin/offers/${withoutEmail.body.id}/moderation`)
      .set(as('admin'))
      .send({ decision: 'reject', reason: 'Spam' });
    assert.equal(guestRes.status, 200);
    assert.equal(sentMails.length, before + 1);

    // Plus modifiable par le publieur une fois retirée.
    const edit = await api.put(`/api/offers/${withEmail.body.id}`).set(as('donor')).send(body);
    assert.equal(edit.status, 409);
  });

  test('désactivation de compte : connexion refusée, Firebase désactivé', async () => {
    const users = await api.get('/api/admin/users?q=nouveau@test.local').set(as('admin'));
    const [user] = users.body;
    assert.equal(user.actor_label, 'Particulier');

    const noReason = await api
      .patch(`/api/admin/users/${user.id}/status`)
      .set(as('admin'))
      .send({ status: 'suspended' });
    assert.equal(noReason.status, 400);

    const res = await api
      .patch(`/api/admin/users/${user.id}/status`)
      .set(as('admin'))
      .send({ status: 'suspended', reason: 'Test' });
    assert.equal(res.status, 200, res.text);
    assert.deepEqual(firebaseCalls.at(-1), ['disabled', 'uid-nouveau', true]);

    const loginRes = await api
      .post('/api/auth/firebase')
      .send({ id_token: fakeToken('uid-nouveau', 'nouveau@test.local') });
    assert.equal(loginRes.status, 403);
    assert.equal(loginRes.body.details.code, 'account_suspended');

    const reactivated = await api
      .patch(`/api/admin/users/${user.id}/status`)
      .set(as('admin'))
      .send({ status: 'active' });
    assert.equal(reactivated.status, 200);
    assert.deepEqual(firebaseCalls.at(-1), ['disabled', 'uid-nouveau', false]);
  });

  test('ajout d’un utilisateur : actif d’emblée, connexion possible', async () => {
    const actors = await api.get('/api/admin/actors').set(as('admin'));
    const particulier = actors.body.find((actor) => actor.label === 'Particulier');
    const admin = actors.body.find((actor) => actor.permission_role === 'admin');
    const account = {
      first_name: 'Awa',
      last_name: 'Traoré',
      email: 'awa.ajout@test.local',
      phone: '+226 70 00 00 00',
      actor_id: particulier.id,
      password: 'Provisoire1',
    };

    const res = await api.post('/api/admin/users').set(as('admin')).send(account);
    assert.equal(res.status, 201, res.text);
    assert.equal(res.body.status, 'active');
    assert.equal(res.body.actor_label, 'Particulier');
    assert.equal(res.body.password_hash, undefined);
    assert.deepEqual(firebaseCalls.at(-1), ['created', 'awa.ajout@test.local']);

    const login = await api
      .post('/api/auth/login')
      .send({ email: account.email, password: account.password });
    assert.equal(login.status, 200, login.text);

    const again = await api.post('/api/admin/users').set(as('admin')).send(account);
    assert.equal(again.status, 409);
    assert.equal(again.body.details.code, 'email_taken');

    // Administrateur : possible ; association : elle s'inscrit elle-même.
    const asAdmin = await api
      .post('/api/admin/users')
      .set(as('admin'))
      .send({ ...account, email: 'autre.admin@test.local', actor_id: admin.id });
    assert.equal(asAdmin.status, 201, asAdmin.text);
    assert.equal(asAdmin.body.role, 'admin');
    const association = actors.body.find(
      (actor) => actor.permission_role === 'association',
    );
    const asAssociation = await api
      .post('/api/admin/users')
      .set(as('admin'))
      .send({ ...account, email: 'asso.ajout@test.local', actor_id: association.id });
    assert.equal(asAssociation.status, 400);

    const notAdmin = await api.post('/api/admin/users').set(as('donor')).send(account);
    assert.equal(notAdmin.status, 403);

    // Copié dans l'instantané de l'administrateur, pour l'écran hors ligne.
    const sync = await api.get('/api/sync').set(as('admin'));
    assert.ok(sync.body.admin.users.some((user) => user.email === account.email));
    assert.ok(sync.body.admin.users.every((user) => user.password_hash === undefined));
  });

  test('MySQL indisponible : comptes lus dans la copie Firestore', async () => {
    await api.get('/api/admin/users').set(as('admin'));
    firestoreMirror.changed();
    await flushFirestoreMirror();

    const realQuery = pool.query;
    pool.query = async () => {
      throw Object.assign(new Error('connect ECONNREFUSED'), { code: 'ECONNREFUSED' });
    };
    try {
      const res = await api.get('/api/admin/users?q=awa.ajout').set(as('admin'));
      assert.equal(res.status, 200, res.text);
      assert.equal(res.headers['x-data-source'], 'firestore');
      assert.equal(res.body.length, 1);
      assert.equal(res.body[0].actor_label, 'Particulier');
      assert.equal(res.body[0].password_hash, undefined);
      assert.equal(typeof res.body[0].created_at, 'string');
    } finally {
      pool.query = realQuery;
    }
  });

  test('réservations, impact et compteurs de la plateforme pour l’admin', async () => {
    const reservations = await api.get('/api/admin/reservations').set(as('admin'));
    assert.equal(reservations.status, 200, reservations.text);
    assert.ok(reservations.body.length > 0);
    assert.ok(reservations.body.every((row) => row.pickup_code === undefined));

    const pickedUp = await api
      .get('/api/admin/reservations?status=picked_up')
      .set(as('admin'));
    assert.ok(pickedUp.body.every((row) => row.status === 'picked_up'));

    const impact = await api.get('/api/admin/impact').set(as('admin'));
    assert.equal(impact.status, 200);
    assert.equal(impact.body.monthly.length, 12);
    assert.ok(impact.body.impact.pickups >= 1);
    assert.equal(typeof impact.body.impact.users, 'number');

    const stats = await api.get('/api/admin/stats').set(as('admin'));
    assert.equal(typeof stats.body.actors_total, 'number');
    assert.equal(typeof stats.body.reservations_open, 'number');

    assert.equal((await api.get('/api/admin/impact').set(as('donor'))).status, 403);

    // Le tout copié dans l'instantané, pour les écrans hors ligne.
    const sync = await api.get('/api/sync').set(as('admin'));
    assert.equal(sync.body.admin.reservations.length, reservations.body.length);
    assert.ok(sync.body.admin.reservations.every((row) => row.pickup_code === undefined));
    assert.deepEqual(sync.body.admin.impact_global.impact, impact.body.impact);
    assert.deepEqual(sync.body.admin.stats, stats.body);
  });

  test('acteurs : création, modification, protections', async () => {
    const created = await api.post('/api/admin/actors').set(as('admin')).send({
      code: 'Traiteur',
      label: 'Traiteur',
      description: 'Je souhaite publier des produits',
      icon: 'restaurant_menu',
      permission_role: 'donor',
    });
    assert.equal(created.status, 201, created.text);
    assert.equal(created.body.code, 'traiteur');
    assert.equal(created.body.users_count, 0);
    assert.ok((await api.get('/api/actors')).body.some((actor) => actor.code === 'traiteur'));

    const { id: actorId, users_count: _count, created_at: _c, updated_at: _u, ...fields } =
      created.body;
    const hidden = await api
      .put(`/api/admin/actors/${actorId}`)
      .set(as('admin'))
      .send({ ...fields, self_signup: true, active: false });
    assert.equal(hidden.status, 200, hidden.text);
    assert.ok(!(await api.get('/api/actors')).body.some((actor) => actor.code === 'traiteur'));

    const selfAdmin = await api
      .post('/api/admin/actors')
      .set(as('admin'))
      .send({ code: 'super', label: 'Super', permission_role: 'admin', self_signup: true });
    assert.equal(selfAdmin.status, 400);

    const duplicate = await api
      .post('/api/admin/actors')
      .set(as('admin'))
      .send({ code: 'traiteur', label: 'Doublon', permission_role: 'donor' });
    assert.equal(duplicate.status, 409);

    assert.equal((await api.delete(`/api/admin/actors/${actorId}`).set(as('admin'))).status, 204);

    // Un acteur utilisé : ni suppression, ni changement de droits.
    const actors = await api.get('/api/admin/actors').set(as('admin'));
    const particulier = actors.body.find((actor) => actor.code === 'particulier');
    assert.ok(particulier.users_count > 0);
    assert.equal(
      (await api.delete(`/api/admin/actors/${particulier.id}`).set(as('admin'))).status,
      409,
    );
    const promote = await api
      .put(`/api/admin/actors/${particulier.id}`)
      .set(as('admin'))
      .send({
        code: particulier.code,
        label: particulier.label,
        permission_role: 'donor',
        self_signup: true,
        active: true,
      });
    assert.equal(promote.status, 409);
  });

  test('catégories et facteurs : CRUD et suppression protégée', async () => {
    const created = await api
      .post('/api/admin/categories')
      .set(as('admin'))
      .send({ name: 'Surgelés', icon: 'ac_unit' });
    assert.equal(created.status, 201);

    const factor = await api
      .post('/api/admin/factors')
      .set(as('admin'))
      .send({ category_id: created.body.id, co2_kg_per_kg: 2.1 });
    assert.equal(factor.status, 201);

    const updated = await api
      .put(`/api/admin/factors/${factor.body.id}`)
      .set(as('admin'))
      .send({ category_id: created.body.id, co2_kg_per_kg: 2.4, meals_per_kg: 2 });
    assert.equal(updated.body.co2_kg_per_kg, 2.4);

    assert.equal(
      (await api.delete(`/api/admin/categories/${created.body.id}`).set(as('admin'))).status,
      204,
    );

    // Une catégorie utilisée par des offres ne peut pas être supprimée.
    const [used] = (await api.get('/api/categories')).body;
    const refused = await api.delete(`/api/admin/categories/${used.id}`).set(as('admin'));
    assert.equal(refused.status, 409);
  });

  test("les routes admin sont interdites aux autres rôles", async () => {
    const res = await api.get('/api/admin/stats').set(as('donor'));
    assert.equal(res.status, 403);
  });
});

describe('mini chat avec l’administration', () => {
  // PNG 1×1 valide.
  const png =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

  test('réservé aux comptes : sans session, 401', async () => {
    assert.equal((await api.get('/api/messages')).status, 401);
    assert.equal((await api.post('/api/messages').send({ body: 'Bonjour' })).status, 401);
  });

  test('message avec image, réponse de l’admin, lecture', async () => {
    const empty = await api.post('/api/messages').set(as('beneficiary')).send({ body: '  ' });
    assert.equal(empty.status, 400);

    // Pièces jointes : images uniquement.
    const pdf = await api
      .post('/api/messages')
      .set(as('beneficiary'))
      .send({ photos: ['data:application/pdf;base64,JVBERi0xLjQ='] });
    assert.equal(pdf.status, 400);
    const fakePng = await api
      .post('/api/messages')
      .set(as('beneficiary'))
      .send({ photos: ['data:image/png;base64,SGVsbG8gdGhlcmUgZnJpZW5k'] });
    assert.equal(fakePng.status, 400);
    const tooMany = await api
      .post('/api/messages')
      .set(as('beneficiary'))
      .send({ photos: [png, png, png, png] });
    assert.equal(tooMany.status, 400);

    const sent = await api
      .post('/api/messages')
      .set(as('beneficiary'))
      .send({ body: 'Le panier était abîmé', photos: [png] });
    assert.equal(sent.status, 201, sent.text);
    assert.equal(sent.body.photos_count, 1);
    assert.equal(sent.body.from_admin, 0);

    const photo = await api
      .get(`/api/messages/${sent.body.id}/photos/0`)
      .set(as('beneficiary'));
    assert.equal(photo.status, 200);
    assert.equal(photo.headers['content-type'], 'image/png');
    // Un autre utilisateur ne voit ni la conversation ni ses images.
    const stranger = await api
      .get(`/api/messages/${sent.body.id}/photos/0`)
      .set(as('donor'));
    assert.equal(stranger.status, 404);
    const donorList = await api.get('/api/messages').set(as('donor'));
    assert.ok(donorList.body.every((m) => m.id !== sent.body.id));

    // L'admin est notifié, voit la conversation et répond.
    const adminSync = await api.get('/api/sync').set(as('admin'));
    assert.ok(adminSync.body.messages.some((m) => m.id === sent.body.id));
    assert.ok(
      adminSync.body.notifications.some(
        (n) => n.type === 'message' && n.body === 'Le panier était abîmé',
      ),
    );
    const noTarget = await api.post('/api/messages').set(as('admin')).send({ body: 'Bonjour' });
    assert.equal(noTarget.status, 400);
    const reply = await api
      .post('/api/messages')
      .set(as('admin'))
      .send({ user_id: sent.body.user_id, photos: [png] });
    assert.equal(reply.status, 201, reply.text);
    assert.equal(reply.body.from_admin, 1);
    assert.equal(
      (await api.get(`/api/messages/${reply.body.id}/photos/0`).set(as('admin'))).status,
      200,
    );

    const read = await api.patch('/api/messages/read').set(as('admin')).send({
      user_id: sent.body.user_id,
    });
    assert.equal(read.status, 204);

    const userSync = await api.get('/api/sync').set(as('beneficiary'));
    const mine = userSync.body.messages;
    assert.ok(mine.every((m) => m.user_id === sent.body.user_id));
    assert.ok(mine.find((m) => m.id === sent.body.id).read_at);
    assert.equal(mine.find((m) => m.id === reply.body.id).read_at, null);
    assert.ok(
      userSync.body.notifications.some(
        (n) => n.type === 'message' && n.body === '📷 1 image',
      ),
    );
  });
});

describe('messagerie entre utilisateurs (fiche détail)', () => {
  // PNG 1×1 valide.
  const png =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';
  const userId = async (email) => {
    const [[user]] = await pool.query('SELECT id FROM users WHERE email = ?', [email]);
    return user.id;
  };
  const offerOf = async (donorId) => {
    const [[offer]] = await pool.query('SELECT id FROM offers WHERE donor_id = ? LIMIT 1', [
      donorId,
    ]);
    return offer.id;
  };

  test('réservé aux comptes : sans session, 401', async () => {
    assert.equal((await api.get('/api/direct-messages')).status, 401);
    const res = await api.post('/api/direct-messages').send({ recipient_id: 1, body: 'Bonjour' });
    assert.equal(res.status, 401);
  });

  test('bénéficiaire → publieur depuis son offre, réponse, lecture, images', async () => {
    const donorId = await userId('commerce@demo.local');
    const beneficiaryId = await userId('beneficiaire@demo.local');
    const offerId = await offerOf(donorId);

    const sent = await api
      .post('/api/direct-messages')
      .set(as('beneficiary'))
      .send({ recipient_id: donorId, offer_id: offerId, body: 'Reste-t-il du pain ?' });
    assert.equal(sent.status, 201, sent.text);
    assert.equal(sent.body.sender_id, beneficiaryId);
    assert.equal(sent.body.offer_id, offerId);
    assert.ok(sent.body.offer_title);
    assert.equal(sent.body.recipient_actor, 'Commerçant');

    // Le publieur est notifié (push compris), avec de quoi ouvrir l'échange.
    const [[notification]] = await pool.query(
      `SELECT * FROM notifications WHERE user_id = ? AND type = 'direct_message'
       ORDER BY id DESC LIMIT 1`,
      [donorId],
    );
    assert.equal(notification.title, 'Message de Awa Bénéficiaire');
    const data =
      typeof notification.data === 'string' ? JSON.parse(notification.data) : notification.data;
    assert.equal(data.peer_id, beneficiaryId);

    // Réponse sans citer d'offre : la conversation existe déjà.
    const reply = await api
      .post('/api/direct-messages')
      .set(as('donor'))
      .send({ recipient_id: beneficiaryId, body: 'Oui, venez avant 19h', photos: [png] });
    assert.equal(reply.status, 201, reply.text);
    assert.equal(reply.body.photos_count, 1);

    const photo = await api
      .get(`/api/direct-messages/${reply.body.id}/photos/0`)
      .set(as('beneficiary'));
    assert.equal(photo.status, 200);
    assert.equal(photo.headers['content-type'], 'image/png');
    const stranger = await api
      .get(`/api/direct-messages/${reply.body.id}/photos/0`)
      .set(as('association'));
    assert.equal(stranger.status, 404);

    // Copiés sur l'appareil des deux participants, pas sur celui de l'admin.
    const sync = await api.get('/api/sync').set(as('beneficiary'));
    const ids = sync.body.direct_messages.map((m) => m.id);
    assert.ok(ids.includes(sent.body.id) && ids.includes(reply.body.id));
    const adminSync = await api.get('/api/sync').set(as('admin'));
    assert.deepEqual(adminSync.body.direct_messages, []);
    const strangerList = await api.get('/api/direct-messages').set(as('association'));
    assert.ok(strangerList.body.every((m) => m.id !== sent.body.id));

    // Lecture : seuls les messages reçus de ce correspondant.
    const read = await api
      .patch('/api/direct-messages/read')
      .set(as('beneficiary'))
      .send({ peer_id: donorId });
    assert.equal(read.status, 204);
    const thread = await api
      .get(`/api/direct-messages?peer_id=${donorId}`)
      .set(as('beneficiary'));
    const byId = Object.fromEntries(thread.body.map((m) => [m.id, m]));
    assert.ok(byId[reply.body.id].read_at);
    assert.equal(byId[sent.body.id].read_at, null);
  });

  test('refusé : offre d’un autre, administrateur, soi-même, message vide', async () => {
    const donorId = await userId('commerce@demo.local');
    const restaurantOffer = await offerOf(await userId('restaurant@demo.local'));
    const adminId = await userId('admin@demo.local');
    const beneficiaryId = await userId('beneficiaire@demo.local');

    const otherOffer = await api
      .post('/api/direct-messages')
      .set(as('association'))
      .send({ recipient_id: donorId, offer_id: restaurantOffer, body: 'Bonjour' });
    assert.equal(otherOffer.status, 403);
    const toAdmin = await api
      .post('/api/direct-messages')
      .set(as('beneficiary'))
      .send({ recipient_id: adminId, body: 'Bonjour' });
    assert.equal(toAdmin.status, 404);
    const toSelf = await api
      .post('/api/direct-messages')
      .set(as('beneficiary'))
      .send({ recipient_id: beneficiaryId, body: 'Bonjour' });
    assert.equal(toSelf.status, 400);
    const empty = await api
      .post('/api/direct-messages')
      .set(as('beneficiary'))
      .send({ recipient_id: donorId, body: '  ' });
    assert.equal(empty.status, 400);
    // L'administration garde son propre mini chat.
    const fromAdmin = await api
      .post('/api/direct-messages')
      .set(as('admin'))
      .send({ recipient_id: donorId, body: 'Bonjour' });
    assert.equal(fromAdmin.status, 403);
  });
});

describe('e-mails envoyés par Firebase (extension Trigger Email)', () => {
  const firestoreMails = [];
  let purgedBefore = null;

  before(() => {
    config.mail.transport = 'firebase';
    setMailStore({
      async add(document) {
        firestoreMails.push(document);
      },
      async purge(before) {
        purgedBefore = before;
        return 0;
      },
    });
  });

  after(() => {
    config.mail.transport = 'smtp';
    setMailStore(null);
  });

  test('le code d’activation est déposé dans la collection mail', async () => {
    const actors = (await api.get('/api/actors')).body;
    const res = await api.post('/api/auth/register').send({
      email: 'mail.firebase@test.local',
      password: 'motdepasse1',
      first_name: 'Awa',
      last_name: 'Sawadogo',
      gender: 'female',
      age: 30,
      phone: '+226 70 00 00 01',
      actor_id: actors.find((actor) => actor.code === 'particulier').id,
    });
    assert.equal(res.status, 201, res.text);

    const mail = firestoreMails.find((doc) => doc.to === 'mail.firebase@test.local');
    assert.ok(mail, 'aucun document dans la collection mail');
    assert.ok(mail.message.subject.length > 0);
    assert.match(mail.message.text, /\b\d{6}\b/);
    assert.ok(mail.created_at instanceof Date);
  });

  test('les e-mails de plus de 24 h sont retirés de Firestore', async () => {
    const now = new Date('2026-10-02T12:00:00Z');
    await purgeFirebaseMails(now);
    assert.equal(purgedBefore.toISOString(), '2026-10-01T12:00:00.000Z');
  });
});

describe('e-mails envoyés par l’API Brevo', () => {
  const calls = [];
  let status = 201;

  before(() => {
    config.mail.transport = 'brevo';
    config.brevo.apiKey = 'xkeysib-test';
    setMailFetch(async (url, options) => {
      calls.push({ url, headers: options.headers, body: JSON.parse(options.body) });
      return new Response('{}', { status });
    });
  });

  after(() => {
    config.mail.transport = 'smtp';
    config.brevo.apiKey = null;
    setMailFetch(null);
  });

  const register = async (email) => {
    const actors = (await api.get('/api/actors')).body;
    return api.post('/api/auth/register').send({
      email,
      password: 'motdepasse1',
      first_name: 'Awa',
      last_name: 'Sawadogo',
      gender: 'female',
      age: 30,
      phone: '+226 70 00 00 02',
      actor_id: actors.find((actor) => actor.code === 'particulier').id,
    });
  };

  test('le code d’activation part par l’API HTTPS', async () => {
    const res = await register('mail.brevo@test.local');
    assert.equal(res.status, 201, res.text);

    const call = calls.find((item) => item.body.to[0].email === 'mail.brevo@test.local');
    assert.ok(call, 'aucun appel à Brevo');
    assert.equal(call.url, 'https://api.brevo.com/v3/smtp/email');
    assert.equal(call.headers['api-key'], 'xkeysib-test');
    assert.ok(call.body.sender.email.includes('@'));
    assert.match(call.body.textContent, /\b\d{6}\b/);
  });

  test('un refus de Brevo donne un message compréhensible', async () => {
    status = 401;
    try {
      const res = await register('mail.brevo.refus@test.local');
      assert.equal(res.status, 503);
      assert.match(res.body.error, /pas pu être envoyé/);
    } finally {
      status = 201;
    }
  });

  test('adresse « Nom <e-mail> » découpée pour Brevo', () => {
    assert.deepEqual(parseAddress('Partage+ <a@b.fr>'), { name: 'Partage+', email: 'a@b.fr' });
    assert.deepEqual(parseAddress('a@b.fr'), { email: 'a@b.fr' });
  });
});

describe('recherche à la voix (IA ouverte, API compatible OpenAI)', () => {
  const audio = `data:audio/mp4;base64,${Buffer.from('enregistrement factice').toString('base64')}`;
  const calls = [];
  let savedKey;

  before(() => {
    savedKey = config.voiceAi.apiKey;
    config.voiceAi.apiKey = 'gsk_test';
    resetAiRateLimit();
    // Fausse API : retranscription, puis filtrage (avec un id inventé).
    setVoiceFetch(async (url, options) => {
      calls.push({ url, body: options.body });
      if (url.endsWith('/audio/transcriptions')) {
        return Response.json({ text: 'Je veux du riz gras' });
      }
      return Response.json({
        choices: [
          {
            message: {
              content: JSON.stringify({ keep_ids: [riz, 999999], summary: 'Du riz gras' }),
            },
          },
        ],
      });
    });
  });

  after(() => {
    config.voiceAi.apiKey = savedKey;
    setVoiceFetch(null);
  });

  let riz;
  let pain;
  before(async () => {
    const [rows] = await pool.query(
      "SELECT id, title FROM offers WHERE status = 'published' ORDER BY id LIMIT 2",
    );
    [riz, pain] = rows.map((row) => row.id);
  });

  test('audio : retranscrit, puis seules les offres retenues (id vérifiés)', async () => {
    calls.length = 0;
    const res = await api
      .post('/api/recommendations/voice-search')
      .send({ audio, candidates: [{ id: riz, distance_km: 0.4 }, { id: pain }] });
    assert.equal(res.status, 200, res.text);
    assert.equal(res.body.transcript, 'Je veux du riz gras');
    assert.deepEqual(res.body.keep_ids, [riz]);
    assert.equal(res.body.summary, 'Du riz gras');
    assert.equal(res.body.engine, 'Groq');

    assert.ok(calls[0].url.endsWith('/audio/transcriptions'));
    assert.equal(calls[0].body.get('model'), config.voiceAi.sttModel);
    assert.equal(calls[0].body.get('language'), 'fr');
    assert.equal(calls[0].body.get('file').name, 'demande.m4a');
    // Offres relues dans MySQL : titres envoyés au modèle.
    const prompt = JSON.parse(calls[1].body).messages[1].content;
    assert.match(prompt, /Je veux du riz gras/);
    assert.match(prompt, /"titre"/);
  });

  test('texte : pas de retranscription', async () => {
    calls.length = 0;
    const res = await api
      .post('/api/recommendations/voice-search')
      .send({ text: 'riz gras', candidates: [{ id: riz }] });
    assert.equal(res.status, 200, res.text);
    assert.equal(res.body.transcript, 'riz gras');
    assert.equal(calls.length, 1);
    assert.ok(calls[0].url.endsWith('/chat/completions'));
  });

  test('refus : demande vide, audio invalide ; panne : 503 ; sans clé : 503', async () => {
    const empty = await api
      .post('/api/recommendations/voice-search')
      .send({ candidates: [{ id: riz }] });
    assert.equal(empty.status, 400);
    const pdf = await api
      .post('/api/recommendations/voice-search')
      .send({ audio: 'data:application/pdf;base64,JVBERi0=', candidates: [{ id: riz }] });
    assert.equal(pdf.status, 400);

    setVoiceFetch(async () => new Response('quota', { status: 429 }));
    const down = await api
      .post('/api/recommendations/voice-search')
      .send({ text: 'riz', candidates: [{ id: riz }] });
    assert.equal(down.status, 503);
    assert.equal(down.body.details.code, 'voice_ai_unavailable');

    config.voiceAi.apiKey = null;
    const off = await api
      .post('/api/recommendations/voice-search')
      .send({ text: 'riz', candidates: [{ id: riz }] });
    assert.equal(off.status, 503);
    assert.equal(off.body.details.code, 'voice_ai_not_configured');
  });
});

describe('sans Firebase (Windows / Linux) : compte local et IA du serveur', () => {
  const prompts = [];

  before(() => {
    config.rodium.apiKey = 'rd_sk_test';
    resetAiRateLimit();
  });
  after(() => {
    config.rodium.apiKey = null;
    setRodiumFetch(null);
  });

  /** Faux RodiumAI : classe les offres reçues dans l'ordre inverse. */
  function fakeRodium() {
    setRodiumFetch(async (url, options) => {
      const body = JSON.parse(options.body);
      prompts.push(JSON.parse(body.messages[1].content));
      const ids = prompts.at(-1).offres.map((offer) => offer.id).reverse();
      const ranking = [{ id: 999999, reason: 'inventée' }, ...ids.map((id) => ({ id, reason: 'ok' }))];
      return new Response(
        JSON.stringify({ choices: [{ message: { content: JSON.stringify({ ranking }) } }] }),
        { status: 200 },
      );
    });
  }

  test('inscription locale : mot de passe haché dans MySQL, code, puis connexion', async () => {
    const [actor] = (await api.get('/api/actors')).body;
    const payload = {
      email: 'local@test.local',
      password: 'motdepasse1',
      first_name: 'Ali',
      last_name: 'Ouédraogo',
      gender: 'male',
      age: 30,
      phone: '+226 70 11 22 33',
      actor_id: actor.id,
    };
    const created = await api.post('/api/auth/register').send(payload);
    assert.equal(created.status, 201, created.text);
    assert.equal(created.body.user.status, 'pending');
    assert.equal(created.body.user.firebase_uid, null);
    assert.equal(created.body.user.password_hash, undefined);

    const [row] = await pool
      .query('SELECT password_hash FROM users WHERE email = ?', ['local@test.local'])
      .then(([rows]) => rows);
    assert.ok(row.password_hash.startsWith('$2'));

    const pending = await api
      .post('/api/auth/login')
      .send({ email: 'local@test.local', password: 'motdepasse1' });
    assert.equal(pending.status, 403);
    assert.equal(pending.body.details.code, 'account_pending');

    // Même e-mail, autre mot de passe : refusé.
    const other = await api.post('/api/auth/register').send({ ...payload, password: 'autre12345' });
    assert.equal(other.status, 409);

    const code = lastCode('local@test.local');
    const verified = await api
      .post('/api/auth/verify-email')
      .send({ email: 'local@test.local', code });
    assert.equal(verified.status, 200, verified.text);

    const login = await api
      .post('/api/auth/login')
      .send({ email: 'local@test.local', password: 'motdepasse1' });
    assert.equal(login.status, 200, login.text);
    tokens.local = login.body.token;
  });

  test('inscription : ni jeton Firebase ni mot de passe → 400', async () => {
    const res = await api.post('/api/auth/register').send({
      email: 'x@test.local',
      first_name: 'Xx',
      last_name: 'Yy',
      gender: 'male',
      age: 30,
      phone: '+226 70 11 22 33',
      actor_id: 1,
    });
    assert.equal(res.status, 400);
  });

  test('IA non configurée sur le serveur : 503 explicite', async () => {
    config.rodium.apiKey = null;
    const res = await api.post('/api/recommendations/refine').send({ candidates: [{ id: 1 }] });
    assert.equal(res.status, 503);
    assert.equal(res.body.details.code, 'ai_not_configured');
    config.rodium.apiKey = 'rd_sk_test';
  });

  test('affinage : offres relues dans MySQL, id inventés écartés', async () => {
    fakeRodium();
    const offers = (await api.get('/api/offers?limit=3')).body;
    const res = await api
      .post('/api/recommendations/refine')
      .send({
        candidates: [...offers.map((offer) => ({ id: offer.id, local_score: 70 })), { id: 999999 }],
        preferences_text: 'des fruits',
        latitude: 12.3714,
        longitude: -1.5197,
        recent_titles: ['Yaourts nature'],
      });
    assert.equal(res.status, 200, res.text);
    assert.equal(res.body.source, 'server');
    assert.deepEqual(
      res.body.ranking.map((item) => item.id),
      offers.map((offer) => offer.id).reverse(),
    );

    const prompt = prompts.at(-1);
    // Titres et catégories lus dans MySQL, pas envoyés par l'application.
    assert.equal(prompt.offres[0].titre, offers[0].title);
    assert.ok(prompt.offres.every((offer) => offer.distance_km !== null));
    assert.deepEqual(prompt.historique.consultees, ['Yaourts nature']);
  });

  test('connecté : les réservations MySQL alimentent l’historique envoyé à l’IA', async () => {
    fakeRodium();
    const [offer] = (await api.get('/api/offers?limit=1')).body;
    const res = await api
      .post('/api/recommendations/refine')
      .set(as('beneficiary'))
      .send({ candidates: [{ id: offer.id }] });
    assert.equal(res.status, 200, res.text);
    assert.ok(prompts.at(-1).historique.reservees.length > 0);
  });

  test('RodiumAI en panne : 503, jamais d’erreur 500', async () => {
    setRodiumFetch(async () => new Response('panne', { status: 502 }));
    const [offer] = (await api.get('/api/offers?limit=1')).body;
    const res = await api.post('/api/recommendations/refine').send({ candidates: [{ id: offer.id }] });
    assert.equal(res.status, 503);
    assert.equal(res.body.details.code, 'ai_unavailable');
  });

  test('la logique IA du serveur est identique à celle de la Cloud Function', async () => {
    const { readFile } = await import('node:fs/promises');
    const server = await readFile(new URL('../src/services/ai_refine.js', import.meta.url), 'utf8');
    const functions = await readFile(
      new URL('../../functions/src/refine.js', import.meta.url),
      'utf8',
    );
    assert.equal(server.replace(/\r\n/g, '\n'), functions.replace(/\r\n/g, '\n'));
  });
});

describe('push, créneau de retrait, compte désactivé, expiration, connexion', () => {
  const pushes = [];
  const staleToken = `perime-${'p'.repeat(30)}`;
  const deviceToken = `appareil-${'d'.repeat(30)}`;
  let categoryId;
  let donorId;

  const offerBody = (overrides = {}) => ({
    category_id: categoryId,
    title: 'Offre corrections',
    quantity: 3,
    unit: 'portion',
    expiry_date: tomorrow(),
    pickup_start: futureIso(-1),
    pickup_end: futureIso(6),
    address: 'Rue des tests',
    latitude: 12.37,
    longitude: -1.52,
    ...overrides,
  });

  async function publish(overrides) {
    const res = await api.post('/api/offers').set(as('donor2')).send(offerBody(overrides));
    assert.equal(res.status, 201, res.text);
    return res.body;
  }

  async function reserve(offerId, quantity = 1) {
    const res = await api
      .post('/api/reservations')
      .set(as('beneficiary'))
      .send({ offer_id: offerId, quantity });
    assert.equal(res.status, 201, res.text);
    return res.body;
  }

  before(async () => {
    [{ id: categoryId }] = (await api.get('/api/categories')).body;
    setPushSender({
      async send(tokens, message) {
        pushes.push({ tokens, message });
        return tokens.map((token) =>
          token === staleToken ? 'messaging/registration-token-not-registered' : null,
        );
      },
    });

    // Donateur créé pour ce bloc : il sera désactivé puis réactivé.
    const actors = await api.get('/api/admin/actors').set(as('admin'));
    const commercant = actors.body.find((actor) => actor.code === 'commercant');
    const created = await api.post('/api/admin/users').set(as('admin')).send({
      first_name: 'Issa',
      last_name: 'Ouédraogo',
      email: 'donateur.corrections@test.local',
      phone: '+226 70 11 11 11',
      actor_id: commercant.id,
      password: 'Provisoire1',
    });
    assert.equal(created.status, 201, created.text);
    donorId = created.body.id;
    const session = await api
      .post('/api/auth/login')
      .send({ email: 'donateur.corrections@test.local', password: 'Provisoire1' });
    tokens.donor2 = session.body.token;
  });

  after(() => {
    setPushSender(null);
    resetLoginAttempts();
  });

  test('push : jeton enregistré, envoyé après la confirmation, jeton périmé supprimé', async () => {
    for (const token of [deviceToken, staleToken]) {
      const res = await api
        .post('/api/users/me/devices')
        .set(as('beneficiary'))
        .send({ token, platform: 'android' });
      assert.equal(res.status, 204, res.text);
    }

    const offer = await publish({ title: 'Offre push' });
    const reservation = await reserve(offer.id);
    pushes.length = 0;
    const confirm = await api
      .patch(`/api/reservations/${reservation.id}/confirm`)
      .set(as('donor2'));
    assert.equal(confirm.status, 200, confirm.text);

    // Le push part après la transaction : on laisse passer la boucle d'événements.
    await new Promise((resolve) => setTimeout(resolve, 50));
    const sent = pushes.find((push) => push.message.notification.title === 'Réservation confirmée');
    assert.ok(sent, 'push non envoyé');
    assert.ok(sent.tokens.includes(deviceToken));
    assert.equal(sent.message.data.type, 'reservation_confirmed');
    assert.equal(sent.message.data.reservation_id, String(reservation.id));

    const [rows] = await pool.query('SELECT token FROM device_tokens WHERE token = ?', [staleToken]);
    assert.equal(rows.length, 0);

    const removed = await api
      .delete('/api/users/me/devices')
      .set(as('beneficiary'))
      .send({ token: deviceToken });
    assert.equal(removed.status, 204);
  });

  test('retrait refusé avant le créneau ; heure réelle d’une action hors ligne prise en compte', async () => {
    const offer = await publish({
      title: 'Offre créneau',
      pickup_start: futureIso(3),
      pickup_end: futureIso(8),
    });
    const reservation = await reserve(offer.id);
    await api.patch(`/api/reservations/${reservation.id}/confirm`).set(as('donor2'));

    const early = await api
      .post(`/api/reservations/${reservation.id}/pickup`)
      .set(as('donor2'))
      .send({ pickup_code: reservation.pickup_code });
    assert.equal(early.status, 409);
    assert.equal(early.body.details.code, 'pickup_too_early');

    // Validé hors ligne pendant le créneau, envoyé plus tard : accepté.
    await pool.query(
      'UPDATE offers SET pickup_start = NOW() - INTERVAL 5 HOUR, pickup_end = NOW() + INTERVAL 1 HOUR WHERE id = ?',
      [offer.id],
    );
    const actionAt = futureIso(-2);
    const late = await api
      .post(`/api/reservations/${reservation.id}/pickup`)
      .set(as('donor2'))
      .set('X-Action-At', actionAt)
      .send({ pickup_code: reservation.pickup_code });
    assert.equal(late.status, 200, late.text);
    assert.equal(new Date(late.body.picked_up_at).toISOString().slice(0, 16), actionAt.slice(0, 16));
  });

  test('impact : poids non indiqué estimé d’après l’unité', async () => {
    const before = (await api.get('/api/impact/me').set(as('beneficiary'))).body;
    const offer = await publish({ title: 'Riz en vrac', unit: 'kg', quantity: 5 });
    const reservation = await reserve(offer.id, 2);
    await api.patch(`/api/reservations/${reservation.id}/confirm`).set(as('donor2'));
    const pickup = await api
      .post(`/api/reservations/${reservation.id}/pickup`)
      .set(as('donor2'))
      .send({ pickup_code: reservation.pickup_code });
    assert.equal(pickup.status, 200, pickup.text);

    const after = (await api.get('/api/impact/me').set(as('beneficiary'))).body;
    assert.equal(Number((after.food_kg - before.food_kg).toFixed(1)), 2);
    assert.equal(after.estimated_pickups - before.estimated_pickups, 1);
  });

  test('compte désactivé : offres masquées, réservations annulées et notifiées', async () => {
    const offer = await publish({ title: 'Offre donateur suspendu' });
    const reservation = await reserve(offer.id);

    const suspend = await api
      .patch(`/api/admin/users/${donorId}/status`)
      .set(as('admin'))
      .send({ status: 'suspended', reason: 'Test des corrections' });
    assert.equal(suspend.status, 200, suspend.text);

    const listed = await api.get('/api/offers?q=donateur%20suspendu');
    assert.equal(listed.body.length, 0);
    const blocked = await api
      .post('/api/reservations')
      .set(as('beneficiary'))
      .send({ offer_id: offer.id, quantity: 1 });
    assert.equal(blocked.status, 409);

    const mine = await api.get(`/api/reservations/${reservation.id}`).set(as('beneficiary'));
    assert.equal(mine.body.status, 'cancelled');
    const notifications = await api.get('/api/notifications').set(as('beneficiary'));
    assert.ok(notifications.body.some((n) => /compte du donateur a été désactivé/.test(n.body)));

    const reactivate = await api
      .patch(`/api/admin/users/${donorId}/status`)
      .set(as('admin'))
      .send({ status: 'active' });
    assert.equal(reactivate.status, 200);
    const back = await api.get('/api/offers?q=donateur%20suspendu');
    assert.equal(back.body.length, 1);
    assert.equal(back.body[0].quantity_available, 3);

    // Jeton délivré avant la suspension : révoqué, même après la réactivation.
    const stale = await api.get('/api/auth/me').set(as('donor2'));
    assert.equal(stale.status, 401);
    const session = await api
      .post('/api/auth/login')
      .send({ email: 'donateur.corrections@test.local', password: 'Provisoire1' });
    assert.equal(session.status, 200, session.text);
    tokens.donor2 = session.body.token;
  });

  test('expiration : le bénéficiaire est prévenu de l’annulation', async () => {
    const offer = await publish({ title: 'Offre qui expire' });
    const reservation = await reserve(offer.id);
    await pool.query(
      'UPDATE offers SET pickup_start = NOW() - INTERVAL 3 HOUR, pickup_end = NOW() - INTERVAL 1 MINUTE WHERE id = ?',
      [offer.id],
    );

    const jobs = await api.post('/api/jobs/run').set('X-Jobs-Token', 'jeton-de-test');
    assert.equal(jobs.status, 200);
    assert.ok(jobs.body.expired_offers >= 1);

    const notifications = await api.get('/api/notifications').set(as('beneficiary'));
    const expired = notifications.body.find((n) => n.title === 'Réservation expirée');
    assert.ok(expired, 'bénéficiaire non prévenu');
    const data = typeof expired.data === 'string' ? JSON.parse(expired.data) : expired.data;
    assert.equal(data.reservation_id, reservation.id);
  });

  test('connexion : trop d’échecs, blocage temporaire (429)', async () => {
    resetLoginAttempts();
    const email = 'cible.force.brute@test.local';
    for (let i = 0; i < MAX_FAILURES; i += 1) {
      const res = await api.post('/api/auth/login').send({ email, password: `faux${i}` });
      assert.equal(res.status, 401);
    }
    const blocked = await api.post('/api/auth/login').send({ email, password: 'encore' });
    assert.equal(blocked.status, 429);
    assert.equal(blocked.body.details.code, 'too_many_attempts');

    // Les autres comptes ne sont pas bloqués.
    const other = await api
      .post('/api/auth/login')
      .send({ email: 'beneficiaire@demo.local', password: DEMO_PASSWORD });
    assert.equal(other.status, 200);
  });
});

describe('profil, préférences et créneaux de retrait', () => {
  test('photo de profil : ajout, affichage public, remplacement, retrait', async () => {
    const jpeg = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(60)]);
    const photo = `data:image/jpeg;base64,${jpeg.toString('base64')}`;

    const none = await api.get('/api/auth/me').set(as('beneficiary'));
    assert.equal(none.body.photo_path ?? null, null);

    const invalid = await api
      .put('/api/users/me/photo')
      .set(as('beneficiary'))
      .send({ photo: `data:image/png;base64,${Buffer.from('pas une image').toString('base64')}` });
    assert.equal(invalid.status, 400);
    const missing = await api.put('/api/users/me/photo').set(as('beneficiary')).send({});
    assert.equal(missing.status, 400);
    const anonymous = await api.put('/api/users/me/photo').send({ photo });
    assert.equal(anonymous.status, 401);

    const saved = await api.put('/api/users/me/photo').set(as('beneficiary')).send({ photo });
    assert.equal(saved.status, 200, saved.text);
    assert.match(saved.body.photo_path, /^\/users\/\d+\/photo\?v=\d+$/);

    // Servie sans compte (affichée aux autres usagers), au bon format.
    const image = await api.get(`/api${saved.body.photo_path}`);
    assert.equal(image.status, 200);
    assert.equal(image.headers['content-type'], 'image/jpeg');
    assert.deepEqual(image.body, jpeg);

    const removed = await api.delete('/api/users/me/photo').set(as('beneficiary'));
    assert.equal(removed.status, 200);
    assert.equal(removed.body.photo_path, null);
    const gone = await api.get(`/api${saved.body.photo_path}`);
    assert.equal(gone.status, 404);
  });

  const pushes = [];
  let categoryId;

  const slotOffer = (overrides = {}) => ({
    category_id: categoryId,
    title: 'Offre à créneaux',
    quantity: 4,
    unit: 'portion',
    expiry_date: tomorrow(),
    address: 'Place des créneaux',
    latitude: 12.37,
    longitude: -1.52,
    slots: [
      { start: futureIso(5), end: futureIso(7) },
      { start: futureIso(-1), end: futureIso(1) },
    ],
    ...overrides,
  });

  before(async () => {
    [{ id: categoryId }] = (await api.get('/api/categories')).body;
    tokens.beneficiary2 = await login('restaurant@demo.local');
    setPushSender({
      async send(deviceTokens, message) {
        pushes.push({ tokens: deviceTokens, message });
        return deviceTokens.map(() => null);
      },
    });
  });

  after(() => setPushSender(null));

  test('profil : prénom, nom et téléphone modifiés, nom affiché recalculé', async () => {
    const res = await api
      .patch('/api/users/me')
      .set(as('beneficiary'))
      .send({ first_name: 'Aminata', last_name: 'Sawadogo', phone: '+226 71 22 33 44' });
    assert.equal(res.status, 200, res.text);
    assert.equal(res.body.name, 'Aminata Sawadogo');
    assert.equal(res.body.phone, '+226 71 22 33 44');

    const invalid = await api.patch('/api/users/me').set(as('beneficiary')).send({ phone: 'abc' });
    assert.equal(invalid.status, 400);
  });

  test('préférences fusionnées, et push désactivé par l’utilisateur', async () => {
    await api
      .patch('/api/users/me')
      .set(as('beneficiary'))
      .send({ preferences: { reco: { max_distance_km: 5 } } });
    const res = await api
      .patch('/api/users/me')
      .set(as('beneficiary'))
      .send({ preferences: { push_enabled: false } });
    assert.equal(res.status, 200, res.text);
    assert.deepEqual(res.body.preferences, { reco: { max_distance_km: 5 }, push_enabled: false });

    const token = `profil-${'t'.repeat(30)}`;
    await api
      .post('/api/users/me/devices')
      .set(as('beneficiary'))
      .send({ token, platform: 'android' });
    const offer = (
      await api
        .post('/api/offers')
        .set(as('donor2'))
        .send(
          slotOffer({
            title: 'Offre préférences push',
            slots: undefined,
            pickup_start: futureIso(-1),
            pickup_end: futureIso(4),
          }),
        )
    ).body;
    const reservation = await api
      .post('/api/reservations')
      .set(as('beneficiary'))
      .send({ offer_id: offer.id, quantity: 1 });
    assert.equal(reservation.status, 201, reservation.text);

    // Push désactivé : la confirmation reste dans l'application seulement.
    pushes.length = 0;
    await api.patch(`/api/reservations/${reservation.body.id}/confirm`).set(as('donor2'));
    await new Promise((resolve) => setTimeout(resolve, 50));
    assert.ok(pushes.every((push) => !push.tokens.includes(token)));

    // Réactivé (clé supprimée) : l'annulation arrive en push.
    await api
      .patch('/api/users/me')
      .set(as('beneficiary'))
      .send({ preferences: { push_enabled: null } });
    await api.patch(`/api/reservations/${reservation.body.id}/cancel`).set(as('donor2'));
    await new Promise((resolve) => setTimeout(resolve, 50));
    assert.ok(pushes.some((push) => push.tokens.includes(token)));

    const me = await api.get('/api/auth/me').set(as('beneficiary'));
    assert.equal(me.body.preferences.push_enabled, undefined);
    assert.equal(me.body.preferences.reco.max_distance_km, 5);
  });

  test('offre à plusieurs créneaux : période globale et créneaux renvoyés', async () => {
    const res = await api.post('/api/offers').set(as('donor')).send(slotOffer());
    assert.equal(res.status, 201, res.text);
    assert.equal(res.body.slots.length, 2);
    // Période de l'offre : premier début, dernière fin.
    const starts = res.body.slots.map((slot) => Date.parse(slot.start));
    const ends = res.body.slots.map((slot) => Date.parse(slot.end));
    assert.equal(Date.parse(res.body.pickup_start), Math.min(...starts));
    assert.equal(Date.parse(res.body.pickup_end), Math.max(...ends));

    const bad = await api
      .post('/api/offers')
      .set(as('donor'))
      .send(slotOffer({ slots: [{ start: futureIso(3), end: futureIso(2) }] }));
    assert.equal(bad.status, 400);
  });

  test('réservation : créneau obligatoire, enregistré, puis contrôlé au retrait', async () => {
    const offer = (await api.post('/api/offers').set(as('donor')).send(slotOffer())).body;
    const [, later] = [...offer.slots].sort((a, b) => Date.parse(a.start) - Date.parse(b.start));

    const missing = await api
      .post('/api/reservations')
      .set(as('beneficiary'))
      .send({ offer_id: offer.id, quantity: 1 });
    assert.equal(missing.status, 400);
    assert.equal(missing.body.details.code, 'slot_required');

    const res = await api
      .post('/api/reservations')
      .set(as('beneficiary'))
      .send({ offer_id: offer.id, quantity: 1, slot_id: later.id });
    assert.equal(res.status, 201, res.text);
    assert.equal(Date.parse(res.body.pickup_start), Date.parse(later.start));
    assert.equal(Date.parse(res.body.pickup_end), Date.parse(later.end));

    // Créneau choisi dans 5 h : retrait encore trop tôt.
    await api.patch(`/api/reservations/${res.body.id}/confirm`).set(as('donor'));
    const early = await api
      .post(`/api/reservations/${res.body.id}/pickup`)
      .set(as('donor'))
      .send({ pickup_code: res.body.pickup_code });
    assert.equal(early.status, 409);
    assert.equal(early.body.details.code, 'pickup_too_early');
  });

  test('tâches : rappel de confirmation au donateur, créneau manqué annulé', async () => {
    const offer = (await api.post('/api/offers').set(as('donor')).send(slotOffer())).body;
    const [current] = [...offer.slots].sort((a, b) => Date.parse(a.start) - Date.parse(b.start));
    const reservation = await api
      .post('/api/reservations')
      .set(as('beneficiary2'))
      .send({ offer_id: offer.id, quantity: 2, slot_id: current.id });
    assert.equal(reservation.status, 201, reservation.text);

    const first = await api.post('/api/jobs/run').set('X-Jobs-Token', 'jeton-de-test');
    assert.ok(first.body.confirm_reminders >= 1);
    const donorNotifications = await api.get('/api/notifications').set(as('donor'));
    assert.ok(donorNotifications.body.some((n) => n.type === 'confirm_reminder'));

    await pool.query('UPDATE reservations SET slot_end = NOW() - INTERVAL 1 MINUTE WHERE id = ?', [
      reservation.body.id,
    ]);
    const second = await api.post('/api/jobs/run').set('X-Jobs-Token', 'jeton-de-test');
    assert.ok(second.body.missed_slots >= 1);
    const after = (await api.get(`/api/offers/${offer.id}`)).body;
    assert.equal(after.quantity_available, 4);
    const notifications = await api.get('/api/notifications').set(as('beneficiary2'));
    assert.ok(notifications.body.some((n) => n.title === 'Créneau manqué'));
  });
});

describe('indicateurs IA du donateur et indicateurs sociaux de la plateforme', () => {
  let categoryId;
  let riskyOfferId;

  before(async () => {
    [{ id: categoryId }] = (await api.get('/api/categories')).body;
    // Offre payante, rien de réservé, retrait qui se termine bientôt : risque élevé.
    const res = await api.post('/api/offers').set(as('donor')).send({
      category_id: categoryId,
      title: 'Offre à risque',
      quantity: 10,
      unit: 'portion',
      price: 500,
      payment_info: 'Orange Money +226 70 00 00 00',
      expiry_date: tomorrow(),
      pickup_start: futureIso(-2),
      pickup_end: futureIso(3),
      address: 'Rue du risque',
      latitude: 12.37,
      longitude: -1.52,
    });
    assert.equal(res.status, 201, res.text);
    riskyOfferId = res.body.id;
  });

  after(() => {
    config.rodium.apiKey = null;
    setRodiumFetch(null);
  });

  test('risque de gaspillage et suggestions, aussi dans l’instantané hors ligne', async () => {
    const res = await api.get('/api/offers/mine/insights').set(as('donor'));
    assert.equal(res.status, 200, res.text);
    const risky = res.body.find((insight) => insight.offer_id === riskyOfferId);
    assert.ok(risky, 'offre absente des indicateurs');
    assert.ok(risky.risk >= 60, `risque attendu élevé : ${risky.risk}`);
    assert.equal(risky.level, 'high');
    assert.ok(risky.suggestions.some((s) => /prix/.test(s)));
    assert.ok(risky.suggestions.some((s) => /créneau/.test(s)));

    const sync = await api.get('/api/sync').set(as('donor'));
    assert.ok(sync.body.offer_insights.some((insight) => insight.offer_id === riskyOfferId));
  });

  test('conseil : par règles sans IA, rédigé par l’IA sinon', async () => {
    config.rodium.apiKey = null;
    const rules = await api.post('/api/recommendations/advice').set(as('donor'));
    assert.equal(rules.status, 200, rules.text);
    assert.equal(rules.body.source, 'rules');
    assert.match(rules.body.advice, /risque de gaspillage/);

    config.rodium.apiKey = 'rd_sk_test';
    resetAiRateLimit();
    let prompt;
    setRodiumFetch(async (url, options) => {
      prompt = JSON.parse(JSON.parse(options.body).messages[1].content);
      return new Response(
        JSON.stringify({ choices: [{ message: { content: 'Baissez le prix de l’offre à risque.' } }] }),
        { status: 200 },
      );
    });
    const ai = await api.post('/api/recommendations/advice').set(as('donor'));
    assert.equal(ai.body.source, 'ai');
    assert.equal(ai.body.advice, 'Baissez le prix de l’offre à risque.');
    assert.ok(prompt.offres.some((offer) => offer.titre === 'Offre à risque'));

    // IA en panne : conseil par règles, jamais d'erreur.
    setRodiumFetch(async () => new Response('panne', { status: 502 }));
    const down = await api.post('/api/recommendations/advice').set(as('donor'));
    assert.equal(down.status, 200);
    assert.equal(down.body.source, 'rules');
  });

  test('publication express : brouillon d’offre réservé aux restaurateurs', async () => {
    const restaurant = { Authorization: `Bearer ${await login('restaurant@demo.local')}` };
    const text = 'Il me reste 5 plats de riz gras, gratuit, à prendre avant 20h';
    config.rodium.apiKey = 'rd_sk_test';
    resetAiRateLimit();

    // Commerçant : refusé, même avec l'IA configurée.
    const shop = await api.post('/api/recommendations/offer-draft').set(as('donor')).send({ text });
    assert.equal(shop.status, 403, shop.text);

    let prompt;
    setRodiumFetch(async (url, options) => {
      prompt = JSON.parse(JSON.parse(options.body).messages[1].content);
      const draft = {
        title: 'Riz gras',
        category_id: categoryId,
        description: 'Riz gras du jour.',
        quantity: 5,
        unit: 'plat',
        weight_kg: 'inconnu',
        price: 0,
        expiry_in_days: 0,
        pickup_start: null,
        pickup_end: '20:00',
      };
      return new Response(
        JSON.stringify({ choices: [{ message: { content: '```json\n' + JSON.stringify(draft) + '\n```' } }] }),
        { status: 200 },
      );
    });
    const ok = await api
      .post('/api/recommendations/offer-draft')
      .set(restaurant)
      .send({ text, local_time: '17:30' });
    assert.equal(ok.status, 200, ok.text);
    assert.equal(ok.body.source, 'ai');
    assert.deepEqual(
      ok.body.draft,
      {
        title: 'Riz gras',
        category_id: categoryId,
        description: 'Riz gras du jour.',
        quantity: 5,
        unit: 'plat',
        weight_kg: null,
        price: 0,
        expiry_in_days: 0,
        pickup_start: null,
        pickup_end: '20:00',
      },
    );
    assert.equal(prompt.heure_locale, '17:30');
    assert.ok(prompt.categories.some((category) => category.id === categoryId));

    // Catégorie inventée par le modèle : écartée, le reste est gardé.
    setRodiumFetch(async () =>
      new Response(
        JSON.stringify({
          choices: [{ message: { content: JSON.stringify({ title: 'Pains', category_id: 99999, quantity: 0 }) } }],
        }),
        { status: 200 },
      ),
    );
    const invented = await api.post('/api/recommendations/offer-draft').set(restaurant).send({ text });
    assert.equal(invented.status, 200, invented.text);
    assert.equal(invented.body.draft.category_id, null);
    assert.equal(invented.body.draft.quantity, null);

    // IA en panne : 503 explicite, le formulaire classique reste utilisable.
    setRodiumFetch(async () => new Response('panne', { status: 502 }));
    const down = await api.post('/api/recommendations/offer-draft').set(restaurant).send({ text });
    assert.equal(down.status, 503);
    assert.equal(down.body.details.code, 'ai_unavailable');

    config.rodium.apiKey = null;
    const off = await api.post('/api/recommendations/offer-draft').set(restaurant).send({ text });
    assert.equal(off.status, 503);
    assert.equal(off.body.details.code, 'ai_not_configured');
  });

  test('impact de la plateforme : indicateurs sociaux', async () => {
    const res = await api.get('/api/admin/impact').set(as('admin'));
    assert.equal(res.status, 200, res.text);
    const { social } = res.body;
    assert.ok(social.people_helped >= 1);
    assert.ok(social.active_donors >= 1);
    assert.ok(social.offers_shared >= 1);
    assert.ok(social.free_share >= 0 && social.free_share <= 100);
    assert.ok(social.completion_rate >= 0 && social.completion_rate <= 100);
  });
});

describe('inscription bloquée par un compte Firebase orphelin', () => {
  const minutesAgo = (minutes) => new Date(Date.now() - minutes * 60_000);

  before(() => resetLoginAttempts());
  after(() => {
    firebaseUsers.clear();
    resetLoginAttempts();
  });

  test('compte sans profil, créé il y a plus de 10 min : libéré', async () => {
    firebaseUsers.set('orphelin@test.local', { uid: 'uid-orphelin', createdAt: minutesAgo(60) });
    const res = await api.post('/api/auth/release-orphan').send({ email: 'orphelin@test.local' });
    assert.equal(res.status, 204);
    assert.equal(firebaseUsers.has('orphelin@test.local'), false);
    assert.deepEqual(firebaseCalls.at(-1), ['deleted', 'uid-orphelin']);
  });

  test('inscription en cours (moins de 10 min) : conservé', async () => {
    firebaseUsers.set('recent@test.local', { uid: 'uid-recent', createdAt: minutesAgo(2) });
    const res = await api.post('/api/auth/release-orphan').send({ email: 'recent@test.local' });
    assert.equal(res.status, 204);
    assert.equal(firebaseUsers.has('recent@test.local'), true);
  });

  test('profil existant (par e-mail ou par compte Firebase) : jamais supprimé', async () => {
    // Adresse d'un compte MySQL.
    firebaseUsers.set('beneficiaire@demo.local', { uid: 'uid-demo', createdAt: minutesAgo(600) });
    await api.post('/api/auth/release-orphan').send({ email: 'beneficiaire@demo.local' });
    assert.equal(firebaseUsers.has('beneficiaire@demo.local'), true);

    // Compte Firebase rattaché à un profil sous une autre adresse.
    const [{ firebase_uid: uid }] = (
      await pool.query('SELECT firebase_uid FROM users WHERE firebase_uid IS NOT NULL LIMIT 1')
    )[0];
    firebaseUsers.set('autre.adresse@test.local', { uid, createdAt: minutesAgo(600) });
    await api.post('/api/auth/release-orphan').send({ email: 'autre.adresse@test.local' });
    assert.equal(firebaseUsers.has('autre.adresse@test.local'), true);
  });

  test('adresse inconnue : 204 (ne révèle rien), essais limités', async () => {
    resetLoginAttempts();
    for (let i = 0; i < MAX_FAILURES; i += 1) {
      const res = await api.post('/api/auth/release-orphan').send({ email: 'inconnu@test.local' });
      assert.equal(res.status, 204);
    }
    const blocked = await api.post('/api/auth/release-orphan').send({ email: 'inconnu@test.local' });
    assert.equal(blocked.status, 429);
  });
});

describe('modification sans compte et créneaux d’une offre réservée', () => {
  let categoryId;

  const body = (overrides = {}) => ({
    category_id: categoryId,
    title: 'Offre à modifier',
    quantity: 4,
    unit: 'portion',
    expiry_date: tomorrow(),
    pickup_start: futureIso(1),
    pickup_end: futureIso(5),
    address: 'Rue des créneaux',
    latitude: 12.37,
    longitude: -1.52,
    ...overrides,
  });

  before(async () => {
    [{ id: categoryId }] = (await api.get('/api/categories')).body;
    resetLoginAttempts();
  });

  test('offre publiée sans compte : modifiable avec son jeton seulement', async () => {
    const guest = { first_name: 'Issa', last_name: 'Kaboré', phone: '+226 75 44 33 22' };
    const created = await api.post('/api/offers').send({ ...body({ title: 'Offre invité' }), guest });
    assert.equal(created.status, 201, created.text);

    const anonymous = await api.put(`/api/offers/${created.body.id}`).send(body({ title: 'Pirate' }));
    assert.equal(anonymous.status, 403);
    const other = await api
      .put(`/api/offers/${created.body.id}`)
      .set(as('donor'))
      .send(body({ title: 'Pirate' }));
    assert.equal(other.status, 403);

    const res = await api
      .put(`/api/offers/${created.body.id}`)
      .set('X-Guest-Token', created.body.guest_token)
      .send(body({ title: 'Offre invité modifiée', quantity: 6 }));
    assert.equal(res.status, 200, res.text);
    assert.equal(res.body.title, 'Offre invité modifiée');
    assert.equal(res.body.quantity_available, 6);
    // Identité de l'invité conservée.
    assert.equal(res.body.guest_phone, guest.phone);
  });

  test('créneau réservé déplacé : réservation suivie et bénéficiaire prévenu', async () => {
    const offer = (
      await api
        .post('/api/offers')
        .set(as('donor'))
        .send(
          body({
            title: 'Offre créneaux réservés',
            slots: [
              { start: futureIso(1), end: futureIso(3) },
              { start: futureIso(6), end: futureIso(8) },
            ],
          }),
        )
    ).body;
    const [first, second] = [...offer.slots].sort((a, b) => Date.parse(a.start) - Date.parse(b.start));
    const reservation = await api
      .post('/api/reservations')
      .set(as('beneficiary'))
      .send({ offer_id: offer.id, quantity: 1, slot_id: second.id });
    assert.equal(reservation.status, 201, reservation.text);

    // Le créneau réservé ne peut pas être supprimé.
    const removal = await api
      .patch(`/api/offers/${offer.id}/slots`)
      .set(as('donor'))
      .send({ slots: [{ id: first.id, start: first.start, end: first.end }] });
    assert.equal(removal.status, 409);
    assert.equal(removal.body.details.code, 'slot_reserved');

    // Déplacé d'une heure, et un créneau ajouté : accepté malgré la réservation.
    const moved = { start: futureIso(7), end: futureIso(9) };
    const lastEnd = futureIso(12);
    const res = await api
      .patch(`/api/offers/${offer.id}/slots`)
      .set(as('donor'))
      .send({
        slots: [
          { id: first.id, start: first.start, end: first.end },
          { id: second.id, ...moved },
          { start: futureIso(10), end: lastEnd },
        ],
      });
    assert.equal(res.status, 200, res.text);
    assert.equal(res.body.slots.length, 3);
    // Période de l'offre étendue à la fin du nouveau créneau.
    assert.ok(Math.abs(Date.parse(res.body.pickup_end) - Date.parse(lastEnd)) < 1000);

    const mine = await api.get(`/api/reservations/${reservation.body.id}`).set(as('beneficiary'));
    assert.ok(Math.abs(Date.parse(mine.body.pickup_start) - Date.parse(moved.start)) < 1000);
    const notifications = await api.get('/api/notifications').set(as('beneficiary'));
    assert.ok(notifications.body.some((n) => n.type === 'slot_changed'));

    // Seul le publieur modifie ses créneaux.
    const other = await api
      .patch(`/api/offers/${offer.id}/slots`)
      .set(as('beneficiary'))
      .send({ slots: [{ start: futureIso(2), end: futureIso(3) }] });
    assert.equal(other.status, 403);
  });

  test('créneaux d’une offre sans compte, avec son jeton', async () => {
    const guest = { first_name: 'Awa', last_name: 'Zongo', phone: '+226 76 55 44 33' };
    const created = (
      await api.post('/api/offers').send({ ...body({ title: 'Créneaux invité' }), guest })
    ).body;
    const res = await api
      .patch(`/api/offers/${created.id}/slots`)
      .set('X-Guest-Token', created.guest_token)
      .send({ slots: [{ start: futureIso(2), end: futureIso(4) }] });
    assert.equal(res.status, 200, res.text);
    assert.equal(res.body.slots.length, 1);

    const past = await api
      .patch(`/api/offers/${created.id}/slots`)
      .set('X-Guest-Token', created.guest_token)
      .send({ slots: [{ start: futureIso(-5), end: futureIso(-4) }] });
    assert.equal(past.status, 400);
  });
});

describe('dates de publication, alertes de recherche, compteurs publics', () => {
  let categoryId;
  const offer = (overrides = {}) => ({
    category_id: categoryId,
    title: 'Pain du soir',
    quantity: 3,
    unit: 'baguette',
    expiry_date: tomorrow(),
    pickup_start: futureIso(1),
    pickup_end: futureIso(3),
    address: 'Boulangerie du marché',
    latitude: 12.37,
    longitude: -1.52,
    ...overrides,
  });

  before(async () => {
    [{ id: categoryId }] = (await api.get('/api/categories')).body;
  });

  test('retrait déjà terminé ou après la date limite : refusé', async () => {
    const past = await api
      .post('/api/offers')
      .set(as('donor'))
      .send(offer({ pickup_start: futureIso(-3), pickup_end: futureIso(-1) }));
    assert.equal(past.status, 400);
    assert.equal(past.body.details.code, 'pickup_in_past');

    const today = new Date().toISOString().slice(0, 10);
    const late = await api
      .post('/api/offers')
      .set(as('donor'))
      .send(offer({ expiry_date: today, pickup_start: futureIso(1), pickup_end: futureIso(30) }));
    assert.equal(late.status, 400);
    assert.equal(late.body.details.code, 'pickup_after_expiry');

    const expired = await api
      .post('/api/offers')
      .set(as('donor'))
      .send(offer({ expiry_date: '2020-01-01' }));
    assert.equal(expired.status, 400);
    assert.equal(expired.body.details.field, 'expiry_date');
  });

  test('recherche enregistrée : le compte est notifié de la nouvelle offre', async () => {
    await api
      .patch('/api/users/me')
      .set(as('beneficiary'))
      .send({
        latitude: 12.371,
        longitude: -1.519,
        preferences: {
          search_alerts: null,
          favorites: { offer_ids: [], searches: [{ name: 'Pain', text: 'pain', radius_km: 5 }] },
        },
      });

    const created = await api.post('/api/offers').set(as('donor')).send(offer());
    assert.equal(created.status, 201, created.text);
    const far = await api
      .post('/api/offers')
      .set(as('donor'))
      .send(offer({ title: 'Pain lointain', latitude: 14, longitude: 2 }));
    assert.equal(far.status, 201, far.text);
    await new Promise((resolve) => setTimeout(resolve, 100));

    const notifications = (await api.get('/api/notifications').set(as('beneficiary'))).body;
    const alerts = notifications.filter((n) => n.type === 'search_match');
    const offerIds = alerts.map((n) => (typeof n.data === 'string' ? JSON.parse(n.data) : n.data).offer_id);
    assert.ok(offerIds.includes(created.body.id));
    assert.ok(!offerIds.includes(far.body.id), 'hors du rayon : pas d’alerte');

    // Alertes coupées dans le profil : plus rien.
    await api
      .patch('/api/users/me')
      .set(as('beneficiary'))
      .send({ preferences: { search_alerts: false } });
    const muted = await api.post('/api/offers').set(as('donor')).send(offer({ title: 'Pain muet' }));
    await new Promise((resolve) => setTimeout(resolve, 100));
    const after = (await api.get('/api/notifications').set(as('beneficiary'))).body;
    assert.ok(
      !after.some(
        (n) =>
          n.type === 'search_match' &&
          (typeof n.data === 'string' ? JSON.parse(n.data) : n.data).offer_id === muted.body.id,
      ),
    );
  });

  test('compteurs de la plateforme dans les instantanés, avec ou sans compte', async () => {
    const guest = await api.get('/api/sync/public');
    assert.equal(typeof guest.body.public_impact.food_kg, 'number');
    assert.equal(typeof guest.body.public_impact.users, 'number');
    const account = await api.get('/api/sync').set(as('beneficiary'));
    assert.deepEqual(account.body.public_impact, guest.body.public_impact);
  });
});

describe('Firebase injoignable, MySQL disponible : rien de bloqué, recopie ensuite', () => {
  const saved = {};
  const imports = [];
  const updates = [];
  const unreachable = () => {
    throw new Error('getaddrinfo ENOTFOUND identitytoolkit.googleapis.com');
  };

  /** Coupe (ou rétablit) Firebase dans le faux Firebase. */
  function firebaseDown(down) {
    for (const name of ['setDisabled', 'markEmailVerified', 'setPassword', 'createUser']) {
      saved[name] ??= fakeFirebase[name];
      fakeFirebase[name] = down ? unreachable : saved[name];
    }
    saved.verifyIdToken ??= fakeFirebase.verifyIdToken;
    fakeFirebase.verifyIdToken = down
      ? () => {
          throw new HttpError(503, 'Firebase momentanément indisponible', {
            code: 'firebase_unavailable',
          });
        }
      : saved.verifyIdToken;
    fakeFirebase.importUser = down ? unreachable : async (account) => imports.push(account);
    fakeFirebase.updateUser = down ? unreachable : async (uid, account) => updates.push([uid, account]);
  }

  const syncState = async (email) =>
    (
      await pool.query(
        'SELECT firebase_uid, firebase_sync_at, firebase_sync_password FROM users WHERE email = ?',
        [email],
      )
    )[0][0];

  before(() => resetLoginAttempts());
  after(() => {
    firebaseDown(false);
    delete fakeFirebase.importUser;
    delete fakeFirebase.updateUser;
  });

  test('connexion Firebase : mot de passe gardé haché, connexion par MySQL pendant la panne', async () => {
    const token = fakeToken('uid-nouveau', 'nouveau@test.local');
    const ok = await api.post('/api/auth/firebase').send({ id_token: token, password: 'Panne2026' });
    assert.equal(ok.status, 200, ok.text);
    assert.equal(ok.body.user.firebase_sync_at, undefined);

    firebaseDown(true);
    const refused = await api.post('/api/auth/firebase').send({ id_token: token });
    assert.equal(refused.status, 503);
    assert.equal(refused.body.details.code, 'firebase_unavailable');

    const fallback = await api
      .post('/api/auth/login')
      .send({ email: 'nouveau@test.local', password: 'Panne2026' });
    assert.equal(fallback.status, 200, fallback.text);
  });

  test('nouveau mot de passe pendant la panne : accepté, recopié dans Firebase ensuite', async () => {
    // Code déjà demandé plus haut : délai d'une minute levé.
    await pool.query(
      "DELETE o FROM email_otps o JOIN users u ON u.id = o.user_id WHERE u.email = 'nouveau@test.local'",
    );
    const forgot = await api.post('/api/auth/password/forgot').send({ email: 'nouveau@test.local' });
    assert.equal(forgot.status, 204, forgot.text);
    const res = await api.post('/api/auth/password/reset').send({
      email: 'nouveau@test.local',
      code: lastCode('nouveau@test.local'),
      password: 'Nouveau2026',
    });
    assert.equal(res.status, 204, res.text);
    const marked = await syncState('nouveau@test.local');
    assert.ok(marked.firebase_sync_at);
    assert.equal(marked.firebase_sync_password, 1);

    const login = await api
      .post('/api/auth/login')
      .send({ email: 'nouveau@test.local', password: 'Nouveau2026' });
    assert.equal(login.status, 200, login.text);

    // Toujours en panne : rien de perdu, nouvel essai plus tard.
    assert.equal(await syncFirebaseAccounts(), 0);
    assert.ok((await syncState('nouveau@test.local')).firebase_sync_at);

    firebaseDown(false);
    assert.ok((await syncFirebaseAccounts()) >= 1);
    const account = imports.find((item) => item.email === 'nouveau@test.local');
    assert.equal(account.uid, 'uid-nouveau');
    assert.ok(account.passwordHash.startsWith('$2'));
    const cleared = await syncState('nouveau@test.local');
    assert.equal(cleared.firebase_sync_at, null);
    assert.equal(cleared.firebase_sync_password, 0);
  });

  test('désactivation pendant la panne : faite dans MySQL, recopiée dans Firebase ensuite', async () => {
    const [{ id }] = (
      await pool.query('SELECT id FROM users WHERE email = ?', ['nouveau@test.local'])
    )[0];
    firebaseDown(true);
    const res = await api
      .patch(`/api/admin/users/${id}/status`)
      .set(as('admin'))
      .send({ status: 'suspended', reason: 'Test de panne' });
    assert.equal(res.status, 200, res.text);
    assert.ok((await syncState('nouveau@test.local')).firebase_sync_at);

    firebaseDown(false);
    await syncFirebaseAccounts();
    // Mot de passe non concerné : seul l'état est mis à jour.
    assert.deepEqual(updates.at(-1), [
      'uid-nouveau',
      {
        email: 'nouveau@test.local',
        displayName: 'Awa Traoré',
        emailVerified: true,
        disabled: true,
      },
    ]);

    await api
      .patch(`/api/admin/users/${id}/status`)
      .set(as('admin'))
      .send({ status: 'active' });
  });

  test('compte créé pendant la panne : recopié dans Firebase une fois activé', async () => {
    firebaseDown(true);
    const [actor] = (await api.get('/api/actors')).body;
    const created = await api.post('/api/auth/register').send({
      email: 'panne@test.local',
      password: 'motdepasse1',
      first_name: 'Ina',
      last_name: 'Sawadogo',
      gender: 'female',
      age: 28,
      phone: '+226 70 99 88 77',
      actor_id: actor.id,
    });
    assert.equal(created.status, 201, created.text);
    assert.ok((await syncState('panne@test.local')).firebase_sync_at);

    // Pas encore activé : pas recopié.
    firebaseDown(false);
    await syncFirebaseAccounts();
    assert.ok(!imports.some((item) => item.email === 'panne@test.local'));

    const verified = await api
      .post('/api/auth/verify-email')
      .send({ email: 'panne@test.local', code: lastCode('panne@test.local') });
    assert.equal(verified.status, 200, verified.text);
    await syncFirebaseAccounts();

    const account = imports.find((item) => item.email === 'panne@test.local');
    assert.ok(account.uid);
    assert.equal(account.emailVerified, true);
    const state = await syncState('panne@test.local');
    assert.equal(state.firebase_uid, account.uid);
    assert.equal(state.firebase_sync_at, null);
  });
});

describe('codes aussi par SMS (téléphone passerelle) et par push', () => {
  const sms = [];
  const pushes = [];
  const signupToken = `signup-device-${'x'.repeat(20)}`;
  let actorId;

  before(async () => {
    actorId = (await api.get('/api/actors')).body.find((actor) => actor.code === 'particulier').id;
    setSmsFetch(async (url, options) => {
      sms.push({ url, auth: options.headers.Authorization, body: JSON.parse(options.body) });
      return new Response('{}', { status: 202 });
    });
    setPushSender({
      async send(tokens, message) {
        pushes.push({ tokens, message });
        return tokens.map(() => null);
      },
    });
    Object.assign(config.sms, {
      provider: 'android-gateway',
      gatewayUrl: 'http://192.168.1.20:8080/message',
      username: 'sms',
      password: 'secret',
      dailyLimit: 10,
    });
    await pool.query('DELETE FROM sms_daily');
  });

  after(() => {
    setSmsFetch(null);
    setPushSender(null);
    config.sms.provider = null;
  });

  test('numéros : indicatif ajouté, formats invalides refusés', () => {
    assert.equal(normalizePhone('70 11 22 33', '+226'), '+22670112233');
    assert.equal(normalizePhone('+226 70 11 22 33'), '+22670112233');
    assert.equal(normalizePhone('0022670112233'), '+22670112233');
    assert.equal(normalizePhone('abc'), null);
    assert.equal(normalizePhone(null), null);
  });

  test('activation : e-mail, SMS et push vers le téléphone de l’inscription', async () => {
    const res = await api.post('/api/auth/register').send({
      email: 'sms.push@test.local',
      password: 'motdepasse1',
      first_name: 'Ali',
      last_name: 'Sawadogo',
      gender: 'male',
      age: 30,
      phone: '70 11 22 33',
      actor_id: actorId,
      device_token: signupToken,
      device_platform: 'android',
    });
    assert.equal(res.status, 201, res.text);
    await flushCodeExtras();
    const code = lastCode('sms.push@test.local');
    assert.ok(code);

    const sent = sms.at(-1);
    assert.equal(sent.url, 'http://192.168.1.20:8080/message');
    assert.equal(sent.auth, `Basic ${Buffer.from('sms:secret').toString('base64')}`);
    assert.deepEqual(sent.body.phoneNumbers, ['+22670112233']);
    assert.match(sent.body.textMessage.text, new RegExp(`Code d'activation : ${code}`));
    // Un seul SMS : moins de 160 caractères, sans apostrophe typographique.
    assert.ok(sent.body.textMessage.text.length <= 160);

    const push = pushes.at(-1);
    assert.deepEqual(push.tokens, [signupToken]);
    assert.equal(push.message.data.type, 'otp_code');
    assert.equal(push.message.data.purpose, 'activation');
    assert.equal(push.message.data.code, code);
  });

  test('mot de passe oublié : push aux appareils du compte, jamais au demandeur', async () => {
    const accountDevice = `beneficiary-device-${'x'.repeat(20)}`;
    const added = await api
      .post('/api/users/me/devices')
      .set(as('beneficiary'))
      .send({ token: accountDevice, platform: 'android' });
    assert.equal(added.status, 204);

    pushes.length = 0;
    const res = await api.post('/api/auth/password/forgot').send({ email: 'beneficiaire@demo.local' });
    assert.equal(res.status, 204);
    await flushCodeExtras();
    const code = lastCode('beneficiaire@demo.local');
    assert.equal(pushes.length, 1);
    assert.ok(pushes[0].tokens.includes(accountDevice));
    assert.equal(pushes[0].message.data.purpose, 'password_reset');
    assert.equal(pushes[0].message.data.code, code);
    assert.match(sms.at(-1).body.textMessage.text, new RegExp(code));

    await api.delete('/api/users/me/devices').set(as('beneficiary')).send({ token: accountDevice });
  });

  test('plafond journalier : au-delà, plus de SMS (l’e-mail part toujours)', async () => {
    await pool.query('DELETE FROM sms_daily');
    config.sms.dailyLimit = 1;
    sms.length = 0;
    for (const email of ['admin@demo.local', 'commerce@demo.local']) {
      const res = await api.post('/api/auth/password/forgot').send({ email });
      assert.equal(res.status, 204);
    }
    await flushCodeExtras();
    assert.equal(sms.length, 1);
    assert.ok(sentMails.some((mail) => mail.to === 'commerce@demo.local'));
    config.sms.dailyLimit = 10;
  });

  test('passerelle en panne ou SMS désactivé : la demande aboutit quand même', async () => {
    await pool.query('DELETE FROM sms_daily');
    setSmsFetch(async () => new Response('panne', { status: 500 }));
    const down = await api.post('/api/auth/password/forgot').send({ email: 'restaurant@demo.local' });
    assert.equal(down.status, 204);
    await flushCodeExtras();
    // Envoi raté : il ne compte pas dans le plafond.
    const [[day]] = await pool.query('SELECT sent FROM sms_daily WHERE day = CURDATE()');
    assert.equal(day.sent, 0);

    config.sms.provider = null;
    sms.length = 0;
    setSmsFetch(async () => {
      sms.push('envoyé');
      return new Response('{}', { status: 202 });
    });
    const off = await api.post('/api/auth/password/forgot').send({ email: 'association@demo.local' });
    assert.equal(off.status, 204);
    await flushCodeExtras();
    assert.equal(sms.length, 0);
  });
});

describe('sécurité : en-têtes, jetons, limites de débit', () => {
  const { resetRateLimits, WindowCounter } = rateLimitModule;

  test('en-têtes de sécurité, sans X-Powered-By', async () => {
    const res = await api.get('/api/categories');
    assert.equal(res.status, 200);
    assert.equal(res.headers['x-content-type-options'], 'nosniff');
    assert.equal(res.headers['x-frame-options'], 'DENY');
    assert.match(res.headers['content-security-policy'], /default-src 'none'/);
    assert.equal(res.headers['x-powered-by'], undefined);

    const me = await api.get('/api/auth/me').set(as('admin'));
    assert.equal(me.headers['cache-control'], 'no-store');
  });

  test('jeton non signé (alg none) ou signé avec une autre clé : refusé', async () => {
    const { default: jwt } = await import('jsonwebtoken');
    const [[admin]] = await pool.query("SELECT id FROM users WHERE role = 'admin' LIMIT 1");
    const payload = { sub: String(admin.id), role: 'admin', ver: 0 };
    const unsigned = jwt.sign(payload, null, { algorithm: 'none' });
    const forged = jwt.sign(payload, 'autre-secret');
    for (const token of [unsigned, forged]) {
      const res = await api.get('/api/admin/stats').set('Authorization', `Bearer ${token}`);
      assert.equal(res.status, 401);
    }
  });

  test('changement de mot de passe : autres sessions révoquées, nouveau jeton remis', async () => {
    const actors = await api.get('/api/actors');
    const particulier = actors.body.find((actor) => actor.code === 'particulier');
    const created = await api.post('/api/admin/users').set(as('admin')).send({
      first_name: 'Session',
      last_name: 'Revoquee',
      email: 'session.revoquee@test.local',
      actor_id: particulier.id,
      password: 'Ancien1234',
    });
    assert.equal(created.status, 201, created.text);
    const login = (password) =>
      api.post('/api/auth/login').send({ email: 'session.revoquee@test.local', password });
    const first = (await login('Ancien1234')).body.token;
    const second = (await login('Ancien1234')).body.token;

    const changed = await api
      .put('/api/users/me/password')
      .set('Authorization', `Bearer ${first}`)
      .send({ current_password: 'Ancien1234', new_password: 'Nouveau1234' });
    assert.equal(changed.status, 200, changed.text);

    const other = await api.get('/api/auth/me').set('Authorization', `Bearer ${second}`);
    assert.equal(other.status, 401);
    const current = await api
      .get('/api/auth/me')
      .set('Authorization', `Bearer ${changed.body.token}`);
    assert.equal(current.status, 200);
    assert.equal(current.body.token_version, undefined);
    assert.equal((await login('Nouveau1234')).status, 200);
  });

  test('Idempotency-Key trop courte : refusée', async () => {
    const res = await api
      .post('/api/reservations')
      .set('Idempotency-Key', 'court-123')
      .send({});
    assert.equal(res.status, 400);
  });

  test('compteur : bloqué au-delà du maximum, libéré à la fin de la fenêtre', () => {
    const counter = new WindowCounter({ max: 2, windowMs: 1000 });
    assert.equal(counter.hit('a', 0).allowed, true);
    assert.equal(counter.hit('a', 10).allowed, true);
    assert.equal(counter.peek('a', 20).blocked, true);
    assert.equal(counter.hit('a', 30).allowed, false);
    assert.equal(counter.hit('b', 30).allowed, true);
    assert.equal(counter.hit('a', 1001).allowed, true);
  });

  test('routes de codes : 429 au-delà de la limite par adresse IP', async () => {
    config.rateLimit.enabled = true;
    resetRateLimits();
    try {
      let last;
      for (let i = 0; i <= config.rateLimit.authPer15Minutes; i += 1) {
        last = await api.post('/api/auth/password/forgot').send({ email: 'inconnu@test.local' });
      }
      assert.equal(last.status, 429);
      assert.equal(last.body.details.code, 'rate_limited');
      assert.ok(Number(last.headers['retry-after']) > 0);
    } finally {
      config.rateLimit.enabled = false;
      resetRateLimits();
    }
  });
});
