import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

class TripData {
  const TripData({
    required this.id,
    required this.pasajero,
    required this.pasajeroUid,
    required this.origen,
    required this.destino,
    required this.tarifa,
    required this.estado,
    this.conductorAsignado,
    this.conductorUid,
    this.promotionalEligibleAtRequest = false,
    this.passengerPromoApplied = false,
    this.passengerDiscountAmount = 0,
    this.passengerAmountDue,
    this.paymentMethod,
    this.platformSubsidyAmount = 0,
    this.updatedAt,
  });

  final String id;
  final String pasajero;
  final String pasajeroUid;
  final String origen;
  final String destino;
  final double tarifa;
  final String estado;
  final String? conductorAsignado;
  final String? conductorUid;
  final bool promotionalEligibleAtRequest;
  final bool passengerPromoApplied;
  final double passengerDiscountAmount;
  final double? passengerAmountDue;
  final String? paymentMethod;
  final double platformSubsidyAmount;
  final DateTime? updatedAt;

  factory TripData.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> snapshot,
  ) {
    final data = snapshot.data();
    if (data == null) {
      throw FormatException('El viaje ${snapshot.id} no contiene datos.');
    }

    final tarifa = data['tarifa'];
    if (data['pasajero'] is! String ||
        data['pasajeroUid'] is! String ||
        data['origen'] is! String ||
        data['destino'] is! String ||
        tarifa is! num ||
        data['estado'] is! String) {
      throw FormatException('El viaje ${snapshot.id} tiene datos inválidos.');
    }

    final updatedAt = data['updatedAt'];
    final platformSubsidyAmount = data['platformSubsidyAmount'];
    final passengerDiscountAmount = data['passengerDiscountAmount'];
    final passengerAmountDue = data['passengerAmountDue'];
    final promotionalEligibleAtRequest =
        data['promotionalEligibleAtRequest'] is bool
        ? data['promotionalEligibleAtRequest'] as bool
        : false;
    final passengerPromoApplied = data['passengerPromoApplied'] is bool
        ? data['passengerPromoApplied'] as bool
        : false;
    return TripData(
      id: snapshot.id,
      pasajero: data['pasajero'] as String,
      pasajeroUid: data['pasajeroUid'] as String,
      origen: data['origen'] as String,
      destino: data['destino'] as String,
      tarifa: tarifa.toDouble(),
      estado: data['estado'] as String,
      conductorAsignado: data['conductorAsignado'] as String?,
      conductorUid: data['conductorUid'] as String?,
      promotionalEligibleAtRequest: promotionalEligibleAtRequest,
      passengerPromoApplied: passengerPromoApplied,
      passengerDiscountAmount: passengerDiscountAmount is num
          ? passengerDiscountAmount.toDouble()
          : (passengerPromoApplied || promotionalEligibleAtRequest
                ? tarifa.toDouble()
                : 0),
      passengerAmountDue: passengerAmountDue is num
          ? passengerAmountDue.toDouble()
          : (passengerPromoApplied || promotionalEligibleAtRequest
                ? 0
                : tarifa.toDouble()),
      paymentMethod: data['paymentMethod'] as String?,
      platformSubsidyAmount: platformSubsidyAmount is num
          ? platformSubsidyAmount.toDouble()
          : 0,
      updatedAt: updatedAt is Timestamp ? updatedAt.toDate() : null,
    );
  }
}

class RideCompletionResult {
  const RideCompletionResult({
    required this.completed,
    required this.commissionAmount,
    required this.commissionWaived,
    required this.commissionWaivedReason,
    required this.driverBonusAmount,
    required this.passengerPromoApplied,
    required this.platformSubsidyAmount,
    required this.passengerDiscountAmount,
    required this.passengerAmountDue,
  });

  final bool completed;
  final double commissionAmount;
  final bool commissionWaived;
  final String? commissionWaivedReason;
  final double driverBonusAmount;
  final bool passengerPromoApplied;
  final double platformSubsidyAmount;
  final double passengerDiscountAmount;
  final double passengerAmountDue;
}

class ReferralInfo {
  const ReferralInfo({
    required this.code,
    required this.codeUsed,
    required this.creditBalance,
    required this.referralApplied,
    required this.rewardGranted,
    required this.canApplyReferral,
  });

  final String code;
  final bool codeUsed;
  final double creditBalance;
  final bool referralApplied;
  final bool rewardGranted;
  final bool canApplyReferral;
}

/// Contract used by the app screens and their widget tests.
abstract interface class RideRepository {
  Stream<TripData?> tripStream(String tripId);
  Stream<List<TripData>> viajesDisponiblesStream();
  Stream<TripData?> viajeActivoConductorStream(String conductorUid);
  Future<String> solicitarViaje({
    required String origen,
    required String destino,
    required double tarifa,
    required String paymentMethod,
  });
  Future<int> contarViajesFinalizadosPasajero();
  Future<ReferralInfo> obtenerEstadoReferidos();
  Future<void> aplicarCodigoInvitacion({required String code});
  Future<bool> aceptarViaje({
    required String tripId,
    required String conductor,
    required String conductorUid,
  });
  Future<bool> iniciarViaje({
    required String tripId,
    required String conductorUid,
  });
  Future<RideCompletionResult> finalizarViaje({required String tripId});
}

class RideService implements RideRepository {
  RideService({FirebaseFirestore? firestore, FirebaseFunctions? functions})
    : _firestore = firestore ?? FirebaseFirestore.instance,
      _functions = functions ?? FirebaseFunctions.instance;

  static const String _collectionName = 'rides';
  final FirebaseFirestore _firestore;
  final FirebaseFunctions _functions;

  CollectionReference<Map<String, dynamic>> get _rides =>
      _firestore.collection(_collectionName);

  @override
  Stream<TripData?> tripStream(String tripId) {
    return _rides
        .doc(tripId)
        .snapshots()
        .map(
          (snapshot) =>
              snapshot.exists ? TripData.fromFirestore(snapshot) : null,
        );
  }

  @override
  Stream<List<TripData>> viajesDisponiblesStream() {
    return _rides.where('estado', isEqualTo: 'BUSCANDO').snapshots().map((
      snapshot,
    ) {
      final trips = snapshot.docs.map(TripData.fromFirestore).toList()
        ..sort((a, b) {
          final aTime = a.updatedAt;
          final bTime = b.updatedAt;
          if (aTime == null || bTime == null) return 0;
          return bTime.compareTo(aTime);
        });
      return trips;
    });
  }

  @override
  Stream<TripData?> viajeActivoConductorStream(String conductorUid) {
    return _rides
        .where('conductorUid', isEqualTo: conductorUid)
        .snapshots()
        .map((snapshot) {
          final trips =
              snapshot.docs
                  .map(TripData.fromFirestore)
                  .where(
                    (trip) =>
                        trip.estado == 'ACEPTADO' || trip.estado == 'EN_CURSO',
                  )
                  .toList()
                ..sort((a, b) {
                  final aTime = a.updatedAt;
                  final bTime = b.updatedAt;
                  if (aTime == null || bTime == null) return 0;
                  return bTime.compareTo(aTime);
                });
          return trips.isEmpty ? null : trips.first;
        });
  }

  @override
  Future<String> solicitarViaje({
    required String origen,
    required String destino,
    required double tarifa,
    required String paymentMethod,
  }) async {
    final result = await _functions
        .httpsCallable('crearSolicitudViaje')
        .call<Map<String, dynamic>>({
          'origen': origen,
          'destino': destino,
          'tarifa': tarifa,
          'paymentMethod': paymentMethod,
        });
    final tripId = result.data['tripId'];
    if (tripId is! String || tripId.isEmpty) {
      throw const FormatException(
        'La respuesta al solicitar el viaje no es válida.',
      );
    }
    return tripId;
  }

  @override
  Future<int> contarViajesFinalizadosPasajero() async {
    final result = await _functions
        .httpsCallable('contarViajesFinalizados')
        .call<Map<String, dynamic>>();
    final count = result.data['completedRideCount'];
    if (count is! int || count < 0) {
      throw const FormatException(
        'La respuesta del conteo de viajes no es válida.',
      );
    }
    return count;
  }

  @override
  Future<ReferralInfo> obtenerEstadoReferidos() async {
    final result = await _functions
        .httpsCallable('obtenerEstadoReferidos')
        .call<Map<String, dynamic>>();
    final code = result.data['referralCode'];
    final codeUsed = result.data['referralCodeUsed'];
    final creditBalance = result.data['referralCreditBalance'];
    final referralApplied = result.data['referralApplied'];
    final rewardGranted = result.data['referralRewardGranted'];
    final canApplyReferral = result.data['canApplyReferral'];
    if (code is! String ||
        code.isEmpty ||
        codeUsed is! bool ||
        creditBalance is! num ||
        referralApplied is! bool ||
        rewardGranted is! bool ||
        canApplyReferral is! bool) {
      throw const FormatException(
        'La respuesta del estado de invitaciones no es válida.',
      );
    }
    return ReferralInfo(
      code: code,
      codeUsed: codeUsed,
      creditBalance: creditBalance.toDouble(),
      referralApplied: referralApplied,
      rewardGranted: rewardGranted,
      canApplyReferral: canApplyReferral,
    );
  }

  @override
  Future<void> aplicarCodigoInvitacion({required String code}) async {
    final result = await _functions
        .httpsCallable('aplicarCodigoInvitacion')
        .call<Map<String, dynamic>>({'code': code});
    if (result.data['applied'] != true) {
      throw const FormatException(
        'No se pudo aplicar el código de invitación.',
      );
    }
  }

  @override
  Future<bool> aceptarViaje({
    required String tripId,
    required String conductor,
    required String conductorUid,
  }) {
    return _actualizarEstado(
      tripId: tripId,
      estadoRequerido: 'BUSCANDO',
      nuevoEstado: 'ACEPTADO',
      conductorUid: conductorUid,
      conductorAsignado: conductor,
    );
  }

  @override
  Future<bool> iniciarViaje({
    required String tripId,
    required String conductorUid,
  }) {
    return _actualizarEstado(
      tripId: tripId,
      estadoRequerido: 'ACEPTADO',
      nuevoEstado: 'EN_CURSO',
      conductorUid: conductorUid,
    );
  }

  @override
  Future<RideCompletionResult> finalizarViaje({required String tripId}) async {
    final result = await _functions
        .httpsCallable('finalizarViaje')
        .call<Map<String, dynamic>>({'tripId': tripId});
    final completed = result.data['completed'];
    final commissionAmount = result.data['commissionAmount'];
    final commissionWaived = result.data['commissionWaived'];
    final commissionWaivedReason = result.data['commissionWaivedReason'];
    final driverBonusAmount = result.data['driverBonusAmount'];
    final passengerPromoApplied = result.data['passengerPromoApplied'];
    final platformSubsidyAmount = result.data['platformSubsidyAmount'];
    final passengerDiscountAmount = result.data['passengerDiscountAmount'];
    final passengerAmountDue = result.data['passengerAmountDue'];
    if (completed is! bool ||
        commissionAmount is! num ||
        commissionWaived is! bool ||
        (commissionWaivedReason != null && commissionWaivedReason is! String) ||
        driverBonusAmount is! num ||
        passengerPromoApplied is! bool ||
        platformSubsidyAmount is! num ||
        passengerDiscountAmount is! num ||
        passengerAmountDue is! num) {
      throw const FormatException(
        'La respuesta al finalizar el viaje no es válida.',
      );
    }
    return RideCompletionResult(
      completed: completed,
      commissionAmount: commissionAmount.toDouble(),
      commissionWaived: commissionWaived,
      commissionWaivedReason: commissionWaivedReason as String?,
      driverBonusAmount: driverBonusAmount.toDouble(),
      passengerPromoApplied: passengerPromoApplied,
      platformSubsidyAmount: platformSubsidyAmount.toDouble(),
      passengerDiscountAmount: passengerDiscountAmount.toDouble(),
      passengerAmountDue: passengerAmountDue.toDouble(),
    );
  }

  Future<bool> _actualizarEstado({
    required String tripId,
    required String estadoRequerido,
    required String nuevoEstado,
    required String conductorUid,
    String? conductorAsignado,
  }) {
    final reference = _rides.doc(tripId);
    return _firestore.runTransaction<bool>((transaction) async {
      final snapshot = await transaction.get(reference);
      final data = snapshot.data();
      if (!snapshot.exists ||
          data == null ||
          data['estado'] != estadoRequerido) {
        return false;
      }

      if (estadoRequerido != 'BUSCANDO' &&
          data['conductorUid'] != conductorUid) {
        return false;
      }

      transaction.update(reference, {
        'estado': nuevoEstado,
        'conductorUid': conductorUid,
        if (conductorAsignado != null) 'conductorAsignado': conductorAsignado,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      return true;
    });
  }
}
