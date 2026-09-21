import 'package:flutter/material.dart';

/// Minimal host application. The destination adapter is exercised by the
/// integration test, not by this UI.
void main() {
  runApp(const Ticket13AdapterApp());
}

class Ticket13AdapterApp extends StatelessWidget {
  const Ticket13AdapterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: Scaffold(
        body: Center(child: Text('ticket 13 destination adapter probe')),
      ),
    );
  }
}
