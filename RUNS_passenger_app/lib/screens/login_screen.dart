import 'package:flutter/material.dart';
import '../services/auth_service.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final AuthService _authService = AuthService();
  
  // Controladores para capturar los datos de los inputs
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _nombreController = TextEditingController();
  final TextEditingController _documentoController = TextEditingController();

  bool _isLoginMode = true; // true = Iniciar Sesión, false = Registrarse
  bool _isLoading = false;
  String _errorMessage = '';

  void _submit() async {
    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });

    String? error;

    if (_isLoginMode) {
      // Iniciar sesión
      error = await _authService.iniciarSesionPasajero(
        email: _emailController.text,
        password: _passwordController.text,
      );
    } else {
      // Registrarse con el número de documento antifraude
      error = await _authService.registrarPasajero(
        email: _emailController.text,
        password: _passwordController.text,
        nombre: _nombreController.text,
        numeroDocumento: _documentoController.text,
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
    } else {
      // Éxito en la autenticación
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('¡Acceso exitoso!')),
      );
      // Aquí más adelante redirigiremos a la pantalla principal de mapas/viajes
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isLoginMode ? 'Iniciar Sesión - Pasajero' : 'Registro de Pasajero'),
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
                  Text(
                    _errorMessage,
                    style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                const SizedBox(height: 20),
                _isLoading
                    ? const CircularProgressIndicator()
                    : SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: ElevatedButton(
                          onPressed: _submit,
                          child: Text(
                            _isLoginMode ? 'Iniciar Sesión' : 'Registrarse',
                            style: const TextStyle(fontSize: 16),
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
                        ? '¿No tienes cuenta? Regístrate aquí'
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
