import 'package:flutter_test/flutter_test.dart';
import 'package:local_clipboard/core/content.dart';

void main() {
  test('file names reject invisible and bidirectional characters', () {
    for (final name in [
      'invoice\u202Efdp.exe',
      'a\u200Bb.txt',
      'a\uFEFF.txt',
      'dir/\u2066x.txt',
      'lone\uD800.txt',
    ]) {
      expect(() => validateRelativePath(name), throwsFormatException, reason: name);
    }
    validateRelativePath('folder/Ünïcode 😀.txt');
  });

  test('HTML with file or network references is flagged', () {
    expect(htmlLeaksCredentials('<img src="file://10.0.0.5/s/a.png">'), isTrue);
    expect(htmlLeaksCredentials(r'<img src="\\host\s\a.png">'), isTrue);
    expect(htmlLeaksCredentials('<img src="//host/a.png">'), isTrue);
    expect(htmlLeaksCredentials('<b>Hello</b> <a href="https://example.com">x</a>'), isFalse);
  });

  test('RTF with objects or fields is flagged', () {
    expect(rtfHasActiveContent(r'{\rtf1{\object\objautlink{\*\objdata 00}}}'), isTrue);
    expect(rtfHasActiveContent(r'{\rtf1{\field{\*\fldinst INCLUDEPICTURE "x"}}}'), isTrue);
    expect(rtfHasActiveContent(r'{\rtf1\ansi\b Hello\b0}'), isFalse);
  });

  test('risky executable file types are listed for the warning', () {
    final manifest = FileManifest.fromJson({
      'totalBytes': 2,
      'fileCount': 2,
      'roots': ['a.EXE', 'notes.txt', 'dir'],
      'entries': [
        {'i': 0, 'path': 'a.EXE', 'size': 1},
        {'i': 1, 'path': 'notes.txt', 'size': 1},
        {'i': 2, 'path': 'dir', 'dir': true},
      ],
    });
    expect(riskyFilePaths(manifest), ['a.EXE']);
  });

  test('unsafe rich text is dropped but plain text is kept', () {
    final payload = ClipPayload.fromJson({
      'kind': 'text',
      'text': 'hi',
      'html': '<img src="file://h/s/a.png">',
      'rtf': r'{\rtf1\b ok\b0}',
    });
    expect(payload.text, 'hi');
    expect(payload.html, isNull);
    expect(payload.rtf, isNotNull);
  });
}
