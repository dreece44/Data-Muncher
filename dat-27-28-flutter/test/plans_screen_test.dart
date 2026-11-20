import 'package:datamuncher/application/monetization/monetization_controller.dart';
import 'package:datamuncher/application/monetization/subscription_gateway.dart';
import 'package:datamuncher/presentation/monetization/ad_banner_slot.dart';
import 'package:datamuncher/presentation/monetization/plans_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_monetization.dart';

void main() {
  late FakeGateway gateway;
  late MonetizationController m;

  Future<void> start({FakeGateway? using, Plan? saved}) async {
    gateway = using ?? FakeGateway(restoreResult: null);
    m = MonetizationController(gateway: gateway);
    await m.init(MemoryPlanStore(saved));
  }

  Future<void> pumpPlans(WidgetTester tester,
      {TargetPlatform platform = TargetPlatform.iOS}) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    addTearDown(m.dispose);
    await tester.pumpWidget(MaterialApp(
        home: PlansScreen(monetization: m, platform: platform)));
    await tester.pumpAndSettle();
  }

  group('Plans screen', () {
    testWidgets('both plans have every feature; only ads differ',
        (tester) async {
      await start();
      await pumpPlans(tester);

      expect(find.text("You're on the free plan"), findsOneWidget);
      expect(
          find.text('Every DataMuncher feature is included in both plans. '
              'The only difference is ads.'),
          findsOneWidget);
      expect(find.text('Free'), findsWidgets);
      expect(find.text(r'$0.99 / month'), findsOneWidget);
      expect(find.text('No ads anywhere'), findsOneWidget);
      expect(find.text('Current plan'), findsOneWidget);
    });

    testWidgets('subscribing makes the user ad-free', (tester) async {
      await start();
      await pumpPlans(tester);

      await tester.tap(find.text(r'Go ad-free for $0.99 / month'));
      await tester.pump();
      expect(gateway.bought, hasLength(1));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      gateway.emit(const BillingOwned());
      await tester.pumpAndSettle();

      expect(find.text("You're ad-free"), findsOneWidget);
      expect(find.text("You're ad-free. Thanks for supporting DataMuncher!"),
          findsOneWidget);
      expect(
          find.text('Manage or cancel it any time in Settings → your name → '
              'Subscriptions.'),
          findsOneWidget);
    });

    testWidgets('states billing and cancel terms for the right store',
        (tester) async {
      await start();
      await pumpPlans(tester, platform: TargetPlatform.android);
      expect(find.textContaining('Billed monthly through the Google Play'),
          findsOneWidget);
      expect(find.textContaining('Play Store → Payments & subscriptions'),
          findsOneWidget);
    });

    testWidgets('unavailable subscription can be retried', (tester) async {
      await start(using: FakeGateway(offer: null, restoreResult: null));
      await pumpPlans(tester);
      expect(find.textContaining("The subscription isn't available right now"),
          findsOneWidget);

      gateway.offer = const SubscriptionOffer(
          productId: 'p', title: 'Ad-free', price: r'$0.99');
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text(r'Go ad-free for $0.99 / month'), findsOneWidget);
    });

    testWidgets('Restore purchases reports the result', (tester) async {
      await start();
      await pumpPlans(tester);
      gateway.restoreResult = true;
      await tester.tap(find.text('Restore purchases'));
      await tester.pumpAndSettle();
      expect(find.text('Subscription restored. No more ads.'), findsOneWidget);
      expect(find.text("You're ad-free"), findsOneWidget);
    });

    testWidgets('Ask to Buy shows that approval is pending', (tester) async {
      await start();
      await pumpPlans(tester);
      await tester.tap(find.text(r'Go ad-free for $0.99 / month'));
      await tester.pump();
      gateway.emit(const BillingPending());
      await tester.pumpAndSettle();
      expect(find.textContaining('Waiting for the purchase to be approved'),
          findsWidgets);
    });

    testWidgets('test mode says no money is charged and asks first',
        (tester) async {
      await start(
          using: FakeGateway(isTest: true, checksOnLaunch: false));
      await pumpPlans(tester);
      expect(
          find.text('Test mode: purchases are simulated and no money is '
              'charged.'),
          findsOneWidget);

      await tester.tap(find.text(r'Go ad-free for $0.99 / month'));
      await tester.pumpAndSettle();
      expect(find.text('Test purchase'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(gateway.bought, isEmpty);

      await tester.tap(find.text(r'Go ad-free for $0.99 / month'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Subscribe (test)'));
      await tester.pump();
      gateway.emit(const BillingOwned());
      await tester.pumpAndSettle();
      expect(find.text("You're ad-free"), findsOneWidget);

      await tester.tap(find.text('End test subscription'));
      await tester.pumpAndSettle();
      expect(find.text("You're on the free plan"), findsOneWidget);
    });
  });

  group('Ad banner slot', () {
    late FakeAdProvider ads;

    Future<void> pumpSlot(WidgetTester tester, {VoidCallback? onRemove}) async {
      ads = FakeAdProvider();
      addTearDown(m.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: const Text('Screen content'),
          bottomNavigationBar: AdBannerSlot(
              monetization: m, ads: ads, onRemoveAds: onRemove ?? () {}),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('free plan shows a banner with Remove ads', (tester) async {
      await start();
      var removeTaps = 0;
      await pumpSlot(tester, onRemove: () => removeTaps++);

      expect(find.byKey(const ValueKey('test-ad')), findsOneWidget);
      await tester.tap(find.text('Remove ads'));
      expect(removeTaps, 1);
      expect(find.text('Screen content'), findsOneWidget,
          reason: 'the ad sits below the screen, never over it');
    });

    testWidgets('ad-free plan shows nothing and takes no space',
        (tester) async {
      await start(saved: Plan.adFree);
      await pumpSlot(tester);
      expect(find.byKey(const ValueKey('test-ad')), findsNothing);
      expect(find.text('Remove ads'), findsNothing);
      expect(ads.built, 0, reason: 'no ad is even requested');
    });

    testWidgets('the banner disappears the moment the user subscribes',
        (tester) async {
      await start();
      await pumpSlot(tester);
      await m.subscribe();
      gateway.emit(const BillingOwned());
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('test-ad')), findsNothing);
    });

    testWidgets('WithAdBanner keeps the screen fully usable',
        (tester) async {
      await start();
      ads = FakeAdProvider();
      addTearDown(m.dispose);
      var tapped = 0;
      await tester.pumpWidget(MaterialApp(
        home: WithAdBanner(
          monetization: m,
          ads: ads,
          onRemoveAds: () {},
          child: Scaffold(
            body: Center(
              child: FilledButton(
                  onPressed: () => tapped++, child: const Text('Feature')),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Feature'));
      expect(tapped, 1);
      expect(find.byKey(const ValueKey('test-ad')), findsOneWidget);
    });
  });
}
