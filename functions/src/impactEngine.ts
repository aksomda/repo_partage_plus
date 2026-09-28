import { Firestore, FieldValue } from "firebase-admin/firestore";

/**
 * Facteur d'émissions de CO2 évitées par kg de produit sauvé du
 * gaspillage (production + fin de vie évitées). Valeur approximative
 * à ajuster avec l'équipe selon la source retenue (ex. ADEME).
 */
export const CO2_FACTOR_KG_PER_KG = 2.5;

export interface ImpactInput {
  quantityReserved: number;
  originalPrice: number;
  discountedPrice: number;
  weightKg: number;
}

export interface ImpactResult {
  produitsSauves: number;
  economiesRealisees: number;
  dechetsEvitesKg: number;
  emissionsCO2EviteesKg: number;
}

export function calculateReservationImpact(input: ImpactInput): ImpactResult {
  const { quantityReserved, originalPrice, discountedPrice, weightKg } =
    input;

  const economieUnitaire = Math.max(originalPrice - discountedPrice, 0);
  const dechetsEvitesKg = weightKg * quantityReserved;

  return {
    produitsSauves: quantityReserved,
    economiesRealisees: economieUnitaire * quantityReserved,
    dechetsEvitesKg,
    emissionsCO2EviteesKg: dechetsEvitesKg * CO2_FACTOR_KG_PER_KG,
  };
}

export function isoWeekKey(date: Date): string {
  const d = new Date(
    Date.UTC(date.getFullYear(), date.getMonth(), date.getDate())
  );
  const dayNum = d.getUTCDay() || 7;
  d.setUTCDate(d.getUTCDate() + 4 - dayNum);
  const yearStart = new Date(Date.UTC(d.getUTCFullYear(), 0, 1));
  const weekNo = Math.ceil(
    ((d.getTime() - yearStart.getTime()) / 86400000 + 1) / 7
  );
  return `${d.getUTCFullYear()}-W${String(weekNo).padStart(2, "0")}`;
}

export function monthKey(date: Date): string {
  return date.toISOString().slice(0, 7);
}

export function yearKey(date: Date): string {
  return String(date.getFullYear());
}

export function dayKey(date: Date): string {
  return date.toISOString().slice(0, 10);
}

interface ApplyParams {
  userId: string;
  category: string;
  now: Date;
  impact: ImpactResult;
}

const incrementFieldsFrom = (impact: ImpactResult) => ({
  produitsSauves: FieldValue.increment(impact.produitsSauves),
  economiesRealisees: FieldValue.increment(impact.economiesRealisees),
  dechetsEvitesKg: FieldValue.increment(impact.dechetsEvitesKg),
  emissionsCO2EviteesKg: FieldValue.increment(impact.emissionsCO2EviteesKg),
  updatedAt: FieldValue.serverTimestamp(),
});

export async function applyImpactToAggregates(
  db: Firestore,
  { userId, category, now, impact }: ApplyParams
): Promise<void> {
  const batch = db.batch();
  const incrementFields = incrementFieldsFrom(impact);

  batch.set(db.collection("impactGlobal").doc("summary"), incrementFields, {
    merge: true,
  });

  batch.set(db.collection("impactUsers").doc(userId), incrementFields, {
    merge: true,
  });

  batch.set(
    db.collection("impactUserPeriods").doc(`${userId}_week_${isoWeekKey(now)}`),
    incrementFields,
    { merge: true }
  );
  batch.set(
    db.collection("impactUserPeriods").doc(`${userId}_month_${monthKey(now)}`),
    incrementFields,
    { merge: true }
  );
  batch.set(
    db.collection("impactUserPeriods").doc(`${userId}_year_${yearKey(now)}`),
    incrementFields,
    { merge: true }
  );

  batch.set(
    db.collection("impactDaily").doc(dayKey(now)),
    { ...incrementFields, date: dayKey(now) },
    { merge: true }
  );
  batch.set(
    db.collection("impactMonthly").doc(monthKey(now)),
    { ...incrementFields, month: monthKey(now) },
    { merge: true }
  );

  batch.set(
    db.collection("impactByCategory").doc(category),
    incrementFields,
    { merge: true }
  );

  await batch.commit();
}