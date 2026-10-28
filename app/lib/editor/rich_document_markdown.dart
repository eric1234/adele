import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:markdown/markdown.dart' as md;

/// The editable Markdown subset. Exact source retention belongs to the owner.
///
/// Supports paragraphs, headings, simple quotes, nested lists, fenced code and
/// inline bold/italic/code/links. Indented/nested code, HTML, hard breaks,
/// reference definitions and other extensions are rejected rather than flattened.
abstract final class RichDocumentMarkdown {
  static const codeBlockType = 'code_block';

  /// Plain code text excludes the structural newline before the closing fence.
  static Node codeBlockNode({String text = '', String? language}) {
    if (language != null) _checkLanguage(language);
    return Node(
      type: codeBlockType,
      attributes: {
        'delta': (Delta()..insert(text)).toJson(),
        'language': ?language,
      },
    );
  }

  static Document decode(String source) {
    final fences = _FencedCodeSyntax();
    final parser = _parser(blockSyntaxes: [fences]);
    final lines = LineSplitter.split(source).map(md.Line.new).toList();
    final elements = parser.parseLineList(lines);
    // The upstream block parser trims Unicode/control whitespace before the AST
    // exists. Only literal code-body lines bypass it, not surrounding prose.
    for (final line in lines) {
      if (fences.literalLines.contains(line)) continue;
      for (final rune in line.content.runes) {
        if (rune == 9 || rune == 32) continue;
        if (String.fromCharCode(rune).trim().isEmpty) {
          throw const FormatException(
            'Raw Unicode/control whitespace requires entity spelling.',
          );
        }
      }
    }
    if (parser.linkReferences.isNotEmpty ||
        parser.footnoteReferences.isNotEmpty) {
      throw const FormatException('Reference definitions are not supported.');
    }
    final document = Document.blank();
    try {
      String? previousList;
      for (final element in elements) {
        final list =
            element is md.Element &&
                (element.tag == 'ul' || element.tag == 'ol')
            ? element.tag
            : null;
        if (list != null && list == previousList) {
          throw const FormatException(
            'Separate adjacent lists are not supported.',
          );
        }
        previousList = list;
        document.insert([document.root.children.length], _blocks(element));
      }
      if (document.root.children.isEmpty) {
        document.insert([0], [paragraphNode()]);
      }
      // Reject formatting we cannot subsequently serialize without changing it.
      encode(document);
      return document;
    } catch (_) {
      document.dispose();
      rethrow;
    }
  }

  static String encode(Document document) {
    if (document.root.type != 'page' || document.root.attributes.isNotEmpty) {
      throw const FormatException('Unsupported document root.');
    }
    // Do not use documentToMarkdown: its nested conversion reparents live nodes.
    return _writeBlocks(document.root.children);
  }
}

md.Document _parser({Iterable<md.BlockSyntax> blockSyntaxes = const []}) =>
    md.Document(
      blockSyntaxes: blockSyntaxes,
      extensionSet: md.ExtensionSet.gitHubFlavored,
      inlineSyntaxes: [_RejectHtml()],
      encodeHtml: false,
    );

class _FencedCodeSyntax extends md.FencedCodeBlockSyntax {
  final literalLines = <md.Line>{};

  @override
  md.Node parse(md.BlockParser parser) {
    if (parser.parentSyntax != null) {
      throw const FormatException('Nested code blocks are not supported.');
    }
    final opening = pattern.firstMatch(parser.current.content)!;
    final marker =
        opening.namedGroup('backtick') ?? opening.namedGroup('tilde')!;
    final indent = opening[1]!.length;
    final info =
        (opening.namedGroup('backtickInfo') ?? opening.namedGroup('tildeInfo')!)
            .replaceAll(RegExp(r'^[ \t]+|[ \t]+$'), '');
    if (info.isNotEmpty) _checkLanguage(info);
    final closing = RegExp(
      '^ {0,3}${RegExp.escape(marker[0])}{${marker.length},}[ \\t]*\$',
    );
    final body = <String>[];
    parser.advance();
    while (!parser.isDone) {
      final line = parser.current;
      if (closing.firstMatch(line.content)?.end == line.content.length) {
        parser.advance();
        // Joining, rather than trimming an upstream code AST, preserves blank
        // lines: zero/one empty body line is '', two empty body lines are '\n'.
        return md.Element.text(
          RichDocumentMarkdown.codeBlockType,
          body.join('\n'),
        )..attributes.addAll({if (info.isNotEmpty) 'language': info});
      }
      literalLines.add(line);
      var removed = 0;
      while (removed < indent &&
          removed < line.content.length &&
          line.content.codeUnitAt(removed) == 32) {
        removed++;
      }
      body.add(line.content.substring(removed));
      parser.advance();
    }
    throw const FormatException('Unclosed fenced code block.');
  }
}

void _checkLanguage(Object? language) {
  if (language is! String ||
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9_+.-]*$').firstMatch(language)?.end !=
          language.length) {
    throw const FormatException('Unsupported code language.');
  }
}

class _RejectHtml extends md.InlineHtmlSyntax {
  @override
  bool onMatch(md.InlineParser parser, Match match) {
    throw const FormatException('HTML is not supported.');
  }
}

List<Node> _blocks(md.Node input) {
  if (input is! md.Element) {
    throw const FormatException('HTML blocks are not supported.');
  }
  final children = input.children ?? const <md.Node>[];
  final tag = input.tag;
  if (tag == RichDocumentMarkdown.codeBlockType) {
    _checkKeys(input.attributes, {'language'});
    return [
      RichDocumentMarkdown.codeBlockNode(
        text: input.textContent,
        language: input.attributes['language'],
      ),
    ];
  }
  if (tag == 'ul' || tag == 'ol') {
    _checkKeys(input.attributes, tag == 'ol' ? {'start'} : {});
    final start = int.tryParse(input.attributes['start'] ?? '1');
    if (start == null || start < 0 || start > 999999999) {
      throw const FormatException('Unsupported list start.');
    }
    return [
      for (var i = 0; i < children.length; i++)
        _listItem(children[i], ordered: tag == 'ol', number: start + i),
    ];
  }
  _checkKeys(input.attributes, {});
  if (tag == 'p') return [paragraphNode(delta: _inlines(children))];
  if (RegExp(r'^h[1-6]$').hasMatch(tag)) {
    return [headingNode(level: int.parse(tag[1]), delta: _inlines(children))];
  }
  if (tag == 'blockquote') {
    if (children.isEmpty) return [quoteNode()];
    if (children.length != 1 ||
        children.single is! md.Element ||
        (children.single as md.Element).tag != 'p') {
      throw const FormatException(
        'Only single-paragraph quotes are supported.',
      );
    }
    final paragraph = children.single as md.Element;
    _checkKeys(paragraph.attributes, {});
    return [quoteNode(delta: _inlines(paragraph.children ?? []))];
  }
  throw FormatException('Unsupported Markdown block: $tag.');
}

Node _listItem(md.Node input, {required bool ordered, required int number}) {
  if (input is! md.Element || input.tag != 'li') {
    throw const FormatException('Unsupported list item.');
  }
  _checkKeys(input.attributes, {});
  final children = input.children ?? const <md.Node>[];
  final body = <md.Node>[];
  final nested = <Node>[];
  var hasNested = false;
  String? previousList;
  for (final child in children) {
    if (child is md.Element && (child.tag == 'ul' || child.tag == 'ol')) {
      if (previousList == child.tag) {
        throw const FormatException(
          'Separate adjacent lists are not supported.',
        );
      }
      previousList = child.tag;
      hasNested = true;
      nested.addAll(_blocks(child));
    } else {
      if (hasNested) {
        throw const FormatException(
          'List continuation blocks are not supported.',
        );
      }
      body.add(child);
    }
  }
  final List<md.Node> inline;
  if (body.length == 1 &&
      body.single is md.Element &&
      (body.single as md.Element).tag == 'p') {
    final paragraph = body.single as md.Element;
    _checkKeys(paragraph.attributes, {});
    inline = paragraph.children ?? [];
  } else {
    inline = body;
  }
  final delta = _inlines(inline);
  return ordered
      ? numberedListNode(delta: delta, number: number, children: nested)
      : bulletedListNode(delta: delta, children: nested);
}

Delta _inlines(List<md.Node> nodes, [Attributes attributes = const {}]) {
  final delta = Delta();
  for (final node in nodes) {
    if (node is md.Text) {
      delta.insert(node.text, attributes: attributes);
    } else if (node is md.Element) {
      final next = {...attributes};
      _checkKeys(node.attributes, node.tag == 'a' ? {'href'} : {});
      switch (node.tag) {
        case 'strong':
          next['bold'] = true;
        case 'em':
          next['italic'] = true;
        case 'code':
          next['code'] = true;
        case 'a':
          final href = node.attributes['href'];
          if (href == null || node.textContent.isEmpty) {
            throw const FormatException('Unsupported empty link.');
          }
          next['href'] = href;
        default:
          throw FormatException('Unsupported Markdown inline: ${node.tag}.');
      }
      delta.addAll(_inlines(node.children ?? [], next));
    } else {
      throw const FormatException('Unsupported inline content.');
    }
  }
  return delta;
}

void _checkKeys(Map<String, dynamic> attributes, Set<String> allowed) {
  if (attributes.keys.any((key) => !allowed.contains(key))) {
    throw const FormatException('Unsupported Markdown attributes.');
  }
}

bool _isList(Node node) =>
    node.type == 'bulleted_list' || node.type == 'numbered_list';

String _writeBlocks(List<Node> nodes) {
  final buffer = StringBuffer();
  var number = 1;
  for (var i = 0; i < nodes.length; i++) {
    final node = nodes[i];
    if (_isList(node)) {
      var previous = i - 1;
      while (previous >= 0 &&
          nodes[previous].type == 'paragraph' &&
          nodes[previous].delta?.isEmpty == true) {
        previous--;
      }
      if (previous >= 0 &&
          previous < i - 1 &&
          nodes[previous].type == node.type) {
        throw const FormatException(
          'Empty paragraphs cannot separate same-kind lists.',
        );
      }
    }
    final continuesList =
        i > 0 && _isList(node) && nodes[i - 1].type == node.type;
    if (i > 0) buffer.write(continuesList ? '\n' : '\n\n');
    if (node.type == 'numbered_list') {
      final start = node.attributes['number'];
      if (start != null && (start is! int || start < 0 || start > 999999999)) {
        throw const FormatException('Unsupported list number.');
      }
      number = continuesList ? number + 1 : (start as int? ?? 1);
      if (number > 999999999) {
        throw const FormatException('Unsupported list number.');
      }
    }
    _checkKeys(node.attributes, {
      'delta',
      if (node.type == RichDocumentMarkdown.codeBlockType) 'language',
      if (node.type == 'heading') 'level',
      if (node.type == 'numbered_list') 'number',
    });
    if (node.children.isNotEmpty &&
        (!_isList(node) || node.children.any((child) => !_isList(child)))) {
      throw const FormatException('Unsupported nested blocks.');
    }
    if (node.type == RichDocumentMarkdown.codeBlockType) {
      buffer.write(_writeCodeBlock(node));
      continue;
    }
    final delta = node.delta;
    if (delta == null) throw const FormatException('Block has no text.');
    final text = _writeInlines(delta, heading: node.type == 'heading');
    switch (node.type) {
      case 'paragraph':
        buffer.write(text);
      case 'heading':
        final level = node.attributes['level'];
        if (level is! int || level < 1 || level > 6) {
          throw const FormatException('Unsupported heading level.');
        }
        buffer.write('${'#' * level} $text');
      case 'quote':
        buffer.write(text.split('\n').map((line) => '> $line').join('\n'));
      case 'bulleted_list':
      case 'numbered_list':
        final marker = node.type == 'bulleted_list' ? '- ' : '$number. ';
        final indent = ' ' * marker.length;
        buffer.write('$marker${text.replaceAll('\n', '\n$indent')}');
        if (node.children.isNotEmpty) {
          final children = _writeBlocks(node.children);
          buffer.write('\n$indent${children.replaceAll('\n', '\n$indent')}');
        }
      default:
        throw FormatException('Unsupported document block: ${node.type}.');
    }
  }
  return buffer.toString();
}

String _writeCodeBlock(Node node) {
  final language = node.attributes['language'];
  if (node.attributes.containsKey('language')) _checkLanguage(language);
  final operations = node.attributes['delta'];
  if (operations is! List) throw const FormatException('Block has no text.');
  final buffer = StringBuffer();
  // Delta.fromJson silently drops unknown operations; validate before conversion.
  for (final operation in operations) {
    if (operation is! Map<String, dynamic>) {
      throw const FormatException('Unsupported code text operation.');
    }
    _checkKeys(operation, {'insert', 'attributes'});
    final text = operation['insert'];
    final attributes = operation['attributes'];
    if (text is! String ||
        (attributes != null && (attributes is! Map || attributes.isNotEmpty))) {
      throw const FormatException('Code blocks require plain text.');
    }
    buffer.write(text);
  }
  final text = buffer.toString();
  if (text.contains('\r')) {
    throw const FormatException('Code text requires LF line endings.');
  }
  var length = 3;
  for (final match in RegExp(r'`+').allMatches(text)) {
    if (match[0]!.length >= length) length = match[0]!.length + 1;
  }
  final fence = '`' * length;
  return '$fence${language ?? ''}\n$text\n$fence';
}

const _marks = ['href', 'bold', 'italic', 'code'];

String _writeInlines(Delta input, {required bool heading}) {
  final normalized = Delta();
  for (final operation in input) {
    if (operation is! TextInsert) {
      throw const FormatException('Unsupported text operation.');
    }
    final attributes = operation.attributes ?? {};
    _checkKeys(attributes, _marks.toSet());
    final clean = <String, dynamic>{};
    for (final key in _marks) {
      final value = attributes[key];
      if (value == null || (key != 'href' && value == false)) continue;
      if ((key == 'href' && value is! String) ||
          (key != 'href' && value != true)) {
        throw const FormatException('Unsupported inline attribute value.');
      }
      clean[key] = value;
    }
    normalized.insert(operation.text, attributes: clean);
  }
  var result = _writeRuns(normalized.cast<TextInsert>().toList(), 0);
  result = _edgeSpaces(result);
  // Empty lines must not split one text node into several Markdown blocks.
  result = result.replaceAllMapped(
    heading ? RegExp(r'\n') : RegExp(r'^\n|\n(?=\n)|\n$'),
    (_) => '&#10;',
  );
  // A local inline check catches delimiter ambiguities without a Markdown diff
  // engine or silently downgrading styles on punctuation and whitespace.
  if (_inlines(_parser().parseInline(result)) != normalized) {
    throw const FormatException(
      'Inline formatting cannot be represented safely.',
    );
  }
  return result;
}

String _writeRuns(List<TextInsert> runs, int mark) {
  if (mark == _marks.length) {
    return runs.map((run) => _escapeText(run.text)).join();
  }
  final key = _marks[mark];
  final buffer = StringBuffer();
  for (var start = 0; start < runs.length;) {
    final value = runs[start].attributes?[key];
    var end = start + 1;
    while (end < runs.length && runs[end].attributes?[key] == value) {
      end++;
    }
    final group = runs.sublist(start, end);
    if (key == 'code' && value == true) {
      final text = group.map((run) => run.text).join();
      if (text.contains('\n') || text.contains('\r')) {
        throw const FormatException('Multiline code spans are not supported.');
      }
      var length = 1;
      for (final match in RegExp(r'`+').allMatches(text)) {
        if (match[0]!.length >= length) length = match[0]!.length + 1;
      }
      final fence = '`' * length;
      final pad =
          text.startsWith('`') ||
          text.endsWith('`') ||
          (text.startsWith(' ') &&
              text.endsWith(' ') &&
              text.trim().isNotEmpty);
      buffer.write('$fence${pad ? ' ' : ''}$text${pad ? ' ' : ''}$fence');
    } else {
      final content = _writeRuns(group, mark + 1);
      if (value == null) {
        buffer.write(content);
      } else if (key == 'href') {
        final href = value as String;
        if (href.contains(RegExp(r'[\r\n]'))) {
          throw const FormatException(
            'Multiline link destinations are not supported.',
          );
        }
        final escaped = href
            .replaceAll('\\', '\\\\')
            .replaceAll('&', '&amp;')
            .replaceAll('<', '\\<')
            .replaceAll('>', '\\>');
        buffer.write('[$content](<$escaped>)');
      } else {
        final delimiter = key == 'bold' ? '**' : '*';
        buffer.write('$delimiter${_edgeSpaces(content)}$delimiter');
      }
    }
    start = end;
  }
  return buffer.toString();
}

String _edgeSpaces(String text) => text
    .split('\n')
    .map((line) {
      // The block parser uses String.trim, which includes Unicode whitespace that
      // the inline parser leaves intact. Protect exactly those edges, not just ASCII.
      final start = line.length - line.trimLeft().length;
      final end = line.trimRight().length;
      String entities(String value) =>
          value.runes.map((rune) => '&#$rune;').join();
      if (start >= end) return entities(line);
      return '${entities(line.substring(0, start))}${line.substring(start, end)}${entities(line.substring(end))}';
    })
    .join('\n');

String _escapeText(String text) => text
    .replaceAllMapped(
      RegExp(r'[\\`*_\[\]<>#&~|:@]'),
      (match) => '\\${match[0]}',
    )
    .replaceAll('www.', r'www\.')
    .replaceAll('\r', '&#13;')
    .replaceAllMapped(
      RegExp(r'^([ \t]*)([-+=])', multiLine: true),
      (match) => '${match[1]}\\${match[2]}',
    )
    .replaceAllMapped(
      RegExp(r'^([ \t]*\d+)([.)])(?=\s|$)', multiLine: true),
      (match) => '${match[1]}\\${match[2]}',
    );
