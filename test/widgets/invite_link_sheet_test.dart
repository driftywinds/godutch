import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:godutch/l10n/app_localizations.dart';
import 'package:godutch/widgets/invite_link_sheet.dart';
import 'package:qr_flutter/qr_flutter.dart';

void main() {
  testWidgets('the invite sheet renders the invite as a QR code', (tester) async {
    const url = 'https://spliit.cloud/groups/g1?invite=abcdefghijklmnop';
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () => showInviteLinkSheet(context, inviteUrl: url),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    final qr = tester.widget<QrImageView>(find.byType(QrImageView));
    expect(qr, isNotNull);
    expect(find.text(url), findsOneWidget);
  });
}
