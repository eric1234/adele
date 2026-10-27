import 'package:adele_desktop/editor/rich_document_markdown.dart';
import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter_test/flutter_test.dart';

Document decode(String source) {
  final document = RichDocumentMarkdown.decode(source);
  addTearDown(document.dispose);
  return document;
}

Document documentWith(Node node) {
  final document = Document(root: pageNode(children: [node]));
  addTearDown(document.dispose);
  return document;
}

void main() {
  for (final source in [
    'First paragraph\n\nSecond paragraph',
    '# Heading\n\n## Smaller\n\n###### Smallest',
    'Title\n=====\n\nSubtitle\n--------',
    'plain **bold** *italic* ***both*** `code`',
    '**a *b* c** and *a **b** c*',
    '**a **b** c**',
    'a*i*b',
    '[link](https://example.invalid/a?x=1&y=2)',
    '[**bold** and *italic*](https://example.invalid/a_(b))',
    '- first\n- second\n  - child\n    3. grandchild\n- third',
    '3. first\n4. second\n   - child\n5. third',
    '- loose\n\n- list',
    '> quoted **text**\n> second line',
    '> first\n\n> separate',
    'before\nsoft break\n\nafter',
    r'\*literal\* \[text\] \<tag\> &amp; &#35;',
    '`` a`b `` and `  x  ` and `   `',
    '\u00e9 \u4e2d\u6587 \ud83d\ude42 e\u0301',
    'Cost \$5 and \$10',
    'https://example.invalid and www.example.invalid',
    'text&nbsp;',
    '# &nbsp;text&emsp;',
    '> ',
  ]) {
    test('supported semantic round trip: $source', () {
      final first = decode(source);
      final before = first.toJson();
      final output = RichDocumentMarkdown.encode(first);
      final second = decode(output);
      expect(second.toJson(), before);
      expect(first.toJson(), before, reason: 'Encoding must not mutate nodes.');
      expect(RichDocumentMarkdown.encode(first), output);
    });
  }

  test('newlines and whitespace have an explicit canonical export', () {
    final document = decode('First\r\nline\r\n\r\nSecond\r\n');
    expect(RichDocumentMarkdown.encode(document), 'First\nline\n\nSecond');
    expect(decode(' \t\n\n').first!.delta!.toPlainText(), '');
    expect(RichDocumentMarkdown.encode(decode('')), '');
  });

  test('nested identical formatting retains the outer attribute', () {
    final document = decode('**a **b** c**');
    expect(
      document.first!.delta,
      Delta()..insert('a b c', attributes: {'bold': true}),
    );
  });

  test('nested nodes retain parent, path and identity across export', () {
    final document = decode('- parent\n  - child\n    1. grandchild');
    final parent = document.first!;
    final child = document.nodeAtPath([0, 0])!;
    final grandchild = document.nodeAtPath([0, 0, 0])!;
    RichDocumentMarkdown.encode(document);
    expect(document.nodeAtPath([0, 0]), same(child));
    expect(document.nodeAtPath([0, 0, 0]), same(grandchild));
    expect(child.parent, same(parent));
    expect(grandchild.path, [0, 0, 0]);
  });

  for (final text in [
    'Hello!',
    '1.',
    '2)',
    ' literal * [x]',
    '*literal* _word_ **not bold** `not code`',
    '[label](https://example.invalid) ![alt](image)',
    '<b>not HTML</b> &amp; &#35; <!-- comment -->',
    '# not heading\n---\n===\n+ not list\n1. not numbered\n2) neither',
    'https://example.invalid www.example.invalid me@example.invalid',
    ' leading  and trailing \t',
    'first\nsecond',
    'first\n\nsecond',
    '\nfirst\n',
    'Windows C:\\path\\name and | table |',
    '\u00e9 \u4e2d\u6587 \ud83d\ude42 e\u0301',
    '\u00a0text\u2003',
    'text\u0085',
    '\u1680text\u2028',
    'text\ufeff',
    '\u000btext\u000c',
  ]) {
    test('edited plain text remains literal: $text', () {
      final document = documentWith(paragraphNode(text: text));
      final output = RichDocumentMarkdown.encode(document);
      final restored = decode(output);
      expect(restored.root.children, hasLength(1));
      expect(restored.first!.type, 'paragraph');
      expect(restored.first!.delta, document.first!.delta);
    });
  }

  test('style runs and inline code delimiters survive edited content', () {
    final delta = Delta()
      ..insert('one ', attributes: {'bold': true})
      ..insert('two', attributes: {'bold': true, 'italic': true})
      ..insert(' three', attributes: {'bold': true})
      ..insert(' ')
      ..insert(' `literal` ', attributes: {'code': true});
    final document = documentWith(paragraphNode(delta: delta));
    expect(decode(RichDocumentMarkdown.encode(document)).first!.delta, delta);
  });

  test('formatting toggled off does not become an unsupported attribute', () {
    final document = documentWith(
      paragraphNode(
        delta: Delta()
          ..insert('plain', attributes: {'bold': false, 'italic': null}),
      ),
    );
    expect(RichDocumentMarkdown.encode(document), 'plain');
  });

  test('list continuation text cannot escape its containing item', () {
    final document = documentWith(
      bulletedListNode(delta: Delta()..insert('first\nsecond')),
    );
    final output = RichDocumentMarkdown.encode(document);
    expect(output, '- first\n  second');
    expect(decode(output).first!.delta!.toPlainText(), 'first\nsecond');
  });

  test('empty separator cannot silently merge separate ordered lists', () {
    final document = Document(
      root: pageNode(
        children: [
          numberedListNode(number: 1, delta: Delta()..insert('A')),
          paragraphNode(),
          numberedListNode(number: 7, delta: Delta()..insert('B')),
        ],
      ),
    );
    addTearDown(document.dispose);
    expect(() => RichDocumentMarkdown.encode(document), throwsFormatException);
  });

  for (final source in [
    '```dart\ncode\n```',
    '~~~\ncode\n~~~',
    '    indented code',
    'before\n\n```\na![b](c)\n```\n\nafter',
    '![image](https://example.invalid/image.png)',
    '<div>important</div>\n\nrest',
    'before <b>bold</b> after',
    '<!-- comment -->',
    'before\n\n---\n\nafter',
    '| a | b |\n|---|---|\n| c | d |',
    '- [ ] task',
    '~~strike~~',
    '<u>underline</u>',
    '[label](https://example.invalid "title")',
    '[label][ref]\n\n[ref]: https://example.invalid',
    'text\n\n[unused]: https://example.invalid',
    'text\n\n[^unused]: important unused footnote',
    'text[^note]\n\n[^note]: footnote',
    '- first\n\n+ separate',
    '1. first\n\n8) separate',
    '- parent\n  - first\n  + separate',
    'first  \nsecond',
    '**first  \nsecond**',
    '> first\n>\n> second',
    '> > nested',
    '- first\n\n  second',
    '- first\n  - child\n\n  tail',
    '- # heading',
    'text\u00a0',
    '# \u00a0text\u2003',
    '> text\u2028',
  ]) {
    test('rejects unsupported input without partial success: $source', () {
      expect(() => RichDocumentMarkdown.decode(source), throwsFormatException);
    });
  }

  test('rejects unsupported document state rather than dropping it', () {
    for (final node in [
      Node(type: 'image', attributes: {'url': 'image'}),
      Node(
        type: 'code',
        attributes: {'delta': (Delta()..insert('code')).toJson()},
      ),
      paragraphNode(
        delta: Delta()..insert('styled', attributes: {'underline': true}),
      ),
      paragraphNode(attributes: {'align': 'center'}),
      paragraphNode(
        delta: Delta()..insert('link', attributes: {'href': false}),
      ),
      paragraphNode(children: [paragraphNode(text: 'child')]),
      paragraphNode(
        delta: Delta()..insert('line\nbreak', attributes: {'code': true}),
      ),
    ]) {
      final document = documentWith(node);
      final before = document.toJson();
      expect(
        () => RichDocumentMarkdown.encode(document),
        throwsFormatException,
      );
      expect(document.toJson(), before);
    }
  });

  test('rejects ambiguous emphasis rather than silently losing formatting', () {
    final document = documentWith(
      paragraphNode(
        delta: Delta()
          ..insert('a')
          ..insert('.', attributes: {'italic': true})
          ..insert('b'),
      ),
    );
    expect(() => RichDocumentMarkdown.encode(document), throwsFormatException);
  });
}
