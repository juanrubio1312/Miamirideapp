import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:ride_services/ride_services.dart';

import 'package:passenger_app/main.dart';

class _FakeRideRepository implements RideRepository {
  _FakeRideRepository({
    this.completedRideCount = 0,
    this.referralCodeUsed = false,
  });

  final int completedRideCount;
  final bool referralCodeUsed;

  @override
  Stream<TripData?> tripStream(String tripId) => const Stream.empty();

  @override
  Stream<List<TripData>> viajesDisponiblesStream() =>
      Stream.value(const <TripData>[]);

  @override
  Stream<TripData?> viajeActivoConductorStream(String conductorUid) =>
      Stream.value(null);

  @override
  Future<String> solicitarViaje({
    required String origen,
    required String destino,
    required double tarifa,
    required String paymentMethod,
  }) async =>
      'trip-id';

  @override
  Future<int> contarViajesFinalizadosPasajero() async => completedRideCount;

  @override
  Future<ReferralInfo> obtenerEstadoReferidos() async => ReferralInfo(
    code: 'RUNS-1234ABCD',
    codeUsed: referralCodeUsed,
    creditBalance: 0,
    referralApplied: false,
    rewardGranted: false,
    canApplyReferral: true,
  );

  @override
  Future<void> aplicarCodigoInvitacion({required String code}) async {}

  @override
  Future<bool> aceptarViaje({
    required String tripId,
    required String conductor,
    required String conductorUid,
  }) async =>
      false;

  @override
  Future<bool> iniciarViaje({
    required String tripId,
    required String conductorUid,
  }) async =>
      false;

  @override
  Future<RideCompletionResult> finalizarViaje({
    required String tripId,
  }) async =>
      const RideCompletionResult(
        completed: false,
        commissionAmount: 0,
        commissionWaived: false,
        commissionWaivedReason: null,
        driverBonusAmount: 0,
        passengerPromoApplied: false,
        platformSubsidyAmount: 0,
        passengerDiscountAmount: 0,
        passengerAmountDue: 0,
      );
}

void main() {
  testWidgets('shows the passenger ride request form', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PassengerHomeScreen(rideRepository: _FakeRideRepository()),
      ),
    );
    await tester.pump();

    final formScrollable = find
        .descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        )
        .first;

    expect(find.text('Passenger App - Miami'), findsOneWidget);
    expect(find.byType(GoogleMap), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Punto de Recogida (Origen)'),
      200,
      scrollable: formScrollable,
    );
    expect(find.text('Punto de Recogida (Origen)'), findsOneWidget);
  });

  testWidgets('requires a payment method after three completed trips', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PassengerHomeScreen(
          rideRepository: _FakeRideRepository(completedRideCount: 3),
        ),
      ),
    );
    await tester.pump();

    final formScrollable = find
        .descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('Método de pago'),
      200,
      scrollable: formScrollable,
    );
    expect(find.text('Método de pago'), findsOneWidget);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    expect(find.text('Tarjeta de crédito'), findsOneWidget);
    expect(find.text('Apple Pay'), findsOneWidget);
    expect(find.text('Google Pay'), findsOneWidget);
    expect(find.textContaining('te quedan'), findsNothing);
  });

  testWidgets('disables sharing when the referral code has been used', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PassengerHomeScreen(
          rideRepository: _FakeRideRepository(referralCodeUsed: true),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('CÓDIGO YA UTILIZADO'), findsOneWidget);
    expect(
      find.text(
        'Tu código ya fue utilizado por un amigo. Solo se puede usar una vez.',
      ),
      findsOneWidget,
    );
    final button = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'CÓDIGO YA UTILIZADO'),
    );
    expect(button.onPressed, isNull);
  });
}
