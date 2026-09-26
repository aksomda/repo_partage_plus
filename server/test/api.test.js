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

describe('authentification', () => {
  test('inscription puis doublon', async () => {
    const payload = {
      name: 'Nouveau Bénéficiaire',
      email: 'nouveau@test.local',
      password: 'motdepasse1',
      role: 'beneficiary',
    };
    const created = await api.post('/api/auth/register').send(payload);
    assert.equal(created.status, 201, created.text);
    assert.ok(created.body.token);
    assert.equal(created.body.user.password_hash, undefined);

    const duplicate = await api.post('/api/auth/register').send(payload);
    assert.equal(duplicate.status, 409);
  });

  test('inscription invalide : 400 avec détails', async () => {
    const res = await api
      .post('/api/auth/register')
      .send({ name: 'X', email: 'pas-un-email', password: '1', role: 'admin' });
    assert.equal(res.status, 400);
    assert.ok(res.body.details.length >= 3);
  });

  test('une association doit fournir ses informations', async () => {
    const res = await api.post('/api/auth/register').send({
      name: 'Asso sans infos',
      email: 'asso@test.local',
      password: 'motdepasse1',
      role: 'association',
    });
    assert.equal(res.status, 400);
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

  test('un bénéficiaire ne peut pas publier', async () => {
    const res = await api.post('/api/offers').set(as('beneficiary')).send({});
    assert.equal(res.status, 403);
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

  test('les recommandations privilégient la catégorie déjà réservée', async () => {
    const res = await api.get('/api/recommendations').set(as('beneficiary'));
    assert.equal(res.status, 200);
    assert.ok(res.body.length > 0);
    assert.ok(res.body[0].affinity >= 1);
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

  test('suspension de compte : connexion refusée', async () => {
    const users = await api.get('/api/admin/users?q=nouveau@test.local').set(as('admin'));
    const [user] = users.body;

    const res = await api
      .patch(`/api/admin/users/${user.id}/status`)
      .set(as('admin'))
      .send({ status: 'suspended', reason: 'Test' });
    assert.equal(res.status, 200, res.text);

    const loginRes = await api
      .post('/api/auth/login')
      .send({ email: 'nouveau@test.local', password: 'motdepasse1' });
    assert.equal(loginRes.status, 403);
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
