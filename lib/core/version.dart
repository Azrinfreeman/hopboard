/// Strict SemVer comparison, including development builds before a release.
int? compareVersions(String a, String b) {
  List<String>? parts(String value) => RegExp(
    r'^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$',
  ).firstMatch(value)?.groups([1, 2, 3, 4]).map((v) => v ?? '').toList();
  final left = parts(a), right = parts(b);
  if (left == null || right == null) return null;
  for (var i = 0; i < 3; i++) {
    final order = int.parse(left[i]).compareTo(int.parse(right[i]));
    if (order != 0) return order;
  }
  if (left[3] == right[3]) return 0;
  if (left[3].isEmpty) return 1;
  if (right[3].isEmpty) return -1;
  final l = left[3].split('.'), r = right[3].split('.');
  for (var i = 0; i < l.length && i < r.length; i++) {
    final ln = int.tryParse(l[i]), rn = int.tryParse(r[i]);
    final order = ln != null && rn != null
        ? ln.compareTo(rn)
        : ln != null
        ? -1
        : rn != null
        ? 1
        : l[i].compareTo(r[i]);
    if (order != 0) return order;
  }
  return l.length.compareTo(r.length);
}
