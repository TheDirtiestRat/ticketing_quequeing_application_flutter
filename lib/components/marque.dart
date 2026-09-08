import 'package:flutter/material.dart';

class CustomMarqueeText extends StatefulWidget {
  final String text;
  final TextStyle? textStyle;
  final Duration duration;

  const CustomMarqueeText({
    super.key,
    required this.text,
    this.textStyle,
    this.duration = const Duration(seconds: 8),
  });

  @override
  State<CustomMarqueeText> createState() => _CustomMarqueeTextState();
}

class _CustomMarqueeTextState extends State<CustomMarqueeText> {
  late ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    
    // Start scrolling after the first frame renders
    WidgetsBinding.instance.addPostFrameCallback((_) => _startScrolling());
  }

  Future<void> _startScrolling() async {
    while (_scrollController.hasClients) {
      // Scroll to max extent
      await _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: widget.duration,
        curve: Curves.linear,
      );
      
      // Jump back to start immediately once finished
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(0.0);
      }
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      controller: _scrollController,
      scrollDirection: Axis.horizontal,
      physics: const NeverScrollableScrollPhysics(), // Disable manual dragging
      child: Row(
        children: [
          Text(widget.text, style: widget.textStyle),
          const SizedBox(width: 50), // Gap before duplicate text
          Text(widget.text, style: widget.textStyle), // Repeat text for continuous feel
        ],
      ),
    );
  }
}