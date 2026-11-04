import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:command_tools_contract/command_tools_contract.dart';
import 'package:crypto/crypto.dart';

/// Internal backend input. Session identity must come from the trusted caller.
final class CommandOutputSearchRequest {
  const CommandOutputSearchRequest({
    required this.sessionId,
    required this.runId,
    required this.toolInvocationId,
    required this.pattern,
    this.before = 3,
    this.after = 5,
    this.maxMatches = 10,
    this.cursor,
  });

  final String sessionId;
  final String runId;
  final String toolInvocationId;
  final String pattern;
  final int before;
  final int after;
  final int maxMatches;
  final String? cursor;
}

enum CommandOutputSearchStop {
  end,
  absent,
  capturing,
  matchLimit,
  textLimit,
  scanLimit,
  pageLimit,
  lineLimit,
  regexLimit,
}

/// One logical line, with a storage locator independent of its display excerpt.
/// LF is excluded from [text]; CR and all other captured characters are retained.
final class CommandOutputSearchLine {
  const CommandOutputSearchLine({
    required this.stream,
    required this.lineNumber,
    required this.chunk,
    required this.offset,
    required this.text,
    required this.excerptOffset,
    required this.length,
    required this.terminated,
    this.matchStart,
    this.matchEnd,
  });

  final String stream;
  final int lineNumber;
  final int chunk;
  final int offset;
  final String text;
  final int excerptOffset;
  final int length;
  final bool terminated;
  final int? matchStart;
  final int? matchEnd;

  bool get isMatch => matchStart != null;
  bool get truncatedBefore => excerptOffset != 0;
  bool get truncatedAfter => excerptOffset + text.length < length;

  List<Object?> _encode() => [
    stream,
    lineNumber,
    chunk,
    offset,
    text,
    excerptOffset,
    length,
    terminated,
  ];

  static CommandOutputSearchLine _decode(List<Object?> v) =>
      CommandOutputSearchLine(
        stream: v[0]! as String,
        lineNumber: v[1]! as int,
        chunk: v[2]! as int,
        offset: v[3]! as int,
        text: v[4]! as String,
        excerptOffset: v[5]! as int,
        length: v[6]! as int,
        terminated: v[7]! as bool,
      );
}

final class CommandOutputSearchResult {
  CommandOutputSearchResult({
    required this.captureState,
    required this.termination,
    required this.exitCode,
    required List<CommandOutputSearchLine> lines,
    required this.stop,
    required this.cursor,
    required this.contextIncomplete,
    required this.unsearchedLongLines,
    required this.regexTimeouts,
    required this.scannedCodeUnits,
    required this.storagePages,
  }) : lines = List.unmodifiable(lines);

  final String captureState;
  final String? termination;
  final int? exitCode;

  /// Unique within this response, stdout then stderr, ordered by stream line.
  /// Context can repeat across responses; only [CommandOutputSearchLine.isMatch]
  /// identifies an admitted hit in this response.
  final List<CommandOutputSearchLine> lines;
  final CommandOutputSearchStop stop;
  final String? cursor;
  final bool contextIncomplete;

  /// Cumulative across continuation, including a long line still being drained.
  final int unsearchedLongLines;
  final int regexTimeouts;
  final int scannedCodeUnits;
  final int storagePages;

  bool get reachedEnd => stop == CommandOutputSearchStop.end;
  bool get exhaustive =>
      reachedEnd && unsearchedLongLines == 0 && regexTimeouts == 0;
  bool get committedOutputOnly => captureState != 'complete';
  int get matchCount => lines.where((line) => line.isMatch).length;
}

/// Read-only, bounded searching over the existing Command Output reader.
///
/// Cursors are self-contained and authenticated by this engine instance. Keep
/// the engine for a backend generation; replacing it invalidates old cursors.
/// No search jobs, transcript cache, writer, or process authority are retained.
final class CommandOutputSearch {
  CommandOutputSearch(this.output)
    : _mac = Hmac(
        sha256,
        List.generate(32, (_) => math.Random.secure().nextInt(256)),
      );

  final CommandOutputService output;
  final Hmac _mac;
  static const int maximumPatternCodeUnits = 256;
  static const int maximumContextLines = 10;
  static const int maximumMatches = 10;
  static const int maximumResultCodeUnits = 16 * 1024;
  static const int maximumScanCodeUnits = 2 * 1024 * 1024;
  static const int maximumLineCodeUnits = 16 * 1024;
  static const int maximumExcerptCodeUnits = 512;
  static const int maximumPages = 128;
  static const int maximumLines = 16384;
  static const int maximumCursorCodeUnits = 192 * 1024;
  static const Duration regexBudget = Duration(seconds: 1);
  static const Duration regexLineTimeout = Duration(milliseconds: 250);

  Future<CommandOutputSearchResult> search(
    CommandOutputSearchRequest request,
  ) async {
    _validate(request);
    // Authenticate before any read. Even a valid cursor is never read authority.
    final saved = request.cursor == null ? null : _decode(request.cursor!);
    if (saved != null && saved[0] != _query(request)) {
      throw _failure(
        'invalid_search_cursor',
        'Cursor belongs to another request.',
      );
    }
    final capture = await output.getState(
      request.sessionId,
      request.runId,
      request.toolInvocationId,
    );
    final snapshot = _snapshot(capture);
    if (saved != null && saved[1] != snapshot) {
      throw _failure('stale_search_cursor', 'The retained capture changed.');
    }
    var state = saved == null
        ? _Position()
        : _Position.decode(saved[2]! as List<Object?>);
    final scan = _Scanner(output, request, capture, state);
    final lines = <(String, int), CommandOutputSearchLine>{};
    int textUnits = 0;
    int hits = 0;
    int after = state.after;
    int lineCount = 0;
    _Position? resumeAfterHit;
    var stop = CommandOutputSearchStop.end;
    var contextIncomplete = false;
    _RegexWorker? regex;
    final regexTime = Stopwatch();
    try {
      if (capture.state == 'absent' || capture.state == 'capturing') {
        stop = capture.state == 'absent'
            ? CommandOutputSearchStop.absent
            : CommandOutputSearchStop.capturing;
      } else if (![
        'complete',
        'failed',
        'interrupted',
      ].contains(capture.state)) {
        throw _failure('corrupt_capture', 'Unsupported capture state.');
      } else {
        while (state.stream < 2) {
          if (lineCount == maximumLines) {
            stop = CommandOutputSearchStop.lineLimit;
            break;
          }
          final checkpoint = state.copy();
          final line = await scan.nextLine();
          if (line == null) {
            if (scan.stop != null) {
              stop = scan.stop!;
              break;
            }
            // End of this pipe: fewer than requested context lines is complete.
            after = 0;
            if (resumeAfterHit != null) break;
            continue;
          }
          lineCount++;
          (int, int)? match;
          bool timedOut = false;
          if (resumeAfterHit == null && !line.long) {
            final remaining = regexBudget - regexTime.elapsed;
            if (remaining <= Duration.zero) {
              state = checkpoint;
              stop = CommandOutputSearchStop.regexLimit;
              break;
            }
            regex ??= await _RegexWorker.start(request.pattern);
            regexTime.start();
            try {
              match = await regex
                  .firstMatch(line.text)
                  .timeout(
                    remaining < regexLineTimeout ? remaining : regexLineTimeout,
                  );
            } on TimeoutException {
              state.regexTimeouts++;
              timedOut = true;
            } finally {
              regexTime.stop();
            }
          }
          final excerpt = line.excerpt(match);
          final additions = <CommandOutputSearchLine>[
            if (match != null) ...state.before,
            if (match != null || after > 0) excerpt,
          ];
          int addedUnits = 0;
          for (final addition in additions) {
            final old = lines[(addition.stream, addition.lineNumber)];
            // A context entry must never replace an already admitted hit.
            if (old == null || addition.isMatch) {
              addedUnits += addition.text.length - (old?.text.length ?? 0);
            }
          }
          if (textUnits + addedUnits > maximumResultCodeUnits) {
            state = checkpoint;
            stop = CommandOutputSearchStop.textLimit;
            break;
          }
          textUnits += addedUnits;
          for (final addition in additions) {
            final key = (addition.stream, addition.lineNumber);
            if (!lines.containsKey(key) || addition.isMatch) {
              lines[key] = addition;
            }
          }
          if (after > 0) after--;
          if (match != null) {
            hits++;
            after = request.after;
          }
          state.after = after;
          // Cursor context is bounded excerpts, not whole historical lines.
          state.before.add(CommandOutputSearchLine._decode(excerpt._encode()));
          if (state.before.length > request.before) state.before.removeAt(0);
          if (timedOut) {
            stop = CommandOutputSearchStop.regexLimit;
            break;
          }
          if (hits == request.maxMatches && resumeAfterHit == null) {
            resumeAfterHit = state.copy();
            stop = CommandOutputSearchStop.matchLimit;
          }
          if (resumeAfterHit != null && after == 0) break;
        }
        contextIncomplete = after > 0;
      }
    } finally {
      await regex?.close();
    }
    // Context lookahead is replayed next time, so it cannot consume future hits.
    if (resumeAfterHit != null && !contextIncomplete) resumeAfterHit.after = 0;
    state = resumeAfterHit ?? state;
    if (state.stream == 2) stop = CommandOutputSearchStop.end;
    final eligible = ![
      CommandOutputSearchStop.absent,
      CommandOutputSearchStop.capturing,
    ].contains(stop);
    final cursor = eligible && state.stream < 2
        ? _encode([_query(request), snapshot, state.encode()])
        : null;
    final ordered = lines.values.toList()
      ..sort((a, b) {
        final stream = (a.stream == 'stdout' ? 0 : 1).compareTo(
          b.stream == 'stdout' ? 0 : 1,
        );
        return stream != 0 ? stream : a.lineNumber.compareTo(b.lineNumber);
      });
    return CommandOutputSearchResult(
      captureState: capture.state,
      termination: capture.termination,
      exitCode: capture.exitCode,
      lines: ordered,
      stop: stop,
      cursor: cursor,
      contextIncomplete: contextIncomplete,
      unsearchedLongLines: state.longLines,
      regexTimeouts: state.regexTimeouts,
      scannedCodeUnits: scan.units,
      storagePages: scan.pages,
    );
  }

  static void _validate(CommandOutputSearchRequest r) {
    if ([
          r.sessionId,
          r.runId,
          r.toolInvocationId,
        ].any((id) => id.isEmpty || id.length > 1024) ||
        r.pattern.isEmpty ||
        r.pattern.length > maximumPatternCodeUnits ||
        r.pattern.contains(RegExp('[\x00\r\n\u2028\u2029]')) ||
        r.before < 0 ||
        r.before > maximumContextLines ||
        r.after < 0 ||
        r.after > maximumContextLines ||
        r.maxMatches < 1 ||
        r.maxMatches > maximumMatches) {
      throw _failure(
        'invalid_search',
        'Invalid search identity, pattern, or bounds.',
      );
    }
    try {
      RegExp(r.pattern);
    } on FormatException {
      throw _failure('invalid_search', 'Malformed regular expression.');
    }
  }

  static String _query(CommandOutputSearchRequest r) => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            r.sessionId,
            r.runId,
            r.toolInvocationId,
            r.pattern,
            r.before,
            r.after,
            r.maxMatches,
          ]),
        ),
      )
      .toString();

  String _encode(List<Object?> value) {
    final payload = utf8.encode(jsonEncode(value));
    final token =
        '${base64Url.encode(payload)}.${base64Url.encode(_mac.convert(payload).bytes)}';
    if (token.length > maximumCursorCodeUnits) {
      throw StateError('Search cursor exceeded its bound.');
    }
    return token;
  }

  List<Object?> _decode(String token) {
    try {
      if (token.length > maximumCursorCodeUnits) throw const FormatException();
      final parts = token.split('.');
      if (parts.length != 2) throw const FormatException();
      final payload = base64Url.decode(parts[0]);
      final signature = base64Url.decode(parts[1]);
      final expected = _mac.convert(payload).bytes;
      if (signature.length != expected.length) throw const FormatException();
      int difference = 0;
      for (var i = 0; i < expected.length; i++) {
        difference |= signature[i] ^ expected[i];
      }
      if (difference != 0) throw const FormatException();
      final value = jsonDecode(utf8.decode(payload)) as List<Object?>;
      if (value.length != 3) throw const FormatException();
      return value;
    } on Object {
      throw _failure(
        'invalid_search_cursor',
        'Malformed or foreign search cursor.',
      );
    }
  }
}

String _snapshot(CommandCaptureState s) => sha256
    .convert(
      utf8.encode(
        jsonEncode([
          s.sessionId,
          s.runId,
          s.toolInvocationId,
          s.state,
          s.version,
          s.highWater,
          s.totalCodeUnits,
        ]),
      ),
    )
    .toString();

CommandOutputFailure _failure(String code, String message) =>
    CommandOutputFailure(code: code, message: message, details: const {});

/// Mutable request-local checkpoint. Only authenticated engine output is decoded.
final class _Position {
  int stream = 0;
  int chunk = 1;
  int offset = 0;
  int streamUnits = 0;
  int lineNumber = 1;
  int startChunk = 0;
  int startOffset = 0;
  int length = 0;
  String prefix = '';
  bool long = false;
  int longLines = 0;
  int regexTimeouts = 0;
  int after = 0;
  final before = <CommandOutputSearchLine>[];

  List<Object?> encode() => [
    stream,
    chunk,
    offset,
    streamUnits,
    lineNumber,
    startChunk,
    startOffset,
    length,
    prefix,
    long,
    longLines,
    regexTimeouts,
    before.map((line) => line._encode()).toList(),
    after,
  ];
  static _Position decode(List<Object?> v) => _Position()
    ..stream = v[0]! as int
    ..chunk = v[1]! as int
    ..offset = v[2]! as int
    ..streamUnits = v[3]! as int
    ..lineNumber = v[4]! as int
    ..startChunk = v[5]! as int
    ..startOffset = v[6]! as int
    ..length = v[7]! as int
    ..prefix = v[8]! as String
    ..long = v[9]! as bool
    ..longLines = v[10]! as int
    ..regexTimeouts = v[11]! as int
    ..after = v[13]! as int
    ..before.addAll(
      (v[12]! as List<Object?>).map(
        (line) => CommandOutputSearchLine._decode(line! as List<Object?>),
      ),
    );
  _Position copy() => decode(encode());
}

final class _LogicalLine {
  _LogicalLine(
    this.stream,
    this.number,
    this.chunk,
    this.offset,
    this.text,
    this.length,
    this.long,
    this.terminated,
  );
  final String stream;
  final int number;
  final int chunk;
  final int offset;
  final String text;
  final int length;
  final bool long;
  final bool terminated;

  CommandOutputSearchLine excerpt((int, int)? match) {
    var start = math.max(
      0,
      math.min(
        (match?.$1 ?? 0) - 128,
        text.length - CommandOutputSearch.maximumExcerptCodeUnits,
      ),
    );
    if (start > 0 &&
        _low(text.codeUnitAt(start)) &&
        _high(text.codeUnitAt(start - 1))) {
      start--;
    }
    var end = math.min(
      text.length,
      start + CommandOutputSearch.maximumExcerptCodeUnits,
    );
    if (end < text.length &&
        end > start &&
        _high(text.codeUnitAt(end - 1)) &&
        _low(text.codeUnitAt(end))) {
      end--;
    }
    return CommandOutputSearchLine(
      stream: stream,
      lineNumber: number,
      chunk: chunk,
      offset: offset,
      text: text.substring(start, end),
      excerptOffset: start,
      length: length,
      terminated: terminated,
      matchStart: match?.$1,
      matchEnd: match?.$2,
    );
  }
}

bool _high(int unit) => unit >= 0xd800 && unit <= 0xdbff;
bool _low(int unit) => unit >= 0xdc00 && unit <= 0xdfff;

final class _Scanner {
  _Scanner(this.output, this.request, this.capture, this.position);
  final CommandOutputService output;
  final CommandOutputSearchRequest request;
  final CommandCaptureState capture;
  final _Position position;
  List<CommandOutputChunk> _page = const [];
  int _pageIndex = 0;
  int units = 0;
  int pages = 0;
  CommandOutputSearchStop? stop;

  Future<_LogicalLine?> nextLine() async {
    final p = position;
    while (p.chunk <= capture.highWater) {
      if (units == CommandOutputSearch.maximumScanCodeUnits) {
        stop = CommandOutputSearchStop.scanLimit;
        return null;
      }
      if (_pageIndex == _page.length) {
        if (pages == CommandOutputSearch.maximumPages) {
          stop = CommandOutputSearchStop.pageLimit;
          return null;
        }
        final page = await output.readAfter(
          request.sessionId,
          request.runId,
          request.toolInvocationId,
          p.chunk - 1,
          commandOutputPageChunks,
          commandOutputPageCodeUnits,
        );
        pages++;
        if (_snapshot(page.state) != _snapshot(capture)) {
          throw _failure(
            'stale_search_cursor',
            'The retained capture changed during search.',
          );
        }
        _page = page.chunks;
        _pageIndex = 0;
        if (_page.isEmpty) {
          throw _failure('corrupt_capture', 'Committed output contains a gap.');
        }
      }
      final chunk = _page[_pageIndex];
      if (chunk.cursor != p.chunk ||
          p.offset < 0 ||
          p.offset >= chunk.text.length) {
        throw _failure('corrupt_capture', 'Invalid retained search position.');
      }
      final end = math.min(
        chunk.text.length,
        p.offset + CommandOutputSearch.maximumScanCodeUnits - units,
      );
      final ownStream = chunk.stream == (p.stream == 0 ? 'stdout' : 'stderr');
      int newline = ownStream ? chunk.text.indexOf('\n', p.offset) : -1;
      if (newline >= end) newline = -1;
      final until = newline < 0 ? end : newline + 1;
      if (ownStream) {
        if (p.startChunk == 0) {
          p.startChunk = p.chunk;
          p.startOffset = p.offset;
        }
        final contentEnd = newline < 0 ? until : newline;
        final added = contentEnd - p.offset;
        if (!p.long &&
            p.length + added > CommandOutputSearch.maximumLineCodeUnits) {
          p.long = true;
          p.longLines++;
          p.prefix = p.prefix.substring(
            0,
            math.min(
              p.prefix.length,
              CommandOutputSearch.maximumExcerptCodeUnits + 1,
            ),
          );
        }
        final keep =
            (p.long
                ? CommandOutputSearch.maximumExcerptCodeUnits + 1
                : CommandOutputSearch.maximumLineCodeUnits) -
            p.prefix.length;
        if (keep > 0) {
          p.prefix += chunk.text.substring(
            p.offset,
            p.offset + math.min(keep, added),
          );
        }
        p.length += added;
      }
      units += until - p.offset;
      p.streamUnits += until - p.offset;
      p.offset = until;
      if (p.offset == chunk.text.length) {
        p.chunk++;
        p.offset = 0;
        _pageIndex++;
      }
      if (newline >= 0) return _finishLine(true);
    }
    if (p.streamUnits != capture.totalCodeUnits) {
      throw _failure(
        'corrupt_capture',
        'Retained output length disagrees with its header.',
      );
    }
    if (p.startChunk != 0) return _finishLine(false);
    p.stream++;
    p.chunk = 1;
    p.offset = 0;
    p.streamUnits = 0;
    p.lineNumber = 1;
    p.after = 0;
    p.before.clear();
    _page = const [];
    _pageIndex = 0;
    return null;
  }

  _LogicalLine _finishLine(bool terminated) {
    final p = position;
    final line = _LogicalLine(
      p.stream == 0 ? 'stdout' : 'stderr',
      p.lineNumber++,
      p.startChunk,
      p.startOffset,
      p.prefix,
      p.length,
      p.long,
      terminated,
    );
    p.startChunk = 0;
    p.startOffset = 0;
    p.length = 0;
    p.prefix = '';
    p.long = false;
    return line;
  }
}

/// Dart's backtracking regexp cannot be interrupted in its calling isolate.
/// This worker holds no storage or process authority and is killed on settlement.
final class _RegexWorker {
  _RegexWorker(this.isolate, this.port, this.replies, this.requests);
  final Isolate isolate;
  final ReceivePort port;
  final StreamIterator<Object?> replies;
  final SendPort requests;

  static Future<_RegexWorker> start(String pattern) async {
    final port = ReceivePort();
    final replies = StreamIterator<Object?>(port);
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn(
        _run,
        (port.sendPort, pattern),
        onError: port.sendPort,
        onExit: port.sendPort,
      );
      if (!await replies.moveNext().timeout(const Duration(seconds: 5)) ||
          replies.current is! SendPort) {
        throw StateError('Search regex worker did not start.');
      }
      return _RegexWorker(isolate, port, replies, replies.current! as SendPort);
    } on Object {
      isolate?.kill(priority: Isolate.immediate);
      port.close();
      await replies.cancel();
      rethrow;
    }
  }

  Future<(int, int)?> firstMatch(String text) async {
    requests.send(text);
    if (!await replies.moveNext() || replies.current is! List<Object?>) {
      throw StateError('Search regex worker failed.');
    }
    final value = replies.current! as List<Object?>;
    return value.isEmpty ? null : (value[0]! as int, value[1]! as int);
  }

  Future<void> close() async {
    isolate.kill(priority: Isolate.immediate);
    port.close();
    await replies.cancel();
  }

  static void _run((SendPort, String) input) {
    final port = ReceivePort();
    final regex = RegExp(input.$2);
    input.$1.send(port.sendPort);
    port.listen((Object? text) {
      final match = regex.firstMatch(text! as String);
      input.$1.send(match == null ? <int>[] : [match.start, match.end]);
    });
  }
}
