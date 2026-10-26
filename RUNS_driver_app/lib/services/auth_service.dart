import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';

class AuthService {
  AuthService({
    FirebaseAuth? auth,
    FirebaseFirestore? firestore,
    FirebaseFunctions? functions,
  })  : _auth = auth ?? FirebaseAuth.instance,
        _firestore = firestore ?? FirebaseFirestore.instance,
        _functions = functions ?? FirebaseFunctions.instance;

  static const String _role = 'driver';
  static const String _wrongRoleMessage =
      'Esta cuenta pertenece a un pasajero. Utiliza la app de pasajeros.';
  static const String _pendingApprovalMessage =
      'Tu solicitud para conducir está pendiente de revisión. Te avisaremos cuando sea aprobada.';
  static const String _rejectedApprovalMessage =
      'Tu solicitud para conducir no fue aprobada. Contacta con soporte si necesitas más información.';
  static const double saldoMinimoPermitido = -50.0;

  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;
  final FirebaseFunctions _functions;

  User? get currentUser => _auth.currentUser;

  Future<String?> registrarConductor({
    required String email,
    required String password,
    required String nombre,
    required String numeroDocumento,
    required int vehicleYear,
  }) async {
    final normalizedEmail = email.trim();
    final normalizedName = nombre.trim();
    final normalizedDoc = numeroDocumento.trim();

    if (normalizedEmail.isEmpty ||
        normalizedName.isEmpty ||
        normalizedDoc.isEmpty) {
      return 'Ingresa tu nombre, correo electrónico y número de documento.';
    }
    final currentYear = DateTime.now().year;
    if (vehicleYear < 2014 || vehicleYear > currentYear) {
      return 'El vehículo debe ser modelo 2014 o posterior y no puede ser de un año futuro.';
    }

    late final UserCredential credential;
    try {
      credential = await _auth.createUserWithEmailAndPassword(
        email: normalizedEmail,
        password: password,
      );
    } on FirebaseAuthException catch (error) {
      return error.message ?? 'No se pudo crear la cuenta.';
    }

    final user = credential.user;
    if (user == null) {
      return 'Firebase no devolvió el usuario recién creado.';
    }

    try {
      await _functions.httpsCallable('solicitarAltaConductor').call({
        'nombre': normalizedName,
        'numeroDocumento': normalizedDoc,
        'vehicleYear': vehicleYear,
      });
      await _auth.signOut();
      return null;
    } on FirebaseFunctionsException catch (error) {
      await _auth.signOut();
      return error.message ?? 'No se pudo enviar la solicitud de conductor.';
    }
  }

  Future<String?> iniciarSesionConductor({
    required String email,
    required String password,
  }) async {
    late final UserCredential credential;
    try {
      credential = await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
    } on FirebaseAuthException catch (error) {
      return error.message ?? 'No se pudo iniciar sesión.';
    }

    final user = credential.user;
    if (user == null) {
      return 'Firebase no devolvió un usuario autenticado.';
    }

    try {
      final userDoc = await _firestore.collection('users').doc(user.uid).get();
      final userData = userDoc.data();
      final role = userData?['role'];
      if (role == 'pending_driver' ||
          userData?['driverApprovalStatus'] == 'pending') {
        await _auth.signOut();
        return _pendingApprovalMessage;
      }
      if (role == 'rejected_driver' ||
          userData?['driverApprovalStatus'] == 'rejected') {
        await _auth.signOut();
        return _rejectedApprovalMessage;
      }
      if (role != _role || userData?['driverApproved'] != true) {
        await _auth.signOut();
        return role == 'passenger'
            ? _wrongRoleMessage
            : 'La cuenta no tiene un perfil de conductor válido.';
      }

      final balance = userData?['saldoBilletera'];
      if (balance is! num || !balance.isFinite) {
        await _auth.signOut();
        return 'El perfil no tiene un saldo válido. Contacta con soporte.';
      }
      if (balance < saldoMinimoPermitido) {
        await _auth.signOut();
        return 'Tu saldo es inferior a -\$50 USD. Contacta con soporte antes de iniciar sesión.';
      }

      return null;
    } on FirebaseException catch (error) {
      await _auth.signOut();
      return error.message ?? 'No se pudo verificar el perfil del conductor.';
    }
  }

  Future<void> cerrarSesion() => _auth.signOut();
}
