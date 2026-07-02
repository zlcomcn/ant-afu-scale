import 'package:flutter/material.dart';
import 'package:home_widget/home_widget.dart';
import 'ble/ble_service.dart';
import 'screens/scan_screen.dart';
import 'screens/measurement_screen.dart';
import 'screens/history_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  HomeWidget.registerInteractivityCallback(backgroundCallback);
  runApp(const ScaleApp());
}

@pragma('vm:entry-point')
void backgroundCallback(Uri? uri) async {
  // widget background update entry point (required by home_widget)
}

class ScaleApp extends StatelessWidget {
  const ScaleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '体脂秤',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const HistoryScreen(),
      onGenerateRoute: (settings) {
        switch (settings.name) {
          case '/scan':
            return MaterialPageRoute(
              builder: (_) => ScanScreen(bleService: BleScaleService.shared),
            );
          case '/measure':
            return MaterialPageRoute(
              builder: (_) =>
                  MeasurementScreen(bleService: BleScaleService.shared),
            );
          case '/history':
            return MaterialPageRoute(
              builder: (_) => const HistoryScreen(),
            );
          default:
            return MaterialPageRoute(
              builder: (_) => ScanScreen(bleService: BleScaleService.shared),
            );
        }
      },
    );
  }
}
