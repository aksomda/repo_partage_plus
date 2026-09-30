import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/features/admin/presentation/account_moderation_screen.dart';
import 'package:repo_partage_plus/features/admin/presentation/actors_screen.dart';
import 'package:repo_partage_plus/features/admin/presentation/admin_dashboard_screen.dart';
import 'package:repo_partage_plus/features/admin/presentation/association_validation_screen.dart';
import 'package:repo_partage_plus/features/admin/presentation/categories_screen.dart';
import 'package:repo_partage_plus/features/admin/presentation/factors_screen.dart';
import 'package:repo_partage_plus/features/admin/presentation/offer_moderation_screen.dart';
import 'package:repo_partage_plus/features/auth/presentation/login_screen.dart';
import 'package:repo_partage_plus/features/auth/presentation/profile_screen.dart';
import 'package:repo_partage_plus/features/auth/presentation/register_screen.dart';
import 'package:repo_partage_plus/features/auth/presentation/splash_screen.dart';
import 'package:repo_partage_plus/features/auth/presentation/verify_email_screen.dart';
import 'package:repo_partage_plus/features/discovery/presentation/home_screen.dart';
import 'package:repo_partage_plus/features/discovery/presentation/location_picker_screen.dart';
import 'package:repo_partage_plus/features/discovery/presentation/nearby_offers_map_screen.dart';
import 'package:repo_partage_plus/features/discovery/presentation/search_screen.dart';
import 'package:repo_partage_plus/features/impact/presentation/impact_screen.dart';
import 'package:repo_partage_plus/features/notifications/presentation/notifications_screen.dart';
import 'package:repo_partage_plus/features/offers/presentation/create_offer_screen.dart';
import 'package:repo_partage_plus/features/offers/presentation/my_offers_screen.dart';
import 'package:repo_partage_plus/features/offers/presentation/offer_detail_screen.dart';
import 'package:repo_partage_plus/features/pickup/presentation/pickup_screen.dart';
import 'package:repo_partage_plus/features/recommendations/presentation/recommendations_screen.dart';
import 'package:repo_partage_plus/features/reservations/presentation/my_reservations_screen.dart';
import 'package:repo_partage_plus/features/reservations/presentation/reserve_screen.dart';
import 'package:repo_partage_plus/features/reservations/presentation/reservation_confirmation_screen.dart';

/// [isLoggedIn] : null (tests) = aucune redirection vers la connexion.
GoRouter createRouter({
  String initialLocation = AppRoutes.splash,
  bool Function()? isLoggedIn,
  Listenable? refreshListenable,
}) {
  return GoRouter(
    initialLocation: initialLocation,
    refreshListenable: refreshListenable,
    redirect: (context, state) {
      if (isLoggedIn == null || isLoggedIn()) return null;
      final path = state.uri.path;
      return AppRoutes.requiresLogin(path)
          ? AppRoutes.loginThen(state.uri.toString())
          : null;
    },
    routes: [
      // Auth
      GoRoute(
        path: AppRoutes.splash,
        builder: (context, state) => const SplashScreen(),
      ),
      GoRoute(
        path: AppRoutes.login,
        builder: (context, state) =>
            LoginScreen(from: state.uri.queryParameters['from']),
      ),
      GoRoute(
        path: AppRoutes.register,
        builder: (context, state) => const RegisterScreen(),
      ),
      GoRoute(
        path: AppRoutes.verifyEmail,
        builder: (context, state) => VerifyEmailScreen(
          initialEmail: state.uri.queryParameters['email'] ?? '',
        ),
      ),
      GoRoute(
        path: AppRoutes.profile,
        builder: (context, state) => const ProfileScreen(),
      ),

      // Découverte
      GoRoute(
        path: AppRoutes.home,
        builder: (context, state) => const HomeScreen(),
      ),
      GoRoute(
        path: AppRoutes.nearbyMap,
        builder: (context, state) => const NearbyOffersMapScreen(),
      ),
      GoRoute(
        path: AppRoutes.search,
        builder: (context, state) => const SearchScreen(),
      ),
      GoRoute(
        path: AppRoutes.pickLocation,
        builder: (context, state) => const LocationPickerScreen(),
      ),

      // Offres : les chemins fixes avant /offers/:id
      GoRoute(
        path: AppRoutes.myOffers,
        builder: (context, state) => const MyOffersScreen(),
      ),
      GoRoute(
        path: AppRoutes.createOffer,
        builder: (context, state) => const CreateOfferScreen(),
      ),
      GoRoute(
        path: AppRoutes.offerDetail,
        builder: (context, state) =>
            OfferDetailScreen(offerId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: AppRoutes.reservePattern,
        builder: (context, state) =>
            ReserveScreen(offerId: int.parse(state.pathParameters['id']!)),
      ),

      // Réservations et retrait
      GoRoute(
        path: AppRoutes.myReservations,
        builder: (context, state) => const MyReservationsScreen(),
      ),
      GoRoute(
        path: AppRoutes.reservationConfirmation,
        builder: (context, state) => ReservationConfirmationScreen(
          reservationId: state.pathParameters['id']!,
        ),
      ),
      GoRoute(
        path: AppRoutes.pickupPattern,
        builder: (context, state) =>
            PickupScreen(reservationId: state.pathParameters['reservationId']!),
      ),

      // Notifications, impact, recommandations
      GoRoute(
        path: AppRoutes.notifications,
        builder: (context, state) => const NotificationsScreen(),
      ),
      GoRoute(
        path: AppRoutes.impact,
        builder: (context, state) => const ImpactScreen(),
      ),
      GoRoute(
        path: AppRoutes.recommendations,
        builder: (context, state) => const RecommendationsScreen(),
      ),

      // Administration
      GoRoute(
        path: AppRoutes.adminDashboard,
        builder: (context, state) => const AdminDashboardScreen(),
      ),
      GoRoute(
        path: AppRoutes.adminOffers,
        builder: (context, state) => const OfferModerationScreen(),
      ),
      GoRoute(
        path: AppRoutes.adminAccounts,
        builder: (context, state) => const AccountModerationScreen(),
      ),
      GoRoute(
        path: AppRoutes.adminAssociations,
        builder: (context, state) => const AssociationValidationScreen(),
      ),
      GoRoute(
        path: AppRoutes.adminCategories,
        builder: (context, state) => const CategoriesScreen(),
      ),
      GoRoute(
        path: AppRoutes.adminFactors,
        builder: (context, state) => const FactorsScreen(),
      ),
      GoRoute(
        path: AppRoutes.adminActors,
        builder: (context, state) => const ActorsScreen(),
      ),
    ],
  );
}

/// Prévient le routeur quand la session change (connexion, déconnexion).
class _SessionListenable extends ChangeNotifier {
  void changed() => notifyListeners();
}

final routerProvider = Provider<GoRouter>((ref) {
  final session = _SessionListenable();
  ref.listen(authTokenProvider, (_, _) => session.changed());
  ref.onDispose(session.dispose);

  final router = createRouter(
    isLoggedIn: () => ref.read(authTokenProvider) != null,
    refreshListenable: session,
  );
  ref.onDispose(router.dispose);
  return router;
});
