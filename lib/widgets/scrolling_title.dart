import 'package:flutter/material.dart';

/// A one-line title that keeps a long name readable in a title bar.
///
/// Material cuts an over-long title off with an ellipsis, which leaves a
/// group's name unreadable. This measures the text against the width it is
/// given: when it fits, it is an ordinary [Text]; when it doesn't, the line
/// scrolls sideways on a loop, drawn twice with a gap between the copies so
/// that the wrap is seamless rather than a jump.
///
/// Where animations are switched off (Reduce motion), the ellipsis is kept
/// instead of motion, since a title that keeps moving is the worse outcome.
class ScrollingTitle extends StatelessWidget {
  const ScrollingTitle(this.text, {super.key, this.style, this.gap = 40});

  final String text;

  /// Merged over the title bar's own style, so a caller can change the size
  /// and keep the bar's colour and weight.
  final TextStyle? style;

  /// The blank space between the end of the line and its repeat.
  final double gap;

  @override
  Widget build(BuildContext context) {
    final base = DefaultTextStyle.of(context).style;
    final style = this.style == null ? base : base.merge(this.style);
    final scaler = MediaQuery.textScalerOf(context);
    final bold = MediaQuery.boldTextOf(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = _measure(context, style, scaler, bold: bold);
        if (!constraints.maxWidth.isFinite ||
            size.width <= constraints.maxWidth ||
            MediaQuery.disableAnimationsOf(context)) {
          return Text(text,
              style: style,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis);
        }
        return _Loop(
          text: text,
          style: style,
          textSize: size,
          viewport: constraints.maxWidth,
          gap: gap,
        );
      },
    );
  }

  /// The line as it would be laid out at one line, to see whether it fits.
  Size _measure(BuildContext context, TextStyle style, TextScaler scaler,
      {required bool bold}) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: bold ? style.merge(_bold) : style),
      textDirection: Directionality.of(context),
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final size = painter.size;
    painter.dispose();
    return size;
  }

  static const _bold = TextStyle(fontWeight: FontWeight.bold);
}

class _Loop extends StatefulWidget {
  const _Loop({
    required this.text,
    required this.style,
    required this.textSize,
    required this.viewport,
    required this.gap,
  });

  final String text;
  final TextStyle style;
  final Size textSize;
  final double viewport;
  final double gap;

  @override
  State<_Loop> createState() => _LoopState();
}

class _LoopState extends State<_Loop> with SingleTickerProviderStateMixin {
  /// How fast the line travels, in logical pixels a second: slow enough to
  /// read, fast enough that a very long name still comes round.
  static const _speed = 40.0;

  /// However short the overflow, one pass takes at least this long, so a
  /// name that overflows by a hair doesn't flick past.
  static const _slowest = Duration(seconds: 8);

  late final AnimationController _controller;

  /// One full turn: the line, then the gap, then the line again.
  double get _distance => widget.textSize.width + widget.gap;

  Duration get _duration {
    final ms = _distance / _speed * 1000;
    return ms > _slowest.inMilliseconds ? Duration(milliseconds: ms.round()) : _slowest;
  }

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _duration)..repeat();
  }

  @override
  void didUpdateWidget(covariant _Loop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.textSize.width != widget.textSize.width || oldWidget.gap != widget.gap) {
      _controller
        ..stop()
        ..duration = _duration
        ..value = 0
        ..repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final line = Text(
      widget.text,
      style: widget.style,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.visible,
    );
    return Semantics(
      label: widget.text,
      container: true,
      child: ExcludeSemantics(
        child: SizedBox(
          width: widget.viewport,
          height: widget.textSize.height,
          child: ClipRect(
            child: OverflowBox(
              alignment: AlignmentDirectional.centerStart,
              maxWidth: double.infinity,
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, child) {
                  final shift = _distance * _controller.value;
                  return Transform.translate(
                    offset: Offset(rtl ? shift : -shift, 0),
                    child: child,
                  );
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    line,
                    SizedBox(width: widget.gap),
                    line,
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
