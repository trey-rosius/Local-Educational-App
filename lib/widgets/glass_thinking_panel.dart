import 'dart:ui';

import 'package:flutter/material.dart';

import 'glass_theme.dart';

/// Glass-themed, collapsible panel that displays Gemma 4's reasoning
/// (the `ThinkingResponse` channel from flutter_gemma) above its final
/// answer. Defaults to collapsed once thinking is done; expanded while
/// the model is still actively thinking so the user sees it in real-time.
///
/// This is a StatefulWidget because each instance manages its own
/// expanded/collapsed state independently of the surrounding chat.
class GlassThinkingPanel extends StatefulWidget {
  const GlassThinkingPanel({
    super.key,
    required this.content,
    this.isStreaming = false,
  });

  /// The thinking text. Updated incrementally during streaming.
  final String content;

  /// If true, the model is still emitting thinking tokens. Shows a pulse
  /// + spinner indicator and defaults the panel to expanded.
  final bool isStreaming;

  @override
  State<GlassThinkingPanel> createState() => _GlassThinkingPanelState();
}

class _GlassThinkingPanelState extends State<GlassThinkingPanel>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;
  late AnimationController _pulse;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    // Auto-expand while thinking is still streaming so the user sees
    // tokens appear live.
    _expanded = widget.isStreaming;
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _pulseAnim = Tween<double>(begin: 0.35, end: 1.0).animate(CurvedAnimation(
      parent: _pulse,
      curve: Curves.easeInOut,
    ));
    if (widget.isStreaming) _pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant GlassThinkingPanel old) {
    super.didUpdateWidget(old);
    if (widget.isStreaming != old.isStreaming) {
      if (widget.isStreaming) {
        _pulse.repeat(reverse: true);
      } else {
        _pulse.stop();
        _pulse.value = 1.0;
      }
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasContent = widget.content.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 6, 0, 4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            decoration: BoxDecoration(
              color: GlassTheme.accentPurple.withOpacity(0.10),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: GlassTheme.accentPurple.withOpacity(0.45),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header — always visible, tap to toggle.
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: hasContent
                        ? () => setState(() => _expanded = !_expanded)
                        : null,
                    borderRadius: BorderRadius.circular(14),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      child: Row(
                        children: [
                          FadeTransition(
                            opacity: widget.isStreaming
                                ? _pulseAnim
                                : const AlwaysStoppedAnimation(1.0),
                            child: const Icon(
                              Icons.psychology_rounded,
                              size: 18,
                              color: GlassTheme.accentPurple,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            widget.isStreaming
                                ? 'Thinking…'
                                : 'Gemma\'s reasoning',
                            style: const TextStyle(
                              color: GlassTheme.accentPurple,
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                              letterSpacing: 0.2,
                            ),
                          ),
                          if (widget.isStreaming) ...[
                            const SizedBox(width: 8),
                            const SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                    GlassTheme.accentPurple),
                              ),
                            ),
                          ],
                          const Spacer(),
                          if (hasContent)
                            Icon(
                              _expanded
                                  ? Icons.expand_less_rounded
                                  : Icons.expand_more_rounded,
                              size: 20,
                              color: GlassTheme.accentPurple.withOpacity(0.85),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                // Body — animated expand/collapse.
                AnimatedSize(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeInOut,
                  alignment: Alignment.topCenter,
                  child: (_expanded && hasContent)
                      ? Padding(
                          padding:
                              const EdgeInsets.fromLTRB(12, 0, 12, 12),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.18),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: Colors.white.withOpacity(0.08),
                              ),
                            ),
                            child: SelectableText(
                              widget.content,
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.85),
                                fontSize: 12.5,
                                height: 1.45,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
