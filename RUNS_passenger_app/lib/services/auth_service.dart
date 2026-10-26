import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class AuthService {
  AuthService({
    FirebaseAuth? auth,
    FirebaseFirestore? firestore,
  })  : _auth = auth ?? FirebaseAuth.instance,
        _firestore = firestore ?? FirebaseFirestore.instance;

  static const String _role = 'passenger';
  static const String _wrongRoleMessage =
      'Esta cuenta pertenece a un conductor. Utiliza la app de conductores.';

  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;

  User? get currentUser => _auth.currentUser;

  Future<String?> registrarPasajero({
    required String email,
    required String password,
    required String nombre,
    required String numeroDocumento, // <-- Agregado para seguridad antifraude
  }) async {
    final normalizedEmail = email.trim();
    final normalizedName = nombre.trim();
    final normalizedDoc = numeroDocumento.trim();

    if (normalizedEmail.isEmpty ||
        normalizedName.isEmpty ||
        normalizedDoc.isEmpty) {
      return 'Ingresa tu nombre, correo electrónico y número de documento.';
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
      final docQuery = await _firestore
          .collection('users')
          .where('numeroDocumento', isEqualTo: normalizedDoc)
          .get();
      if (docQuery.docs.isNotEmpty) {
        try {
          await user.delete();
        } on FirebaseException catch (cleanupError) {
          return 'Este número de documento ya está asociado a otra cuenta. '
              'No se pudo limpiar la cuenta creada '
              '(${cleanupError.message ?? cleanupError.code}).';
        }
        return 'Este número de documento ya está asociado a otra cuenta.';
      }
    } on FirebaseException catch (error) {
      try {
        await user.delete();
      } on FirebaseException catch (cleanupError) {
        return 'Error al verificar el documento: '
            '${error.message ?? error.code}. '
            'No se pudo limpiar la cuenta creada '
            '(${cleanupError.message ?? cleanupError.code}).';
      }
      return 'Error al verificar el documento: ${error.message ?? error.code}';
    }

    try {
      await _firestore.collection('users').doc(user.uid).set({
        'uid': user.uid,
        'nombre': normalizedName,
        'email': normalizedEmail,
        'numeroDocumento': normalizedDoc, // <-- Guardado en el perfil
        'role': _role,
        'createdAt': FieldValue.serverTimestamp(),
      });
      return null;
    } on FirebaseException catch (error) {
      try {
        await user.delete(); // Rollback de seguridad si falla Firestore
      } on FirebaseException catch (cleanupError) {
        return 'No se pudo guardar el perfil (${error.message ?? error.code}) '
            'ni limpiar la cuenta creada (${cleanupError.message ?? cleanupError.code}).';
      }
      return error.message ?? 'No se pudo guardar el perfil del pasajero.';
    }
  }

  Future<String?> iniciarSesionPasajero({
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
      final role = userDoc.data()?['role'];
      if (role != _role) {
        await _auth.signOut();
        return role == 'driver'
            ? _wrongRoleMessage
            : 'La cuenta no tiene un perfil de pasajero válido.';
      }
      return null;
    } on FirebaseException catch (error) {
      await _auth.signOut();
      return error.message ?? 'No se pudo verificar el perfil del pasajero.';
    }
  }

  Future<void> cerrarSesion() => _auth.signOut();
}
