import 'package:flutter/material.dart';

void main() {
  runApp(const DriverApp());
}

class DriverApp extends StatelessWidget {
  const DriverApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Miami Ride Driver',
      theme: ThemeData(
        primarySwatch: Colors.green,
        scaffoldBackgroundColor: const Color(0xFF121212), // Fondo oscuro profesional tipo app de transporte
      ),
      home: const DriverHomeScreen(),
    );
  }
}

class DriverHomeScreen extends StatefulWidget {
  const DriverHomeScreen({super.key});

  @override
  State<DriverHomeScreen> createState() => _DriverHomeScreenState();
}

class _DriverHomeScreenState extends State<DriverHomeScreen> {
  // Simulamos el saldo actual del conductor en la billetera
  double saldoBilletera = -15.0; // Usando el margen negativo de confianza
  bool estaConectado = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Miami Ride - Conductor'),
        backgroundColor: Colors.black87,
        actions: [
          Switch(
            value: estaConectado,
            activeColor: Colors.green,
            onChanged: (value) {
              setState(() {
                estaConectado = value;
              });
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // TARJETA DE ESTADO FINANCIERO (BILLETERA & SALDO NEGATIVO)
            Card(
              color: const Color(0xFF1E1E1E),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(20.0),
                child: Column(
                  children: [
                    const Text(
                      'SALDO DIGITAL EN BILLETERA',
                      style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '\$${saldoBilletera.toStringAsFixed(2)} USD',
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        color: saldoBilletera >= 0 ? Colors.greenAccent : Colors.orangeAccent,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      saldoBilletera >= 0 
                          ? 'Estado: Al día (Recibiendo efectivo)' 
                          : 'Usando margen negativo (Límite: -\$50.00)',
                      style: const TextStyle(color: Colors.white54, fontSize: 13),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed: () {
                        // Acción de recargar saldo
                        setState(() {
                          saldoBilletera = 20.0; // Simulamos una recarga exitosa
                        });
                      },
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                      icon: const Icon(icon: Icons.account_balance_wallet, color: Colors.white),
                      label: const Text('Recargar Saldo (Simulación)', style: TextStyle(color: Colors.white)),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            
            // ESTADO DE CONEXIÓN EN LA CALLE
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Text(
                    estaConectado 
                        ? '🟢 Buscando pasajeros cercanos en Miami...' 
                        : '🔴 Estás desconectado (No recibes viajes)',
                    style: const TextStyle(color: Colors.white70, fontSize: 16),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
