import assert from 'node:assert/strict';
import { after, before, describe, test } from 'node:test';

// Base dédiée, recréée à chaque exécution. Défini avant de charger config.js
// (les valeurs vides empêchent dotenv de reprendre celles du .env).
process.env.NODE_ENV = 'test';
process.env.DATABASE_URL = process.env.TEST_DATABASE_URL ?? '';
process.env.DB_NAME = process.env.TEST_DB_NAME ?? 'repas_partage_test';
process.env.JOBS_TOKEN = 'jeton-de-test';

const { default: request } = await import('supertest');
const { app } = await import('../src/app.js');
const { migrate } = await import('../src/db/migrate.js');
const { pool } = await import('../src/db/pool.js');
const { DEMO_PASSWORD, seed } = await import('../src/db/seed.js');
const { setFirebaseGateway } = await import('../src/services/firebase.js');
const { purgeFirebaseMails, sentMails, setMailStore } = await import(
  '../src/services/mailer.js'
);
const { flushFirestoreMirror, setFirestoreStore } = await import(
  '../src/services/firestore_mirror.js'
);
const { config } = await import('../src/config.js');
const { setRodiumFetch, resetAiRateLimit } = await import('../src/routes/ai.js');
const { HttpError } = await import('../src/http/errors.js');
const { fillMonths, MONTHS } = await import('../src/routes/impact.js');
const { isDatabaseUnavailable } = await import('../src/db/pool.js');

// Faux Firebase : un jeton « fake:<uid>:<email>:… » est accepté tel quel.
const firebaseCalls = [];
setFirebaseGateway({
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
});

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
  tokens.pendingAssociation = await login('association2@demo.local');
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
      ['commercant', 'particulier', 'restaurateur'],
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
});

describe('parcours offre → réservation → retrait', () => {
  let offerId;
  let reservationId;
  let pickupCode;

  test('le donateur publie une offre, en attente de modération', async () => {
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
      });
    assert.equal(res.status, 201, res.text);
    assert.equal(res.body.status, 'pending');
    offerId = res.body.id;

    const list = await api.get('/api/offers?limit=100');
    assert.ok(!list.body.some((offer) => offer.id === offerId));
  });

  test('une offre incomplète est refusée', async () => {
    const res = await api.post('/api/offers').set(as('beneficiary')).send({});
    assert.equal(res.status, 400);
  });

  test("l'admin valide l'offre, qui apparaît à proximité", async () => {
    const pending = await api.get('/api/admin/offers').set(as('admin'));
    assert.ok(pending.body.some((offer) => offer.id === offerId));

    const res = await api
      .patch(`/api/admin/offers/${offerId}/moderation`)
      .set(as('admin'))
      .send({ decision: 'approve' });
    assert.equal(res.status, 200, res.text);
    assert.equal(res.body.status, 'published');

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

  test('une association non validée ne peut pas réserver', async () => {
    const res = await api
      .post('/api/reservations')
      .set(as('pendingAssociation'))
      .send({ offer_id: offerId, quantity: 1 });
    assert.equal(res.status, 403);
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

  async function approve(offerId) {
    const res = await api
      .patch(`/api/admin/offers/${offerId}/moderation`)
      .set(as('admin'))
      .send({ decision: 'approve' });
    assert.equal(res.status, 200, res.text);
  }

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
    assert.equal(doc.status, 'pending');
    assert.equal(doc.quantity_available, 4);

    // La modération est répercutée sur la copie.
    await approve(res.body.id);
    await flushFirestoreMirror();
    assert.equal(firestoreCollection('offers').get(res.body.id).status, 'published');
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
    assert.equal(res.body.status, 'pending');
    assert.equal(res.body.donor_id, null);
    assert.equal(res.body.is_guest, 1);
    assert.equal(res.body.donor_name, 'Moussa Kaboré');
    assert.equal(res.body.publisher_type, 'invite');
    assert.equal(res.body.contact_phone, guest.phone);
    assert.ok(res.body.guest_token.length > 20);
    guestOffer = res.body;

    // Offre en modération : visible par son auteur (jeton), pas par les autres.
    assert.equal((await api.get(`/api/offers/${guestOffer.id}`)).status, 404);
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
    await approve(paidOffer.id);
    await approve(guestOffer.id);
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

  test("réserver l'offre d'un invité : confirmée d'office, téléphone du publieur donné", async () => {
    const res = await api
      .post('/api/reservations')
      .set(as('beneficiary'))
      .send({ offer_id: guestOffer.id, quantity: 1 });
    assert.equal(res.status, 201, res.text);
    assert.equal(res.body.status, 'confirmed');
    assert.equal(res.body.is_guest_offer, 1);
    assert.equal(res.body.donor_phone, guest.phone);
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
    assert.ok(Array.isArray(admin.body.admin.pending_offers));
  });
});

describe('administration', () => {
  test("validation d'une association", async () => {
    const pending = await api.get('/api/admin/associations').set(as('admin'));
    assert.equal(pending.status, 200);
    const [association] = pending.body;

    const res = await api
      .patch(`/api/admin/associations/${association.id}/review`)
      .set(as('admin'))
      .send({ decision: 'approve' });
    assert.equal(res.status, 200);
    assert.equal(res.body.status, 'approved');
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
