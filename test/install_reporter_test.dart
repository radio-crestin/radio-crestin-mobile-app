import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/install_reporter.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _installed = DateTime.utc(2026, 11, 4, 9, 30);
final _reinstalled = DateTime.utc(2026, 11, 20, 18);

Future<SharedPreferences> _prefs([Map<String, Object> values = const {}]) {
  SharedPreferences.setMockInitialValues(values);
  return SharedPreferences.getInstance();
}

void main() {
  late List<DateTime> reports;

  setUp(() => reports = []);

  Future<bool> reportOnce(
    SharedPreferences prefs,
    DateTime? installTime, {
    bool knownDevice = false,
  }) =>
      InstallReporter.reportOnce(
        prefs: prefs,
        installTime: installTime,
        knownDevice: knownDevice,
        report: reports.add,
      );

  test('a fresh install is reported once', () async {
    final prefs = await _prefs();
    expect(await reportOnce(prefs, _installed), isTrue);
    expect(await reportOnce(prefs, _installed), isFalse);
    expect(reports, [_installed]);
  });

  test('a reinstall, with a new install time, is reported again', () async {
    final prefs = await _prefs({
      InstallReporter.reportedKey: _installed.millisecondsSinceEpoch,
    });
    expect(await reportOnce(prefs, _reinstalled), isTrue);
    expect(reports, [_reinstalled]);
  });

  test('an update from a version without reports stays silent', () async {
    final prefs = await _prefs();
    expect(await reportOnce(prefs, _installed, knownDevice: true), isFalse);
    expect(reports, isEmpty);
    expect(prefs.getInt(InstallReporter.reportedKey),
        _installed.millisecondsSinceEpoch);
  });

  test('a restored backup with an older install time reports', () async {
    final prefs = await _prefs({
      InstallReporter.reportedKey: _installed.millisecondsSinceEpoch,
    });
    expect(await reportOnce(prefs, _reinstalled, knownDevice: true), isTrue);
  });

  test('an unknown install time reports nothing', () async {
    final prefs = await _prefs();
    expect(await reportOnce(prefs, null), isFalse);
    expect(reports, isEmpty);
  });
}
