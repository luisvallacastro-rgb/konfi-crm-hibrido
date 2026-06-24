import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:konfi_sales_app/main.dart';

void main() {
  testWidgets('registers seller and renders sales shell', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 900));
    await tester.pumpWidget(const KonfiSalesApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Bienvenido'), findsOneWidget);
    expect(find.text('Ingresar'), findsOneWidget);
    expect(find.text('Crear una cuenta nueva'), findsOneWidget);

    await tester.tap(find.text('Crear una cuenta nueva'));
    await tester.pumpAndSettle();

    expect(find.text('Crea tu cuenta'), findsOneWidget);
    expect(find.text('Registrarme y entrar'), findsOneWidget);

    await tester.enterText(find.byType(EditableText).at(0), 'Luis');
    await tester.enterText(find.byType(EditableText).at(1), 'Valla');
    await tester.enterText(find.byType(EditableText).at(2), '01234567');
    await tester.enterText(find.byType(EditableText).at(3), 'San Salvador');
    await tester.enterText(find.byType(EditableText).at(4), '+503 7000-0000');
    await tester.enterText(find.byType(EditableText).at(5), 'luis@konfi.local');
    await tester.enterText(find.byType(EditableText).at(6), '123456');
    await tester.enterText(find.byType(EditableText).at(7), '123456');
    await tester.ensureVisible(find.text('Registrarme y entrar'));
    await tester.tap(find.text('Registrarme y entrar'));
    await tester.pumpAndSettle();

    expect(find.text('Agenda de campo'), findsOneWidget);
    expect(find.text('Luis Valla - Ejecutivo de ventas'), findsOneWidget);
    expect(find.text('Agenda'), findsWidgets);
    expect(find.text('Pipeline'), findsWidgets);

    await tester.binding.setSurfaceSize(null);
  });
}
