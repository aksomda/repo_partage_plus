import { onDocumentUpdated } from "firebase-functions/v2/firestore";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { initializeApp } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";
import {
  calculateReservationImpact,
  applyImpactToAggregates,
  isoWeekKey,
  monthKey,
  yearKey,
} from "./impactEngine";

initializeApp();
const db = getFirestore();

export const onReservationCompleted = onDocumentUpdated(
  "reservations/{reservationId}",
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (!before || !after) return;

    if (before.status === "completed" || after.status !== "completed") {
      return;
    }

    const offerSnap = await db.collection("offers").doc(after.offerId).get();
    if (!offerSnap.exists) {
      console.error(`Offre introuvable pour la réservation: ${after.offerId}`);
      return;
    }
    const offer = offerSnap.data()!;

    const impact = calculateReservationImpact({
      quantityReserved: after.quantityReserved ?? 1,
      originalPrice: offer.originalPrice ?? 0,
      discountedPrice: offer.discountedPrice ?? 0,
      weightKg: offer.weightKg ?? 0,
    });

    await applyImpactToAggregates(db, {
      userId: after.userId,
      category: offer.category ?? "autre",
      now: new Date(),
      impact,
    });
  }
);

export const getDashboardStats = onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError("unauthenticated", "Utilisateur non authentifié.");
  }

  const period: "week" | "month" | "year" | "all" =
    request.data?.period ?? "week";

  const now = new Date();
  const periodKey =
    period === "week"
      ? isoWeekKey(now)
      : period === "month"
      ? monthKey(now)
      : period === "year"
      ? yearKey(now)
      : null;

  const userDocRef =
    period === "all"
      ? db.collection("impactUsers").doc(uid)
      : db.collection("impactUserPeriods").doc(`${uid}_${period}_${periodKey}`);

  const [userSnap, globalSnap, dailySnap, monthlySnap, categorySnap] =
    await Promise.all([
      userDocRef.get(),
      db.collection("impactGlobal").doc("summary").get(),
      db.collection("impactDaily").orderBy("date", "desc").limit(30).get(),
      db.collection("impactMonthly").orderBy("month", "desc").limit(12).get(),
      db.collection("impactByCategory").get(),
    ]);

  return {
    user: userSnap.exists ? userSnap.data() : emptyImpact(),
    global: globalSnap.exists ? globalSnap.data() : emptyImpact(),
    dailySeries: dailySnap.docs
      .map((d) => ({ date: d.id, ...d.data() }))
      .reverse(),
    monthlySeries: monthlySnap.docs
      .map((d) => ({ month: d.id, ...d.data() }))
      .reverse(),
    byCategory: categorySnap.docs.map((d) => ({
      category: d.id,
      ...d.data(),
    })),
  };
});

function emptyImpact() {
  return {
    produitsSauves: 0,
    economiesRealisees: 0,
    dechetsEvitesKg: 0,
    emissionsCO2EviteesKg: 0,
  };
}