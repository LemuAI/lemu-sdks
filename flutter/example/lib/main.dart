import 'package:flutter/widgets.dart';
import 'package:lemu_analytics/lemu_analytics.dart';

const _writeKey = String.fromEnvironment(
  'LEMU_WRITE_KEY',
  defaultValue: 'pk_test_example',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Lemu.instance.setup(
    _writeKey,
    options: const LemuOptions(debug: true),
  );
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return WidgetsApp(
      color: const Color(0xFF4F46E5),
      navigatorObservers: [LemuNavigatorObserver()],
      initialRoute: '/',
      pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
          PageRouteBuilder<T>(
        settings: settings,
        pageBuilder: (context, _, __) => builder(context),
      ),
      routes: {'/': (_) => const ProductScreen()},
    );
  }
}

class ProductScreen extends StatelessWidget {
  const ProductScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFFFFFFFF),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Button(
              label: 'Add to cart',
              onTap: () => Lemu.instance.track(LemuEvent.addToCart, {
                'value': 999,
                'currency': 'INR',
                'content_ids': ['SKU1'],
              }),
            ),
            const SizedBox(height: 16),
            _Button(
              label: 'Buy now',
              onTap: () => Lemu.instance.purchase(
                value: 999,
                currency: 'INR',
                orderId: 'demo-${DateTime.now().millisecondsSinceEpoch}',
                contents: const [
                  LemuContent(id: 'SKU1', quantity: 1, itemPrice: 999),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Button extends StatelessWidget {
  const _Button({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF4F46E5),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          textDirection: TextDirection.ltr,
          style: const TextStyle(color: Color(0xFFFFFFFF), fontSize: 16),
        ),
      ),
    );
  }
}
