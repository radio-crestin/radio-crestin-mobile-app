/// [count] and the noun that goes with it, the way Romanian says it:
/// "1 stație", "5 stații", "23 de stații", "1.360 de stații".
///
/// Romanian puts "de" between a number and its noun when the number is 20
/// or more and its last two digits are 00 or 20 to 99, so "101 stații" but
/// "120 de stații".
String romanianCount(int count, {required String one, required String many}) {
  if (count == 1) return '1 $one';
  final lastTwo = count % 100;
  final withDe = count >= 20 && (lastTwo == 0 || lastTwo >= 20);
  return '${formatThousands(count)} ${withDe ? 'de ' : ''}$many';
}

/// [value] with a dot between groups of thousands, as Romanian writes it:
/// 1360 becomes "1.360".
String formatThousands(int value) {
  final digits = value.abs().toString();
  final buffer = StringBuffer(value < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write('.');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}
