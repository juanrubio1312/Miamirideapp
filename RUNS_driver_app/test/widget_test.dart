import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_services/ride_services.dart';

import 'package:driver_app/main.dart' as driver_app;

class _FakeRideRepository implements RideRepository {
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
  Future<int> contarViajesFinalizadosPasajero() async => 0;

  @override
  Future<ReferralInfo> obtenerEstadoReferidos() async => const ReferralInfo(
    code: 'RUNS-1234ABCD',
    codeUsed: false,
    creditBalance: 0,
    referralApplied: false,
    rewardGranted: false,
    canApplyReferral: false,
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
  testWidgets('shows the driver home screen', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: driver_app.DriverHomeScreen(
          rideRepository: _FakeRideRepository(),
          conductorUid: 'driver-test',
          conductorNombre: 'Test Driver',
        ),
      ),
    );

    expect(find.text('Driver App - Panel de Solicitudes'), findsOneWidget);
  });
}
