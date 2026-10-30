import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/install_id.dart';

/// Tests for [newInstallId], the device id of the desktop apps.
void main() {
  final uuidV4 = RegExp(
    r'^[0-9A-F]{8}-[0-9A-F]{4}-4[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$',
  );

  test('is an upper-case version 4 UUID, like identifierForVendor', () {
    for (var i = 0; i < 200; i++) {
      expect(newInstallId(), matches(uuidV4));
    }
  });

  test('differs from one installation to the next', () {
    final ids = {for (var i = 0; i < 1000; i++) newInstallId()};
    expect(ids, hasLength(1000));
  });

  test('comes only from the random source', () {
    expect(newInstallId(Random(7)), newInstallId(Random(7)));
    expect(newInstallId(Random(7)), isNot(newInstallId(Random(8))));
  });
}
