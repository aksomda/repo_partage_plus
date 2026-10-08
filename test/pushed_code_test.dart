import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:repo_partage_plus/core/notifications/push_messaging.dart';
import 'package:repo_partage_plus/features/auth/presentation/verify_email_screen.dart';

import 'helpers.dart';

/// Push simulé : les codes sont émis par le test.
class _FakePush extends PushMessaging {
  _FakePush(super.ref);

  final controller = StreamController<PushedCode>.broadcast();

  @override
  Stream<PushedCode> get codes => controller.stream;
}

void main() {
  testWidgets('code d’activation reçu par push : champ rempli tout seul', (
    tester,
  ) async {
    late _FakePush push;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...await testOverrides(),
          pushMessagingProvider.overrideWith((ref) => push = _FakePush(ref)),
        ],
        child: const MaterialApp(
          home: VerifyEmailScreen(initialEmail: 'awa@test.local'),
        ),
      ),
    );
    await tester.pump();

    // Code d'un autre usage : ignoré.
    push.controller.add((purpose: 'password_reset', code: '111111'));
    await tester.pump();
    expect(find.text('111111'), findsNothing);

    push.controller.add((purpose: 'activation', code: '482913'));
    await tester.pump();
    expect(find.text('482913'), findsOneWidget);
    expect(find.textContaining('Code reçu par notification'), findsOneWidget);
  });
}
