import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/account.dart';

/// The app's one Spliit Cloud instance, its Better Auth session cookies,
/// and the account those cookies belong to.
///
/// Spliit Cloud is account-bound: every group belongs to the account, not
/// to a URL. The old per-group `serverUrl` therefore becomes this one
/// instance address, and every request carries this cookie jar instead of
/// the old unauthenticated public group URL.
class CloudConnection {
  /// The public instance's API origin. The web app lives on
  /// `spliit.cloud`, but its API (tRPC and Better Auth) is served from
  /// `api.spliit.cloud`; invite links stay on the web origin.
  static const defaultBaseUrl = 'https://api.spliit.cloud';

  static const _keyBaseUrl = 'cloud_base_url';
  static const _keyCookies = 'cloud_session_cookies';
  static const _keyAccount = 'cloud_session_account';

  /// The connection the current app session uses. Set by [load] before any
  /// screen is shown; tests construct their own.
  static CloudConnection? current;

  String baseUrl;
  CloudAccount? account;

  final Map<String, String> _cookies;

  CloudConnection({
    required this.baseUrl,
    this.account,
    Map<String, String>? cookies,
  }) : _cookies = {...?cookies};

  bool get hasSession => _cookies.isNotEmpty;

  String? get cookieHeader {
    if (_cookies.isEmpty) return null;
    return _cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  /// Loads the persisted instance and session. Safe to call before any
  /// network request; a missing cookie simply means "signed out".
  static Future<CloudConnection> load() async {
    final prefs = await SharedPreferences.getInstance();
    final rawBase = prefs.getString(_keyBaseUrl);
    final base = normalizeBaseUrl(rawBase ?? defaultBaseUrl) ?? defaultBaseUrl;
    Map<String, String> cookies = const {};
    final rawCookies = prefs.getString(_keyCookies);
    if (rawCookies != null && rawCookies.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawCookies) as Map<String, dynamic>;
        cookies = {
          for (final entry in decoded.entries)
            if (entry.value is String) entry.key: entry.value as String,
        };
      } catch (_) {
        // A corrupt cookie blob is a signed-out session, not a crash.
      }
    }
    CloudAccount? account;
    final rawAccount = prefs.getString(_keyAccount);
    if (rawAccount != null && rawAccount.isNotEmpty) {
      try {
        account = CloudAccount.fromJson(
            jsonDecode(rawAccount) as Map<String, dynamic>);
      } catch (_) {
        account = null;
      }
    }
    final connection = CloudConnection(
      baseUrl: base,
      account: account,
      cookies: cookies,
    );
    current = connection;
    return connection;
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyBaseUrl, baseUrl);
    if (_cookies.isEmpty) {
      await prefs.remove(_keyCookies);
    } else {
      await prefs.setString(_keyCookies, jsonEncode(_cookies));
    }
    final account = this.account;
    if (account == null) {
      await prefs.remove(_keyAccount);
    } else {
      await prefs.setString(_keyAccount, jsonEncode(account.toJson()));
    }
  }

  Future<void> setBaseUrl(String value) async {
    final normalized = normalizeBaseUrl(value);
    if (normalized == null || normalized == baseUrl) return;
    baseUrl = normalized;
    // A session belongs to the instance that issued it.
    _cookies.clear();
    account = null;
    await save();
  }

  Future<void> clearSession() async {
    _cookies.clear();
    account = null;
    await save();
  }

  /// Consumes every Better Auth cookie a response set. Session reads slide
  /// the expiry and rotate the token, so this must run on every response.
  /// Returns whether the jar changed -- the caller persists it, because a
  /// rotation that only lives in memory is lost on the next launch.
  bool absorb(http.Response response) {
    final raw = response.headers['set-cookie'] ??
        response.headers['Set-Cookie'] ??
        '';
    if (raw.isEmpty) return false;
    var changed = false;
    final pattern =
        RegExp(r'((?:__Secure-)?better-auth\.[A-Za-z0-9_.-]+)=([^;,\s]*)');
    for (final match in pattern.allMatches(raw)) {
      final name = match.group(1)!;
      final value = match.group(2)!;
      if (value.isEmpty) {
        changed = _cookies.remove(name) != null || changed;
      } else if (_cookies[name] != value) {
        _cookies[name] = value;
        changed = true;
      }
    }
    return changed;
  }

  /// The browser origin Better Auth expects. The public API is on
  /// `api.spliit.cloud` while the web app (and its trusted origin) is
  /// `spliit.cloud`; a self-hosted instance serves both from one host.
  String get origin {
    final uri = Uri.parse(baseUrl);
    final host = uri.host == 'api.spliit.cloud' ? 'spliit.cloud' : uri.host;
    return Uri(
      scheme: uri.scheme,
      host: host,
      port: uri.hasPort ? uri.port : null,
    ).toString();
  }
}

/// `spliit.example.com` or `https://example.com/spliit/` -> a base URL with
/// a scheme and no trailing slash. Null when it has no usable host.
String? normalizeBaseUrl(String input) {
  var value = input.trim();
  if (value.isEmpty) return null;
  var uri = Uri.tryParse(value);
  if (uri == null || uri.host.isEmpty) {
    uri = Uri.tryParse('https://$value');
  }
  if (uri == null || uri.host.isEmpty) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  // The public web app and its API live on different hosts; entering the
  // name people know should work.
  if (uri.host == 'spliit.cloud') {
    return 'https://api.spliit.cloud';
  }
  final path = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    pathSegments: path,
  ).toString();
}
