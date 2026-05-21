import 'package:flutter_gemma/flutter_gemma.dart';

class EducationalToolService {
  /// Defines the catalog of tools Gemma 4 can use to interact with the student.
  static final List<Tool> educationalTools = [
    const Tool(
      name: 'generate_interactive_quiz',
      description: 'Creates a gamified quiz based on the study material. Use this when a student wants to test their knowledge.',
      parameters: {
        'type': 'object',
        'properties': {
          'subject': {
            'type': 'string',
            'description': 'The topic of the quiz (e.g., "Photosynthesis", "Cloud Computing").',
          },
          'questions': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'question': {'type': 'string'},
                'options': {
                  'type': 'array',
                  'items': {'type': 'string'},
                },
                'correct_answer': {'type': 'string'},
                'explanation': {'type': 'string'},
              },
              'required': ['question', 'options', 'correct_answer'],
            },
          },
        },
        'required': ['subject', 'questions'],
      },
    ),
    const Tool(
      name: 'award_badge',
      description: 'Awards a digital badge to the student for mastering a concept or showing great effort.',
      parameters: {
        'type': 'object',
        'properties': {
          'badge_name': {
            'type': 'string',
            'description': 'The name of the badge (e.g., "Cloud Guru", "Quick Learner").',
          },
          'reason': {
            'type': 'string',
            'description': 'Why the student is receiving this badge.',
          },
          'animation_type': {
            'type': 'string',
            'description': 'The visual effect to show (confetti, sparkler, fireworks).',
          },
        },
        'required': ['badge_name', 'reason'],
      },
    ),
    const Tool(
      name: 'start_focus_timer',
      description: 'Starts a Pomodoro-style focus timer to help the student manage their study session.',
      parameters: {
        'type': 'object',
        'properties': {
          'duration_minutes': {
            'type': 'integer',
            'description': 'How long the timer should run (default is 25).',
          },
          'focus_topic': {
            'type': 'string',
            'description': 'What the student is focusing on during this timer.',
          },
        },
        'required': ['duration_minutes', 'focus_topic'],
      },
    ),
    const Tool(
      name: 'narrate_explanation',
      description: 'Reads an explanation out loud using the devices native voice narrator.',
      parameters: {
        'type': 'object',
        'properties': {
          'text_to_read': {
            'type': 'string',
            'description': 'The text content to be spoken.',
          },
          'voice_style': {
            'type': 'string',
            'description': 'The style of narration (calm, enthusiastic, professional).',
          },
        },
        'required': ['text_to_read'],
      },
    ),
    const Tool(
      name: 'launch_mini_game',
      description: 'Launches a subject-specific interactive mini-game for hands-on learning.',
      parameters: {
        'type': 'object',
        'properties': {
          'game_type': {
            'type': 'string',
            'description': 'The type of game (equation_balancer, alphabet_match, memory_grid).',
          },
          'difficulty': {
            'type': 'integer',
            'description': 'Difficulty level from 1 to 5.',
          },
        },
        'required': ['game_type', 'difficulty'],
      },
    ),
  ];

  /// Schema for multiple-choice quiz generation. Used with
  /// [ToolChoice.required] so the model emits a guaranteed-valid function
  /// call — no free-text JSON, no repair pipeline, no FormatException.
  static const Tool quizTool = Tool(
    name: 'create_quiz',
    description:
        'Creates a multiple-choice quiz. Each question has exactly 4 plain-text '
        'answer options and an integer answerIndex (0-3) pointing to the correct one.',
    parameters: {
      'type': 'object',
      'properties': {
        'questions': {
          'type': 'array',
          'description': 'Quiz questions covering distinct concepts from the source material.',
          'items': {
            'type': 'object',
            'properties': {
              'question': {
                'type': 'string',
                'description': 'The question text.',
              },
              'options': {
                'type': 'array',
                'description':
                    'Exactly 4 short, plain-text answer choices. Never citations, '
                    'bibliography entries, page-ranges, DOI/URL fragments, or raw '
                    'quotes from the context.',
                'items': {'type': 'string'},
              },
              'answerIndex': {
                'type': 'integer',
                'description': 'Index (0-3) of the correct option in the options array.',
              },
              'explanation': {
                'type': 'string',
                'description': 'Brief reason why the correct option is right (1 sentence).',
              },
            },
            'required': ['question', 'options', 'answerIndex'],
          },
        },
      },
      'required': ['questions'],
    },
  );

  /// Schema for flashcard generation. Used with [ToolChoice.required] so
  /// the model emits a guaranteed-valid function call instead of free-text
  /// JSON we'd have to repair.
  static const Tool flashcardsTool = Tool(
    name: 'create_flashcards',
    description:
        'Creates a set of question-and-answer flashcards for study practice. '
        'Each card pairs a concise question with a short, factual answer.',
    parameters: {
      'type': 'object',
      'properties': {
        'cards': {
          'type': 'array',
          'description': 'Flashcards covering distinct concepts from the source material.',
          'items': {
            'type': 'object',
            'properties': {
              'question': {
                'type': 'string',
                'description': 'A short question testing one concept.',
              },
              'answer': {
                'type': 'string',
                'description': 'A short, factual answer (1-2 sentences max).',
              },
            },
            'required': ['question', 'answer'],
          },
        },
      },
      'required': ['cards'],
    },
  );

  /// Schema for workshop outline generation. Used with [ToolChoice.required]
  /// so the model's output is constrained by the runtime to be a valid
  /// function call — no free-text JSON to repair.
  static const Tool workshopOutlineTool = Tool(
    name: 'create_workshop_outline',
    description:
        'Creates a structured course outline with a sequence of lessons. '
        'Each lesson has a title, summary, list of key points, and estimated minutes.',
    parameters: {
      'type': 'object',
      'properties': {
        'title': {
          'type': 'string',
          'description': 'Workshop title.',
        },
        'description': {
          'type': 'string',
          'description': 'Short summary of what the workshop covers (1-2 sentences).',
        },
        'lessons': {
          'type': 'array',
          'description': 'Ordered list of lessons from foundations to advanced.',
          'items': {
            'type': 'object',
            'properties': {
              'title': {'type': 'string', 'description': 'Short lesson title.'},
              'summary': {'type': 'string', 'description': 'One-sentence overview.'},
              'keyPoints': {
                'type': 'array',
                'description': 'Bullet points the lesson must cover.',
                'items': {'type': 'string'},
              },
              'estimatedMinutes': {
                'type': 'integer',
                'description': 'How many minutes to study this lesson.',
              },
            },
            'required': ['title', 'summary', 'keyPoints', 'estimatedMinutes'],
          },
        },
      },
      'required': ['title', 'description', 'lessons'],
    },
  );

  /// Handles the raw model output for tools.
  /// This is our "GenUI-Lite" parsing layer.
  /// It can handle slightly malformed JSON or direct function calls.
  static Map<String, dynamic>? parseLiteResponse(String output) {
    // Basic regex to find JSON-like structures if the model misses brackets
    // (This is the fault-tolerance for quantized edge models)
    if (output.contains('"{') && output.contains('}"')) {
       // Model might have wrapped JSON in extra quotes
       // We can strip them here.
    }
    return null; // Placeholder for future custom parsing if needed
  }

  static Future<InferenceChat> createEducationalChat() async {
    final model = await FlutterGemma.getActiveModel(maxTokens: 2048);
    return model.createChat(
      temperature: 0.7,
      randomSeed: 1,
      topP: 0.9,
      tokenBuffer: 512,
      supportsFunctionCalls: true,
      tools: educationalTools,
      // Enable Gemma 4's reasoning channel. Thinking tokens stream as
      // ThinkingResponse and we render them in a collapsible panel above
      // the answer bubble (see GlassThinkingPanel).
      isThinking: true,
    );
  }
}
