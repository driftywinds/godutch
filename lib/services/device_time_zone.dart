import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:timezone/timezone.dart' as tz;

/// The phone's IANA time zone, and the date conversions Spliit Cloud needs.
///
/// Cloud stores an expense as a UTC instant plus the IANA zone it was
/// entered in. Reading the instant back as a plain local date would move
/// an expense across midnight for anyone in a different zone, so every
/// date is rendered through the expense's own zone.
class DeviceTimeZone {
  DeviceTimeZone._();

  static String? _name;
  static bool _databaseInitialized = false;
  static final Map<String, tz.Location> _locations = {};

  /// IANA renamed several zones; Android and older servers still send the
  /// old names. The bundled database only carries the current ones.
  static const Map<String, String> _aliases = {
    'Asia/Calcutta': 'Asia/Kolkata',
    'Asia/Katmandu': 'Asia/Kathmandu',
    'Asia/Rangoon': 'Asia/Yangon',
    'Asia/Saigon': 'Asia/Ho_Chi_Minh',
    'Europe/Kiev': 'Europe/Kyiv',
    'America/Godthab': 'America/Nuuk',
    'Pacific/Ponape': 'Pacific/Pohnpei',
    'Pacific/Truk': 'Pacific/Chuuk',
    'US/Eastern': 'America/New_York',
    'US/Central': 'America/Chicago',
    'US/Mountain': 'America/Denver',
    'US/Pacific': 'America/Los_Angeles',
  };

  static String canonicalName(String name) => _aliases[name] ?? name;

  /// Pins the phone's zone for tests: a widget test has no platform channel,
  /// and asking for the real name there waits on a timeout timer.
  @visibleForTesting
  static void useName(String name) {
    _initializeDatabase();
    location(name);
    _name = name;
  }

  static void _initializeDatabase() {
    if (_databaseInitialized) return;
    timezone_data.initializeTimeZones();
    _databaseInitialized = true;
  }

  /// The IANA name reported by the platform, e.g. `Asia/Calcutta`; falls
  /// back to UTC if the platform channel is unavailable (tests, desktop).
  static Future<String> name() async {
    final cached = _name;
    if (cached != null) return cached;
    try {
      final info = await FlutterTimezone.getLocalTimezone()
          .timeout(const Duration(seconds: 2));
      final identifier = info.identifier;
      _initializeDatabase();
      // Only an identifier this build's timezone database knows is usable
      // to the server; an unknown one would make every write fail. Send
      // the canonical name where the platform still uses a renamed zone.
      final location = tz.getLocation(canonicalName(identifier));
      _name = location.name;
      return _name!;
    } catch (_) {
      _name = 'UTC';
      return 'UTC';
    }
  }

  /// A location for [name], or UTC when it isn't in the database.
  static tz.Location location(String? name) {
    _initializeDatabase();
    final key = name == null || name.isEmpty ? 'UTC' : name;
    return _locations.putIfAbsent(key, () {
      try {
        return tz.getLocation(canonicalName(key));
      } catch (_) {
        return tz.UTC;
      }
    });
  }

  /// The calendar date of [instant] in [zone].
  static DateTime dateInZone(DateTime instant, String? zone) {
    final local = tz.TZDateTime.from(instant, location(zone));
    return DateTime(local.year, local.month, local.day);
  }

  /// Noon on [date] in [zone], as the UTC instant Cloud stores. Noon keeps
  /// the calendar date stable whatever offset the zone has.
  static DateTime instantForDate(DateTime date, String? zone) {
    final local = tz.TZDateTime(
        location(zone), date.year, date.month, date.day, 12);
    return local.toUtc();
  }

  /// A stable local name for a zone name, used in tests.
  static String normalize(String? name) => location(name).name;
}
