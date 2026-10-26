import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/auth_service.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final AuthService _authService = AuthService();

  // Controladores de texto
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _nombreController = TextEditingController();
  final TextEditingController _documentoController = TextEditingController();
  final TextEditingController _anioVehiculoController = TextEditingController();

  bool _isLoginMode = true; // true = Iniciar Sesión, false = Registrarse
  bool _isLoading = false;
  String _errorMessage = '';

  void _submit() async {
    final isRegistration = !_isLoginMode;
    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });

    String? error;

    if (_isLoginMode) {
      // Iniciar sesión como conductor (con validación de saldo de -50 USD incluida)
      error = await _authService.iniciarSesionConductor(
        email: _emailController.text,
        password: _passwordController.text,
      );
    } else {
      final vehicleYear = int.tryParse(_anioVehiculoController.text.trim());
      if (vehicleYear == null) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Ingresa un año de vehículo válido.';
        });
        return;
      }
      // Registrarse como conductor con número de documento antifraude
      error = await _authService.registrarConductor(
        email: _emailController.text,
        password: _passwordController.text,
        nombre: _nombreController.text,
        numeroDocumento: _documentoController.text,
        vehicleYear: vehicleYear,
      );
    }

    if (!mounted) return;

    setState(() {
      _isLoading = false;
    });

    final errorMessage = error;
    if (errorMessage != null) {
      if (!mounted) return;
      setState(() {
        _errorMessage = errorMessage;
      });
    } else if (isRegistration) {
      setState(() {
        _isLoginMode = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Solicitud enviada. Podrás iniciar sesión cuando sea aprobada.',
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('¡Bienvenido, Conductor!')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isLoginMode
            ? 'Iniciar Sesión - Conductor'
            : 'Registro de Conductor'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Center(
          child: SingleChildScrollView(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Campos adicionales solo si es Modo Registro
                if (!_isLoginMode) ...[
                  TextField(
                    controller: _nombreController,
                    decoration: const InputDecoration(
                      labelText: 'Nombre Completo',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _documentoController,
                    decoration: const InputDecoration(
                      labelText: 'Número de Documento (Cédula/ID)',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _anioVehiculoController,
                    decoration: const InputDecoration(
                      labelText: 'Año del vehículo (mínimo 2014)',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  ),
                  const SizedBox(height: 12),
                ],
                TextField(
                  controller: _emailController,
                  decoration: const InputDecoration(
                    labelText: 'Correo Electrónico',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.emailAddress,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _passwordController,
                  decoration: const InputDecoration(
                    labelText: 'Contraseña',
                    border: OutlineInputBorder(),
                  ),
                  obscureText: true,
                ),
                const SizedBox(height: 20),
                if (_errorMessage.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 15.0),
                    child: Text(
                      _errorMessage,
                      style: const TextStyle(
                          color: Colors.red, fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center,
                    ),
                  ),
                _isLoading
                    ? const CircularProgressIndicator()
                    : SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: ElevatedButton(
                          onPressed: _submit,
                          style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.amber),
                          child: Text(
                            _isLoginMode
                                ? 'Entrar como Conductor'
                                : 'Registrarme',
                            style: const TextStyle(
                                fontSize: 16,
                                color: Colors.black,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () {
                    setState(() {
                      _isLoginMode = !_isLoginMode;
                      _errorMessage = '';
                    });
                  },
                  child: Text(
                    _isLoginMode
                        ? '¿No tienes cuenta de conductor? Regístrate'
                        : '¿Ya tienes cuenta? Inicia sesión',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
