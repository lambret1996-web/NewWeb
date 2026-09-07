import 'package:flutter/material.dart';

/// 屏幕左边缘右滑返回手势（观察式，不消费触摸，不影响页面内部滚动）。
///
/// 作为 CupertinoPageRoute 原生交互式返回手势的双保险：
/// 在 WKWebView 平台视图干扰导致原生边缘手势失效时，仍可边缘右滑返回。
/// 同时避免与原生手势重复触发（检测到交互式返回进行中则不再 pop）。
class EdgeBackGesture extends StatefulWidget {
  const EdgeBackGesture({
    super.key,
    required this.child,
    this.edgeWidth = 24,
    this.threshold = 56,
  });

  final Widget child;

  /// 左边缘识别宽度（pt）。
  final double edgeWidth;

  /// 触发返回的最小水平位移（pt）。
  final double threshold;

  @override
  State<EdgeBackGesture> createState() => _EdgeBackGestureState();
}

class _EdgeBackGestureState extends State<EdgeBackGesture> {
  Offset? _downPos;
  DateTime? _downTime;
  bool _atEdge = false;

  void _onDown(PointerDownEvent e) {
    final size = context.size;
    if (size == null) return;
    _downPos = e.localPosition;
    _downTime = DateTime.now();
    _atEdge = e.localPosition.dx <= widget.edgeWidth;
  }

  void _onUp(PointerUpEvent e) {
    final start = _downPos;
    _downPos = null;
    if (!_atEdge || start == null) {
      _atEdge = false;
      return;
    }
    _atEdge = false;
    final dx = e.localPosition.dx - start.dx;
    final dy = (e.localPosition.dy - start.dy).abs();
    final duration = DateTime.now().difference(_downTime ?? DateTime.now());
    // 水平右滑占主导、超过阈值、时长合理
    if (dx > widget.threshold && dx > dy &&
        duration.inMilliseconds <= 800) {
      // 原生交互式返回正在进行时不重复 pop
      final route = ModalRoute.of(context);
      final anim = route?.animation;
      if (anim != null && anim.value < 0.999) return;
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onDown,
      onPointerUp: _onUp,
      onPointerCancel: (_) {
        _downPos = null;
        _atEdge = false;
      },
      child: widget.child,
    );
  }
}
