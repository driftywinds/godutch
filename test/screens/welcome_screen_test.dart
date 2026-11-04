import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:godutch/api/spliit_client.dart';
import 'package:godutch/l10n/app_localizations.dart';
import 'package:godutch/main.dart' show goDutchAppBuilder;
import 'package:godutch/screens/welcome_screen.dart';
import 'package:godutch/theme.dart';

// Android's autofill -- Bitwarden, Keyguard, a keychain -- needs the sign-in
// and sign-up forms to say what their fields are, or it can't offer to fill
// them in (nor to save them once they work).
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  SpliitClient offline() => SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async => throw http.ClientException('offline')),
      );

  SpliitClient signingIn() => SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async => http.Response(
              jsonEncode({
                'user': {
                  'id': 'u1',
                  'name': 'Ken',
                  'email': 'ken@example.com',
                  'emailVerified': true,
                }
              }),
              200,
              headers: {'content-type': 'application/json'},
            )),
      );

  Future<void> pump(WidgetTester tester, Widget screen) => tester.pumpWidget(MaterialApp(
        theme: goDutchLightTheme,
        builder: goDutchAppBuilder,
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: screen,
      ));

  /// The form's fields, as the widgets that actually carry the autofill
  /// hints (a [TextFormField] keeps them to itself).
  List<TextField> fields(WidgetTester tester) =>
      tester.widgetList<TextField>(find.byType(TextField)).toList();

  /// The screens as they're reached in the app: pushed over whatever was
  /// there, so that popping them (the way sign-in ends) is a real pop.
  Future<void> pumpPushed(WidgetTester tester, Widget screen) async {
    await pump(
      tester,
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () =>
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen)),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  /// Records what the app tells Android's text input, so the autofill
  /// session's end can be checked. Call once the typing is done: until then
  /// the test binding's own handler does the work.
  List<MethodCall> captureTextInput(WidgetTester tester) {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.textInput,
        (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(tester.testTextInput.register);
    return calls;
  }

  Iterable<MethodCall> autofillEnds(List<MethodCall> calls) =>
      calls.where((c) => c.method == 'TextInput.finishAutofillContext');

  testWidgets('signing in: one autofill form, with the email and password hints', (tester) async {
    await pump(tester, SignInScreen(client: offline()));

    expect(find.byType(AutofillGroup), findsOneWidget);
    final [email, password] = fields(tester);
    expect(email.autofillHints, containsAll(<String>[AutofillHints.username, AutofillHints.email]));
    expect(password.autofillHints, <String>[AutofillHints.password]);
    expect(password.obscureText, isTrue);
    // A password manager shouldn't be fighting the keyboard's suggestions.
    expect(email.enableSuggestions, isFalse);
    expect(password.enableSuggestions, isFalse);
  });

  testWidgets('a working sign-in goes back, its credentials offered to the manager', (tester) async {
    await pumpPushed(tester, SignInScreen(client: signingIn()));
    await tester.enterText(find.byType(TextFormField).at(0), 'ken@example.com');
    await tester.enterText(find.byType(TextFormField).at(1), 'hunter2hunter2');

    final calls = captureTextInput(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    expect(find.byType(SignInScreen), findsNothing, reason: 'signed in: back to where it came from');
    // The form closing commits the autofill session: "save this password?"
    expect(autofillEnds(calls), isNotEmpty);
    expect(autofillEnds(calls).last.arguments, isTrue, reason: 'saved, so it can be filled next time');
  });

  testWidgets('signing up: a name, a new username and a new password to generate and save',
      (tester) async {
    await pump(tester, EmailSignUpScreen(client: offline()));

    expect(find.byType(AutofillGroup), findsOneWidget);
    final [name, email, password] = fields(tester);
    expect(name.autofillHints, <String>[AutofillHints.name]);
    expect(email.autofillHints, containsAll(<String>[AutofillHints.newUsername, AutofillHints.email]));
    expect(password.autofillHints, <String>[AutofillHints.newPassword]);
    expect(password.obscureText, isTrue);
  });
}
