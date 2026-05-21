import 'dart:typed_data';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'utils/audio_converter.dart';
import 'widgets/educational_widgets.dart';
import 'widgets/glass_theme.dart';
import 'utils/json_utils.dart';

class ChatMessageWidget extends StatelessWidget {
  const ChatMessageWidget({super.key, required this.message});

  final Message message;

  @override
  Widget build(BuildContext context) {
    final text = message.text;
    // IMPROVED: Detect raw JSON tool calls from quantized models
    bool isRawToolCall = text.contains('"tool_calls"') && text.contains('"function"');

    // Handle educational tool calls and raw JSON tool calls
    if ((message.type == MessageType.systemInfo && text.contains('🔧 Calling:')) || isRawToolCall) {
       return _buildEducationalWidget(context);
    }

    // Handle system info messages differently
    if (message.type == MessageType.systemInfo) {
      return _buildSystemMessage(context);
    }

    final isUser = message.isUser;
    // Glass-themed bubble — accent-tinted for user, neutral surface for bot.
    final Color bubbleTint = isUser
        ? GlassTheme.accentBlue.withOpacity(0.22)
        : GlassTheme.surface;
    final Color bubbleBorder = isUser
        ? GlassTheme.accentBlue.withOpacity(0.55)
        : GlassTheme.border;
    final Color codeBg = isUser
        ? GlassTheme.accentBlue.withOpacity(0.18)
        : Colors.white.withOpacity(0.10);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: <Widget>[
          if (!isUser) _buildAvatar(),
          if (!isUser) const SizedBox(width: 10),
          Flexible(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: Container(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.78,
                  ),
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  decoration: BoxDecoration(
                    color: bubbleTint,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: bubbleBorder),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.12),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (message.hasImage) ...[
                        _buildImageWidget(context),
                        if (message.text.isNotEmpty) const SizedBox(height: 8),
                      ],
                      if (message.hasAudio) ...[
                        _buildAudioWidget(message.audioBytes!),
                        if (message.text.isNotEmpty) const SizedBox(height: 8),
                      ],
                      if (message.text.isNotEmpty)
                        MarkdownBody(
                          data: message.text,
                          selectable: true,
                          styleSheet: MarkdownStyleSheet(
                            p: const TextStyle(
                              color: GlassTheme.textPrimary,
                              fontSize: 14,
                              height: 1.45,
                            ),
                            strong: const TextStyle(
                              color: GlassTheme.textPrimary,
                              fontWeight: FontWeight.w700,
                            ),
                            listBullet: const TextStyle(
                              color: GlassTheme.textPrimary,
                              fontSize: 14,
                            ),
                            code: TextStyle(
                              backgroundColor: codeBg,
                              color: GlassTheme.textPrimary,
                              fontFamily: 'monospace',
                            ),
                            codeblockDecoration: BoxDecoration(
                              color: codeBg,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                  color: Colors.white.withOpacity(0.08)),
                            ),
                          ),
                        )
                      else if (!message.hasImage && !message.hasAudio)
                        const Padding(
                          padding: EdgeInsets.all(4),
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                  GlassTheme.accentBlue),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (isUser) const SizedBox(width: 10),
          if (isUser) _buildAvatar(),
        ],
      ),
    );
  }

  Widget _buildImageWidget(BuildContext context) {
    return GestureDetector(
      onTap: () => _showImageDialog(context),
      child: Container(
        constraints: const BoxConstraints(
          maxWidth: 300,
          maxHeight: 200,
        ),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.3),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(
            message.imageBytes!,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) {
              return Container(
                width: 200,
                height: 100,
                color: Colors.grey[300],
                child: const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.error, color: Colors.red),
                    SizedBox(height: 4),
                    Text(
                      'Image loading error',
                      style: TextStyle(color: Colors.red, fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildAudioWidget(Uint8List audioBytes) {
    final duration = AudioConverter.calculateDuration(
      audioBytes,
      sampleRate: AudioConverter.targetSampleRate,
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF2a5a8c),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.audiotrack,
            color: Colors.white70,
            size: 20,
          ),
          const SizedBox(width: 8),
          Text(
            'Audio: ${AudioConverter.formatDuration(duration)}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '(${(audioBytes.length / 1024).toStringAsFixed(1)} KB)',
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  void _showImageDialog(BuildContext context) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (BuildContext context) {
        return Dialog(
          backgroundColor: Colors.transparent,
          child: Stack(
            children: [
              // Full-size image
              Center(
                child: InteractiveViewer(
                  child: Image.memory(
                    message.imageBytes!,
                    fit: BoxFit.contain,
                  ),
                ),
              ),

              // Close button
              Positioned(
                top: 40,
                right: 20,
                child: IconButton(
                  icon: const Icon(
                    Icons.close,
                    color: Colors.white,
                    size: 30,
                  ),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSystemMessage(BuildContext context) {
    IconData iconData;
    Color iconColor;

    // Determine icon based on message content
    if (message.text.contains('Calling')) {
      iconData = Icons.settings;
      iconColor = Colors.blue;
    } else if (message.text.contains('Executing')) {
      iconData = Icons.flash_on;
      iconColor = Colors.orange;
    } else if (message.text.contains('completed')) {
      iconData = Icons.check_circle;
      iconColor = Colors.green;
    } else if (message.text.contains('Generating')) {
      iconData = Icons.psychology;
      iconColor = Colors.purple;
    } else {
      iconData = Icons.info;
      iconColor = Colors.blue;
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 10.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.start,
        children: <Widget>[
          const SizedBox(width: 58), // Same spacing as regular messages
          Expanded(
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.8,
              ),
              padding: const EdgeInsets.all(12.0),
              decoration: BoxDecoration(
                color: const Color(0xFF1a4a7c), // Same as user messages
                borderRadius: BorderRadius.circular(12.0),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(iconData, size: 16, color: iconColor),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      message.text,
                      style: const TextStyle(
                        fontSize: 14,
                        color: Colors.white, // White text on blue background
                        fontStyle: FontStyle.italic,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
        ],
      ),
    );
  }

  Widget _buildEducationalWidget(BuildContext context) {
    final text = message.text;
    
    try {
      String jsonStr = '';
      
      // Attempt 1: Extract from TOOL_DATA marker
      if (text.contains('TOOL_DATA:')) {
        jsonStr = text.split('TOOL_DATA:')[1];
      } 
      // Attempt 2: Extract raw JSON block
      else if (text.contains('{') && text.contains('}')) {
        final startIndex = text.indexOf('{');
        final endIndex = text.lastIndexOf('}') + 1;
        jsonStr = text.substring(startIndex, endIndex);
      }

      // Clean up common quantized model artifacts
      jsonStr = jsonStr.replaceAll('<|', '').replaceAll('|>', '').replaceAll('\n', ' ');

      final Map<String, dynamic> data = jsonDecode(JsonUtils.cleanJson(jsonStr));
      
      // Normalize data structure (handle both raw model output and our TOOL_DATA format)
      String? name;
      Map<String, dynamic>? args;

      if (data.containsKey('tool_calls')) {
        final call = data['tool_calls'][0]['function'];
        name = call['name'];
        args = call['arguments'] is String ? jsonDecode(JsonUtils.cleanJson(call['arguments'])) : call['arguments'];
      } else if (data.containsKey('name')) {
        name = data['name'];
        args = data['args'];
      }

      if (name == 'generate_interactive_quiz' && args != null) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 58, vertical: 8),
          child: QuizCard(
            subject: args['subject'] ?? 'Document Quiz',
            questions: args['questions'] ?? [],
            onComplete: (score, total) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Quiz Finished! Score: $score/$total')),
              );
            },
          ),
        );
      }

      if (name == 'award_badge' && args != null) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 58, vertical: 8),
          child: BadgeCard(
            badgeName: args['badge_name'] ?? 'Scholar',
            reason: args['reason'] ?? 'Excellence in learning',
          ),
        );
      }

      if (name == 'start_focus_timer' && args != null) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 58, vertical: 8),
          child: FocusTimerCard(
            minutes: args['duration_minutes'] ?? 25,
            topic: args['focus_topic'] ?? 'Study Session',
          ),
        );
      }
    } catch (e) {
      debugPrint('GenUI-Lite Error: $e');
    }

    return _buildSystemMessage(context);
  }

  Widget _buildAvatar() {
    if (message.isUser) {
      return Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              GlassTheme.accentBlue.withOpacity(0.55),
              GlassTheme.accentPurple.withOpacity(0.45),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withOpacity(0.30)),
        ),
        child: const Icon(Icons.person, color: Colors.white, size: 18),
      );
    }
    // Bot avatar — robot icon on a glass gradient disk.
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF1E2A4E), Color(0xFF0E1A33)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        shape: BoxShape.circle,
        border: Border.all(color: GlassTheme.accentCyan.withOpacity(0.55)),
        boxShadow: [
          BoxShadow(
            color: GlassTheme.accentCyan.withOpacity(0.30),
            blurRadius: 8,
          ),
        ],
      ),
      child: const Icon(
        Icons.smart_toy_rounded,
        color: GlassTheme.accentCyan,
        size: 20,
      ),
    );
  }
}
