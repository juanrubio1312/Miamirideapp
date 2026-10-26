import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:ride_services/ride_services.dart';

import 'screens/login_screen.dart';

const _useFirebaseEmulators = bool.fromEnvironment('USE_FIREBASE_EMULATORS');
const _firebaseEmulatorHost = String.fromEnvironment(
  'FIREBASE_EMULATOR_HOST',
  defaultValue: '10.0.2.2',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  if (_useFirebaseEmulators) {
    FirebaseFirestore.instance
        .useFirestoreEmulator(_firebaseEmulatorHost, 8080);
    await FirebaseAuth.instance.useAuthEmulator(_firebaseEmulatorHost, 9099);
    FirebaseFunctions.instance
        .useFunctionsEmulator(_firebaseEmulatorHost, 5001);
  }
  runApp(const PassengerApp());
}

class PassengerApp extends StatelessWidget {
  const PassengerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Passenger App',
      theme: ThemeData.dark(),
      // Usamos un StreamBuilder para verificar si el usuario ya está autenticado
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snapshot) {
          // Si está cargando el estado de autenticación
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          // Si hay una sesión activa, va directo al Home de Viajes
          if (snapshot.hasData && snapshot.data != null) {
            return const PassengerHomeScreen();
          }
          // Si no hay sesión, muestra la pantalla de Login / Registro
          return const LoginScreen();
        },
      ),
    );
  }
}

class PassengerHomeScreen extends StatefulWidget {
  const PassengerHomeScreen({super.key, this.rideRepository});

  final RideRepository? rideRepository;

  @override
  State<PassengerHomeScreen> createState() => _PassengerHomeScreenState();
}

class _PassengerHomeScreenState extends State<PassengerHomeScreen> {
  late final RideRepository _rideService;
  final TextEditingController _origenController =
      TextEditingController(text: 'Brickell Ave, Miami');
  final TextEditingController _destinoController =
      TextEditingController(text: 'South Beach, Miami');
  final TextEditingController _tarifaController =
      TextEditingController(text: '25.0');

  TripData? viajeActual;
  StreamSubscription<TripData?>? _tripSubscription;
  String? _rideError;
  bool _solicitandoViaje = false;
  int? _completedRideCount;
  String _paymentMethod = 'cash';
  ReferralInfo? _referralInfo;
  bool _hasLocationPermission = false;
  String? _locationMessage;

  @override
  void dispose() {
    _origenController.dispose();
    _destinoController.dispose();
    _tarifaController.dispose();
    _tripSubscription?.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _rideService = widget.rideRepository ?? RideService();
    unawaited(_loadPromotionStatus());
    unawaited(_loadReferralInfo());
    unawaited(_checkLocationPermission());
  }

  Future<void> _checkLocationPermission() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        if (mounted) {
          setState(() {
            _hasLocationPermission = false;
            _locationMessage =
                'Activa los servicios de ubicación para mostrar tu posición.';
          });
        }
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (!mounted) return;
      setState(() {
        _hasLocationPermission = permission == LocationPermission.whileInUse ||
            permission == LocationPermission.always;
        _locationMessage = switch (permission) {
          LocationPermission.denied =>
            'No se concedió el permiso de ubicación. Puedes activarlo en los ajustes de la app.',
          LocationPermission.deniedForever =>
            'El permiso de ubicación está bloqueado. Actívalo en los ajustes de la app.',
          LocationPermission.unableToDetermine =>
            'No se pudo determinar el permiso de ubicación.',
          _ => null,
        };
      });
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _hasLocationPermission = false;
        _locationMessage = 'No se pudo comprobar el permiso de ubicación: '
            '${error.message ?? error.code}';
      });
    } on MissingPluginException catch (error) {
      if (!mounted) return;
      setState(() {
        _hasLocationPermission = false;
        _locationMessage = 'No está disponible el servicio de ubicación: '
            '${error.message ?? 'reinicia la app después de compilarla de nuevo.'}';
      });
    }
  }

  Future<void> _loadPromotionStatus() async {
    try {
      final count = await _rideService.contarViajesFinalizadosPasajero();
      if (!mounted) return;
      setState(() {
        _completedRideCount = count;
        _rideError = null;
      });
    } on FirebaseFunctionsException catch (error) {
      if (!mounted) return;
      setState(() => _rideError = _mensajeError(error));
    } on FirebaseException catch (error) {
      if (!mounted) return;
      setState(() => _rideError = _mensajeError(error));
    }
  }

  Future<void> _loadReferralInfo() async {
    try {
      final info = await _rideService.obtenerEstadoReferidos();
      if (!mounted) return;
      setState(() => _referralInfo = info);
    } on FirebaseFunctionsException catch (error) {
      if (!mounted) return;
      setState(() => _rideError = _mensajeError(error));
    } on FirebaseException catch (error) {
      if (!mounted) return;
      setState(() => _rideError = _mensajeError(error));
    } on FormatException catch (error) {
      if (!mounted) return;
      setState(() => _rideError = error.message);
    }
  }

  Future<void> _solicitarViaje() async {
    final origen = _origenController.text.trim();
    final destino = _destinoController.text.trim();
    final tarifa = double.tryParse(_tarifaController.text.trim());

    if (origen.isEmpty || destino.isEmpty) {
      _mostrarMensaje('Ingresa el origen y el destino.');
      return;
    }

    if (tarifa == null || !tarifa.isFinite || tarifa <= 0) {
      _mostrarMensaje('Ingresa una tarifa válida mayor a cero.');
      return;
    }

    setState(() {
      _solicitandoViaje = true;
      _rideError = null;
    });

    try {
      final tripId = await _rideService.solicitarViaje(
        origen: origen,
        destino: destino,
        tarifa: tarifa,
        paymentMethod: _paymentMethod,
      );
      await _tripSubscription?.cancel();
      _tripSubscription = _rideService.tripStream(tripId).listen(
        (trip) {
          if (!mounted) return;
          setState(() => viajeActual = trip);
          if (trip?.estado == 'FINALIZADO') {
            unawaited(_loadPromotionStatus());
            unawaited(_loadReferralInfo());
          }
        },
        onError: (Object error) {
          if (!mounted) return;
          setState(() => _rideError = _mensajeError(error));
        },
      );
    } on FirebaseFunctionsException catch (error) {
      if (mounted) {
        setState(() => _rideError = _mensajeError(error));
        unawaited(_loadPromotionStatus());
      }
    } on FirebaseException catch (error) {
      if (mounted) {
        setState(() => _rideError = _mensajeError(error));
      }
    } finally {
      if (mounted) setState(() => _solicitandoViaje = false);
    }
  }

  void _mostrarMensaje(String mensaje) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(mensaje)));
  }

  Future<void> _copiarCodigoInvitacion() async {
    final info = _referralInfo;
    if (info == null) return;

    try {
      await Clipboard.setData(ClipboardData(text: info.code));
      if (mounted) {
        _mostrarMensaje(
          'Código copiado. Envíalo a tu amigo para que lo aplique antes de su primer viaje.',
        );
      }
    } on PlatformException catch (error) {
      if (mounted) {
        setState(
          () => _rideError =
              'No se pudo copiar el código de invitación: ${error.message ?? error.code}',
        );
      }
    }
  }

  Future<void> _mostrarDialogoCodigoInvitacion() async {
    final controller = TextEditingController();
    var enviando = false;
    String? error;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Código de invitación'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Ingresa el código de tu amigo antes de completar tu primer '
                'viaje. Al finalizarlo, ambos recibirán \$10 USD de crédito.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                  labelText: 'Código',
                  border: const OutlineInputBorder(),
                  errorText: error,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed:
                  enviando ? null : () => Navigator.of(dialogContext).pop(),
              child: const Text('CANCELAR'),
            ),
            ElevatedButton(
              onPressed: enviando
                  ? null
                  : () async {
                      setDialogState(() {
                        enviando = true;
                        error = null;
                      });
                      try {
                        await _rideService.aplicarCodigoInvitacion(
                          code: controller.text,
                        );
                        if (!mounted || !dialogContext.mounted) return;
                        Navigator.of(dialogContext).pop();
                        await _loadReferralInfo();
                        if (mounted) {
                          _mostrarMensaje(
                            'Código aplicado. Al completar tu primer viaje, '
                            'ambos recibirán \$10 USD.',
                          );
                        }
                      } on FirebaseFunctionsException catch (exception) {
                        if (dialogContext.mounted) {
                          setDialogState(
                            () => error = exception.message ??
                                'No se pudo aplicar el código.',
                          );
                        }
                      } on FirebaseException catch (exception) {
                        if (dialogContext.mounted) {
                          setDialogState(
                            () => error = exception.message ??
                                'No se pudo aplicar el código.',
                          );
                        }
                      } on FormatException catch (exception) {
                        if (dialogContext.mounted) {
                          setDialogState(() => error = exception.message);
                        }
                      } finally {
                        if (dialogContext.mounted) {
                          setDialogState(() => enviando = false);
                        }
                      }
                    },
              child: Text(enviando ? 'VALIDANDO...' : 'APLICAR CÓDIGO'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
  }

  String _mensajeError(Object error) {
    if (error is FirebaseFunctionsException) {
      return 'Viajes (${error.code}): '
          '${error.message ?? 'No se pudo completar la operación.'}';
    }
    if (error is FirebaseException) {
      return 'Firebase (${error.code}): '
          '${error.message ?? 'No se pudo completar la operación.'}';
    }
    return 'No se pudo leer el viaje: $error';
  }

  Widget _buildRequestForm() {
    return ListView(
      children: [
        const Text(
          'Solicita tu viaje',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        if (_referralInfo != null) ...[
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Programa de invitaciones',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Cuando tu amigo complete su primer viaje, ambos '
                    'recibirán \$10 USD de crédito promocional.',
                  ),
                  const SizedBox(height: 4),
                  SelectableText('Tu código: ${_referralInfo!.code}'),
                  const SizedBox(height: 4),
                  Text(
                    'Crédito de invitaciones: '
                    '\$${_referralInfo!.creditBalance.toStringAsFixed(2)} USD',
                  ),
                  if (_referralInfo!.codeUsed) ...[
                    const SizedBox(height: 4),
                    const Text(
                      'Tu código ya fue utilizado por un amigo. Solo se puede usar una vez.',
                    ),
                  ],
                  if (_referralInfo!.referralApplied) ...[
                    const SizedBox(height: 4),
                    Text(
                      _referralInfo!.rewardGranted
                          ? 'Tu invitación ya fue recompensada.'
                          : 'Tu código de amigo está aplicado; falta completar tu primer viaje.',
                    ),
                  ],
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _referralInfo!.codeUsed
                        ? null
                        : _copiarCodigoInvitacion,
                    icon: Icon(
                      _referralInfo!.codeUsed
                          ? Icons.check_circle_outline
                          : Icons.copy,
                    ),
                    label: Text(
                      _referralInfo!.codeUsed
                          ? 'CÓDIGO YA UTILIZADO'
                          : 'INVITA A UN AMIGO Y GANA \$10',
                    ),
                  ),
                  if (_referralInfo!.canApplyReferral) ...[
                    TextButton.icon(
                      onPressed: _mostrarDialogoCodigoInvitacion,
                      icon: const Icon(Icons.card_giftcard),
                      label: const Text('TENGO UN CÓDIGO DE UN AMIGO'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ] else ...[
          const SizedBox(height: 12),
          const LinearProgressIndicator(),
        ],
        if (_completedRideCount == null) ...[
          const SizedBox(height: 12),
          const LinearProgressIndicator(),
        ] else if (_completedRideCount! < 3) ...[
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'Promoción RUNS: te quedan '
                '${3 - _completedRideCount!} viaje(s) con 40% de descuento '
                'en la tarifa.',
              ),
            ),
          ),
        ],
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: _paymentMethod,
          decoration: const InputDecoration(
            labelText: 'Método de pago',
            border: OutlineInputBorder(),
          ),
          items: const [
            DropdownMenuItem(value: 'cash', child: Text('Efectivo')),
            DropdownMenuItem(
              value: 'credit_card',
              child: Text('Tarjeta de crédito'),
            ),
            DropdownMenuItem(value: 'apple_pay', child: Text('Apple Pay')),
            DropdownMenuItem(value: 'google_pay', child: Text('Google Pay')),
          ],
          onChanged: (value) {
            if (value != null) setState(() => _paymentMethod = value);
          },
        ),
        const SizedBox(height: 8),
        const Text(
          'El método queda registrado, pero la app aún no procesa pagos '
          'con tarjeta ni wallets.',
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _origenController,
          decoration: const InputDecoration(
            labelText: 'Punto de Recogida (Origen)',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _destinoController,
          decoration: const InputDecoration(
            labelText: 'Destino en Miami',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _tarifaController,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Tarifa propuesta (USD)',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 20),
        ElevatedButton(
          onPressed: _solicitandoViaje || _completedRideCount == null
              ? null
              : _solicitarViaje,
          style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
          child: Text(
            _solicitandoViaje ? 'ENVIANDO...' : 'SOLICITAR VIAJE',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTripStatus(TripData trip) {
    final statusMessage = switch (trip.estado) {
      'BUSCANDO' => 'Buscando conductor cercano...',
      'ACEPTADO' => 'Un conductor aceptó tu viaje y va en camino.',
      'EN_CURSO' => 'Tu viaje está en curso.',
      'FINALIZADO' => 'Tu viaje ha finalizado.',
      _ => 'Estado del viaje: ${trip.estado}',
    };

    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'Estado: ${trip.estado}',
              style: const TextStyle(
                fontSize: 20,
                color: Colors.amber,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            Text('Origen: ${trip.origen}'),
            Text('Destino: ${trip.destino}'),
            Text(
              'Tarifa: \$${trip.tarifa.toStringAsFixed(2)} USD',
              style: const TextStyle(
                color: Colors.greenAccent,
                fontSize: 18,
              ),
            ),
            if (trip.passengerPromoApplied ||
                trip.promotionalEligibleAtRequest) ...[
              Text(
                'Descuento RUNS (40%): '
                '\$${trip.passengerDiscountAmount.toStringAsFixed(2)} USD',
                textAlign: TextAlign.center,
              ),
              Text(
                'Monto a pagar: '
                '\$${(trip.passengerAmountDue ?? trip.tarifa).toStringAsFixed(2)} USD',
                textAlign: TextAlign.center,
              ),
            ],
            if (trip.paymentMethod != null)
              Text(
                'Método seleccionado: ${_paymentMethodLabel(trip.paymentMethod!)}',
                textAlign: TextAlign.center,
              ),
            if (trip.conductorAsignado != null)
              Text('Conductor: ${trip.conductorAsignado}'),
            const SizedBox(height: 24),
            Text(
              statusMessage,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16),
            ),
            if (trip.estado == 'FINALIZADO') ...[
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () async {
                  await _tripSubscription?.cancel();
                  if (!mounted) return;
                  setState(() {
                    viajeActual = null;
                    _rideError = null;
                  });
                },
                child: const Text('SOLICITAR OTRO VIAJE'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _paymentMethodLabel(String method) => switch (method) {
        'cash' => 'Efectivo',
        'credit_card' => 'Tarjeta de crédito',
        'apple_pay' => 'Apple Pay',
        'google_pay' => 'Google Pay',
        _ => 'No especificado',
      };

  @override
  Widget build(BuildContext context) {
    final trip = viajeActual;
    final showForm = trip == null || trip.estado == 'FINALIZADO';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Passenger App - Miami'),
        actions: [
          // Botón para cerrar sesión de forma limpia
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
            },
            tooltip: 'Cerrar Sesión',
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            if (_rideError != null)
              MaterialBanner(
                content: Text(_rideError!),
                actions: [
                  TextButton(
                    onPressed: () => setState(() => _rideError = null),
                    child: const Text('CERRAR'),
                  ),
                ],
              ),
            SizedBox(
              height: 240,
              child: GoogleMap(
                initialCameraPosition: const CameraPosition(
                  target: LatLng(25.7617, -80.1918),
                  zoom: 14,
                ),
                myLocationEnabled: _hasLocationPermission,
                myLocationButtonEnabled: _hasLocationPermission,
              ),
            ),
            if (_locationMessage != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _locationMessage!,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            Expanded(
              child: showForm ? _buildRequestForm() : _buildTripStatus(trip),
            ),
          ],
        ),
      ),
    );
  }
}
