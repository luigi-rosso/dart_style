// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.chunk;

import 'fast_hash.dart';
import 'rule.dart';

/// Tracks where a selection start or end point may appear in some piece of
/// text.
abstract class Selection {
  /// The chunk of text.
  String get text;

  /// The offset from the beginning of [text] where the selection starts, or
  /// `null` if the selection does not start within this chunk.
  int get selectionStart => _selectionStart;
  int _selectionStart;

  /// The offset from the beginning of [text] where the selection ends, or
  /// `null` if the selection does not start within this chunk.
  int get selectionEnd => _selectionEnd;
  int _selectionEnd;

  /// Sets [selectionStart] to be [start] characters into [text].
  void startSelection(int start) {
    _selectionStart = start;
  }

  /// Sets [selectionStart] to be [fromEnd] characters from the end of [text].
  void startSelectionFromEnd(int fromEnd) {
    _selectionStart = text.length - fromEnd;
  }

  /// Sets [selectionEnd] to be [end] characters into [text].
  void endSelection(int end) {
    _selectionEnd = end;
  }

  /// Sets [selectionEnd] to be [fromEnd] characters from the end of [text].
  void endSelectionFromEnd(int fromEnd) {
    _selectionEnd = text.length - fromEnd;
  }
}

/// A chunk of non-breaking output text terminated by a hard or soft newline.
///
/// Chunks are created by [LineWriter] and fed into [LineSplitter]. Each
/// contains some text, along with the data needed to tell how the next line
/// should be formatted and how desireable it is to split after the chunk.
///
/// Line splitting after chunks comes in a few different forms.
///
/// *   A "hard" split is a mandatory newline. The formatted output will contain
///     at least one newline after the chunk's text.
/// *   A "soft" split is a discretionary newline. If a line doesn't fit within
///     the page width, one or more soft splits may be turned into newlines to
///     wrap the line to fit within the bounds. If a soft split is not turned
///     into a newline, it may instead appear as a space or zero-length string
///     in the output, depending on [spaceWhenUnsplit].
/// *   A "double" split expands to two newlines. In other words, it leaves a
///     blank line in the output. Hard or soft splits may be doubled. This is
///     determined by [isDouble].
///
/// A split controls the leading spacing of the subsequent line, both
/// block-based [indent] and expression-wrapping-based [nesting].
class Chunk extends Selection {
  /// The literal text output for the chunk.
  String get text => _text;
  String _text;

  /// The number of levels of indentation from the left edge of the block that
  /// contains this chunk.
  ///
  /// For top level chunks that are not inside any block, this also includes
  /// leading indentation.
  int get indent => _indent;
  int _indent;

  /// The number of levels of expression nesting following this chunk.
  ///
  /// This is used to determine how much to increase the indentation when a
  /// line starts after this chunk. A single statement may be indented multiple
  /// times if the splits occur in more deeply nested expressions, for example:
  ///
  ///     // 40 columns                           |
  ///     someFunctionName(argument, argument,
  ///         argument, anotherFunction(argument,
  ///             argument));
  int get nesting => _nesting;
  int _nesting;

  /// If this chunk marks the beginning of a block, these are the chunks
  /// contained in the block.
  final blockChunks = <Chunk>[];

  /// Whether it's valid to add more text to this chunk or not.
  ///
  /// Chunks are built up by adding text and then "capped off" by having their
  /// split information set by calling [handleSplit]. Once the latter has been
  /// called, no more text should be added to the chunk since it would appear
  /// *before* the split.
  bool get canAddText => _rule == null;

  /// The [Rule] that controls when a split should occur after this chunk.
  ///
  /// Multiple splits may share a [Rule].
  Rule get rule => _rule;
  Rule _rule;

  /// Whether this chunk is always followed by a newline or whether the line
  /// splitter may choose to keep the next chunk on the same line.
  bool get isHardSplit => _rule is HardSplitRule;

  /// `true` if an extra blank line should be output after this chunk if it's
  /// split.
  bool get isDouble => _isDouble;
  bool _isDouble = false;

  /// If `true`, then the line after this chunk should always be at column
  /// zero regardless of any indentation or expression nesting.
  ///
  /// Used for multi-line strings and commented out code.
  bool get flushLeft => _flushLeft;
  bool _flushLeft;

  /// Whether this chunk should append an extra space if it does not split.
  ///
  /// This is `true`, for example, in a chunk that ends with a ",".
  bool get spaceWhenUnsplit => _spaceWhenUnsplit;
  bool _spaceWhenUnsplit = false;

  /// Whether this chunk marks the end of a range of chunks that can be line
  /// split independently of the following chunks.
  bool get canDivide {
    // Have to call markDivide() before accessing this.
    assert(_canDivide != null);
    return _canDivide;
  }
  bool _canDivide;

  /// The number of characters in this chunk when unsplit.
  int get length => _text.length + (spaceWhenUnsplit ? 1 : 0);

  /// The unsplit length of all of this chunk's block contents.
  ///
  /// Does not include this chunk's own length, just the length of its child
  /// block chunks (recursively).
  int get unsplitBlockLength {
    var length = 0;
    for (var chunk in blockChunks) {
      length += chunk.length + chunk.unsplitBlockLength;
    }

    return length;
  }

  /// The [Span]s that contain this chunk.
  final spans = <Span>[];

  /// Creates a new chunk starting with [_text].
  Chunk(this._text);

  /// Discard the split for the chunk and put it back into the state where more
  /// text can be appended.
  void allowText() {
    _rule = null;
  }

  /// Append [text] to the end of the split's text.
  void appendText(String text) {
    assert(canAddText);
    _text += text;
  }

  /// Forces this soft split to become a hard split.
  ///
  /// This is called on the soft splits owned by a rule that decides to harden
  /// when it finds out another hard split occurs within its chunks.
  void harden() {
    _rule = new HardSplitRule();
    spans.clear();
  }

  /// Finishes off this chunk with the given [rule] and split information.
  ///
  /// This may be called multiple times on the same split since the splits
  /// produced by walking the source and the splits coming from comments and
  /// preserved whitespace often overlap. When that happens, this has logic to
  /// combine that information into a single split.
  void applySplit(Rule rule, int indent, int nesting,
      {bool flushLeft, bool spaceWhenUnsplit, bool isDouble}) {
    if (flushLeft == null) flushLeft = false;
    if (spaceWhenUnsplit == null) spaceWhenUnsplit = false;
    if (isDouble == null) isDouble = false;

    if (isHardSplit || rule is HardSplitRule) {
      // A hard split always wins.
      _rule = rule;
    } else if (_rule == null) {
      // If the chunk hasn't been initialized yet, just inherit the rule.
      _rule = rule;
    }

    // Last split settings win.
    _flushLeft = flushLeft;
    _nesting = nesting;
    _indent = indent;

    _spaceWhenUnsplit = spaceWhenUnsplit;

    // Preserve a blank line.
    _isDouble = _isDouble || isDouble;
  }

  // Mark whether this chunk can divide the range of chunks.
  void markDivide(canDivide) {
    // Should only do this once.
    assert(_canDivide == null);

    _canDivide = canDivide;
  }

  void flattenNesting(Map<int, int> nestingMap) {
    _nesting = nestingMap[_nesting];
  }

  String toString() {
    var parts = [];

    if (text.isNotEmpty) parts.add(text);

    if (_indent != null) parts.add("indent:$_indent");
    if (_nesting != 0) parts.add("nesting:$_nesting");
    if (spaceWhenUnsplit) parts.add("space");
    if (_isDouble) parts.add("double");
    if (_flushLeft) parts.add("flush");

    if (_rule == null) {
      parts.add("(no split)");
    } else if (isHardSplit) {
      parts.add("hard");
    } else {
      parts.add(rule.toString());

      if (_rule.outerRules.isNotEmpty) {
        parts.add("-> ${_rule.outerRules.join(' ')}");
      }
    }

    return parts.join(" ");
  }
}

/// Constants for the cost heuristics used to determine which set of splits is
/// most desirable.
class Cost {
  /// The smallest cost.
  ///
  /// This isn't zero because we want to ensure all splitting has *some* cost,
  /// otherwise, the formatter won't try to keep things on one line at all.
  /// Almost all splits and spans use this. Greater costs tend to come from a
  /// greater number of nested spans.
  static const normal = 1;

  /// Splitting after a "=" both for assignment and initialization.
  static const assignment = 2;

  /// Splitting before the first argument when it happens to be a function
  /// expression with a block body.
  static const firstBlockArgument = 2;

  /// The series of positional arguments.
  static const positionalArguments = 2;

  /// Splitting inside the brackets of a list with only one element.
  static const singleElementList = 2;

  /// Splitting the internals of literal block arguments.
  ///
  /// Used to prefer splitting at the argument boundary over splitting the
  /// block contents.
  static const splitBlocks = 2;

  /// The cost of a single character that goes past the page limit.
  ///
  /// This cost is high to ensure any solution that fits in the page is
  /// preferred over one that does not.
  static const overflowChar = 1000;
}

/// The in-progress state for a [Span] that has been started but has not yet
/// been completed.
class OpenSpan {
  /// Index of the first chunk contained in this span.
  int get start => _start;
  int _start;

  /// The cost applied when the span is split across multiple lines or `null`
  /// if the span is for a multisplit.
  final int cost;

  OpenSpan(this._start, this.cost);

  String toString() => "OpenSpan($start, \$$cost)";
}

/// Delimits a range of chunks that must end up on the same line to avoid an
/// additional cost.
///
/// These are used to encourage the line splitter to try to keep things
/// together, like parameter lists and binary operator expressions.
///
/// This is a wrapper around the cost so that spans have unique identities.
/// This way we can correctly avoid paying the cost multiple times if the same
/// span is split by multiple chunks.
class Span extends FastHash {
  /// The cost applied when the span is split across multiple lines or `null`
  /// if the span is for a multisplit.
  final int cost;

  Span(this.cost);

  String toString() => "$id\$$cost";
}

/// A comment in the source, with a bit of information about the surrounding
/// whitespace.
class SourceComment extends Selection {
  /// The text of the comment, including `//`, `/*`, and `*/`.
  final String text;

  /// The number of newlines between the comment or token preceding this comment
  /// and the beginning of this one.
  ///
  /// Will be zero if the comment is a trailing one.
  final int linesBefore;

  /// Whether this comment is a line comment.
  final bool isLineComment;

  /// Whether this comment starts at column one in the source.
  ///
  /// Comments that start at the start of the line will not be indented in the
  /// output. This way, commented out chunks of code do not get erroneously
  /// re-indented.
  final bool isStartOfLine;

  SourceComment(this.text, this.linesBefore,
      {this.isLineComment, this.isStartOfLine});
}
