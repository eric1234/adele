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
    '``` a``b ```',
    '\u00e9 \u4e2d\u6587 \ud83d\ude42 e\u0301',
    'Cost \$5 and \$10',
    'https://example.invalid and www.example.invalid',
    'text&nbsp;',
    '# &nbsp;text&emsp;',
    '> ',
    '```dart\ncode\n```',
    '~~~\ncode\n~~~',
    'before\n\n```\na![b](c)\n```\n\nafter',
    '# Heading\n\nProse **bold** `inline`.\n\n```dart\n  code\n```\n\n'
        '- parent\n  - child\n\n~~~sh\n\techo ok\n~~~\n\n> quote',
    '```\nfirst\n```\n~~~json\nsecond\n~~~',
    '```\n```\n```\n\n\n```',
    '- before\n\n```\ncode\n```\n\n- after',
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

  for (final (source, text, language) in <(String, String, String?)>[
    ('```dart\nprint("hi");\n```', 'print("hi");', 'dart'),
    ('~~~ c++ \t\n    x\t \n~~~ \t', '    x\t ', 'c++'),
    ('```\n```', '', null),
    ('```\n\n```', '', null),
    ('```\n\n\n```', '\n', null),
    ('```\n\nline\n\n\n```', '\nline\n\n', null),
    (
      '```Dart-3.1\r\n  first\t \r\n\r\nsecond \r\n\r\n```\r\n',
      '  first\t \n\nsecond \n',
      'Dart-3.1',
    ),
    (
      '  ```dart\n  base\n    nested\n\tkeep\n \n  ```',
      'base\n  nested\n\tkeep\n',
      'dart',
    ),
    ('````\n```\n~~~\n```not a close\n````', '```\n~~~\n```not a close', null),
    (
      '~~~\n**bold** ![img](x) &amp;\n[ref]: url\n<div>html</div>\n~~~',
      '**bold** ![img](x) &amp;\n[ref]: url\n<div>html</div>',
      null,
    ),
    (
      '```\n\u00a0\u2003\n\u000btext\u000c\n\u0085\u2028\ufeff\n```',
      '\u00a0\u2003\n\u000btext\u000c\n\u0085\u2028\ufeff',
      null,
    ),
  ]) {
    test('fenced import retains plain code text: $source', () {
      final document = decode(source);
      final node = document.first!;
      expect(document.root.children, hasLength(1));
      expect(node.type, RichDocumentMarkdown.codeBlockType);
      expect(node.children, isEmpty);
      expect(node.attributes, {
        'delta': (Delta()..insert(text)).toJson(),
        'language': ?language,
      });
      final output = RichDocumentMarkdown.encode(document);
      expect(decode(output).first!.attributes, node.attributes);
    });
  }

  test('empty and newline-only code have distinct canonical exports', () {
    final empty = documentWith(RichDocumentMarkdown.codeBlockNode());
    final newline = documentWith(
      RichDocumentMarkdown.codeBlockNode(text: '\n'),
    );
    expect(RichDocumentMarkdown.encode(empty), '```\n\n```');
    expect(RichDocumentMarkdown.encode(newline), '```\n\n\n```');
    expect(
      decode(RichDocumentMarkdown.encode(empty)).first!.delta!.toPlainText(),
      '',
    );
    expect(
      decode(RichDocumentMarkdown.encode(newline)).first!.delta!.toPlainText(),
      '\n',
    );
  });

  for (final text in [
    'line',
    'line\n',
    '\nline\n\n',
    '\n\n',
    '  \t\n \t ',
    '    indented\n\tTabbed\ntrailing spaces  \n',
    '```\n~~~~~\n``````\n   ``` \t\n```dart\n',
    '**literal** `code` ![image](x) &amp; <b>html</b>',
    '\u00e9 \u4e2d\u6587 \ud83d\ude42 e\u0301',
    '\u00a0\u2003\n\u000btext\u000c\n\u0085\u2028\ufeff',
  ]) {
    test('edited code survives repeated export without mutation: $text', () {
      final document = documentWith(
        RichDocumentMarkdown.codeBlockNode(text: text, language: 'plain_text'),
      );
      final node = document.first!;
      final before = document.toJson();
      final output = RichDocumentMarkdown.encode(document);
      expect(decode(output).first!.delta!.toPlainText(), text);
      expect(decode(output).first!.attributes['language'], 'plain_text');
      expect(RichDocumentMarkdown.encode(document), output);
      expect(document.toJson(), before);
      expect(document.first, same(node));
      expect(node.parent, same(document.root));
      expect(node.path, [0]);
    });
  }

  test('export lengthens fences past every literal backtick run', () {
    final document = documentWith(
      RichDocumentMarkdown.codeBlockNode(
        text: '```\n`````\n~~~',
        language: 'sh',
      ),
    );
    expect(
      RichDocumentMarkdown.encode(document),
      '``````sh\n```\n`````\n~~~\n``````',
    );
  });

  test('empty paragraph spacers never become code content or join blocks', () {
    final document = Document(
      root: pageNode(
        children: [
          paragraphNode(),
          RichDocumentMarkdown.codeBlockNode(text: 'first', language: 'dart'),
          paragraphNode(),
          paragraphNode(),
          RichDocumentMarkdown.codeBlockNode(
            text: '\nsecond\n',
            language: 'json',
          ),
          paragraphNode(),
        ],
      ),
    );
    addTearDown(document.dispose);
    final before = document.toJson();
    final output = RichDocumentMarkdown.encode(document);
    final restored = decode(output);
    // As in prose-only exports, empty paragraph spacers normalize to Markdown
    // block separation, not literal code lines or persisted empty node identity.
    expect(restored.root.children.map((node) => node.type), [
      RichDocumentMarkdown.codeBlockType,
      RichDocumentMarkdown.codeBlockType,
    ]);
    expect(restored.root.children.map((node) => node.delta!.toPlainText()), [
      'first',
      '\nsecond\n',
    ]);
    expect(restored.root.children.map((node) => node.attributes['language']), [
      'dart',
      'json',
    ]);
    expect(document.toJson(), before);
  });

  test(
    'edited mixed tree reimports without changing code or list ownership',
    () {
      final document = decode(
        '# Before\n\n```dart\nold\n```\n\n- parent\n  - child\n\nAfter',
      );
      final code = document.nodeAtPath([1])!;
      const text = '\n\t```literal\n  a![b](c)  \n\n';
      code.updateAttributes({'delta': (Delta()..insert(text)).toJson()});
      final list = document.nodeAtPath([2])!;
      final child = document.nodeAtPath([2, 0])!;
      final before = document.toJson();
      final output = RichDocumentMarkdown.encode(document);
      final restored = decode(output);
      expect(restored.toJson(), before);
      expect(restored.nodeAtPath([1])!.delta!.toPlainText(), text);
      expect(RichDocumentMarkdown.encode(document), output);
      expect(document.toJson(), before);
      expect(document.nodeAtPath([1]), same(code));
      expect(document.nodeAtPath([2, 0]), same(child));
      expect(child.parent, same(list));
      expect(child.path, [2, 0]);
    },
  );

  test('plain code runs may be separate without being mutated or styled', () {
    final document = documentWith(
      Node(
        type: RichDocumentMarkdown.codeBlockType,
        attributes: {
          'delta': [
            {'insert': 'first\n', 'attributes': <String, dynamic>{}},
            {'insert': 'second'},
          ],
        },
      ),
    );
    final before = document.toJson();
    expect(RichDocumentMarkdown.encode(document), '```\nfirst\nsecond\n```');
    expect(document.toJson(), before);
  });

  test(
    'code construction validates optional language without rewriting it',
    () {
      for (final language in [
        '',
        'dart extra',
        'dart\n',
        'c#',
        '<script>',
        'a`b',
        r'a\b',
      ]) {
        expect(
          () => RichDocumentMarkdown.codeBlockNode(language: language),
          throwsFormatException,
        );
      }
    },
  );

  for (final source in [
    '```',
    '```dart\ncode',
    '```\ncode\n~~~',
    '````\ncode\n```',
    '~~~\ncode\n~~~ trailing',
    '```dart extra\ncode\n```',
    '~~~{.dart}\ncode\n~~~',
    '```a`b\ncode\n```',
    '~~~c#\ncode\n~~~',
    '~~~a\\b\ncode\n~~~',
    '~~~&#100;art\ncode\n~~~',
    '```dart\u00a0\ncode\n```',
    '```\ncode\n```\u00a0',
    '> ```dart\n> code\n> ```',
    '- ```dart\n  code\n  ```',
    '- item\n\n  ~~~\n  code\n  ~~~',
    '\tindented code',
    '    ```\n    code\n    ```',
    '\u000b\n```\ncode\n```',
    'before\u00a0\n\n```\n\u00a0code\n```',
    '```\n\u00a0code\n```\n\n# after\u2003',
    '```\ncode\n```\n\n![image](x)',
    '```\ncode\n```\n\n[unused]: https://example.invalid',
  ]) {
    test('rejects unsafe fenced import as a whole: $source', () {
      expect(() => RichDocumentMarkdown.decode(source), throwsFormatException);
    });
  }

  test('unsafe edited code fails explicitly without mutation', () {
    for (final attributes in <Map<String, dynamic>>[
      {},
      {'delta': 'not a delta'},
      {
        'delta': [42],
      },
      {
        'delta': [
          {
            'insert': {'image': 'x'},
          },
        ],
      },
      {
        'delta': [
          {'retain': 1},
        ],
      },
      {
        'delta': [
          {'delete': 1},
        ],
      },
      {
        'delta': [
          {'insert': 'code', 'unknown': true},
        ],
      },
      {
        'delta': [
          {
            'insert': 'code',
            'attributes': {'bold': true},
          },
        ],
      },
      {
        'delta': [
          {
            'insert': 'code',
            'attributes': {'code': false},
          },
        ],
      },
      {
        'delta': [
          {'insert': 'code', 'attributes': 'invalid'},
        ],
      },
      {
        'delta': [
          {'insert': 'code\r\n'},
        ],
      },
      {'delta': <dynamic>[], 'language': 42},
      {'delta': <dynamic>[], 'language': null},
      {'delta': <dynamic>[], 'language': ''},
      {'delta': <dynamic>[], 'language': 'dart extra'},
      {'delta': <dynamic>[], 'language': 'dart\n```'},
      {'delta': <dynamic>[], 'align': 'center'},
    ]) {
      final document = documentWith(
        Node(type: RichDocumentMarkdown.codeBlockType, attributes: attributes),
      );
      final before = document.toJson();
      expect(
        () => RichDocumentMarkdown.encode(document),
        throwsFormatException,
      );
      expect(document.toJson(), before);
    }
    for (final node in [
      Node(
        type: RichDocumentMarkdown.codeBlockType,
        attributes: {'delta': <dynamic>[]},
        children: [paragraphNode(text: 'child')],
      ),
      bulletedListNode(
        children: [RichDocumentMarkdown.codeBlockNode(text: 'nested')],
      ),
    ]) {
      final document = documentWith(node);
      expect(
        () => RichDocumentMarkdown.encode(document),
        throwsFormatException,
      );
    }
  });

  for (final source in [
    '    indented code',
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
