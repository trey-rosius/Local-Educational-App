import 'dart:convert';

class JsonUtils {
  static String extractAndCleanJson(String text) {
    final startBracket = text.indexOf('[');
    final startBrace = text.indexOf('{');
    int start = -1;
    if (startBracket != -1 && startBrace != -1) start = startBracket < startBrace ? startBracket : startBrace;
    else if (startBracket != -1) start = startBracket;
    else if (startBrace != -1) start = startBrace;

    final endBracket = text.lastIndexOf(']');
    final endBrace = text.lastIndexOf('}');
    int end = -1;
    if (endBracket != -1 && endBrace != -1) end = endBracket > endBrace ? endBracket : endBrace;
    else if (endBracket != -1) end = endBracket;
    else if (endBrace != -1) end = endBrace;

    String json = text;
    if (start != -1 && end != -1 && end > start) {
      json = text.substring(start, end + 1);
    }
    
    return cleanJson(json);
  }

  static String cleanJson(String json) {
    // 1. Remove trailing commas before closing brackets
    json = json.replaceAll(RegExp(r',\s*]'), ']');
    json = json.replaceAll(RegExp(r',\s*}'), '}');
    
    // 2. Fix hallucinated numbers inside objects: {1, "question": ...
    json = json.replaceAll(RegExp(r'\{\s*\d+\s*,\s*'), '{');
    
    // 3. Fix the specific error seen: number followed by extra quote (e.g. : 1")
    json = json.replaceAllMapped(RegExp(r'(:\s*\d+)"(\s*[,}])'), (m) => '${m[1]}${m[2]}');
    
    // 3. Fix unescaped control characters inside strings (like newlines)
    StringBuffer sb = StringBuffer();
    bool inString = false;
    bool escapeNext = false;
    
    for (int i = 0; i < json.length; i++) {
      String char = json[i];
      
      if (inString) {
        if (escapeNext) {
          sb.write(char);
          escapeNext = false;
        } else if (char == '\\') {
          sb.write(char);
          escapeNext = true;
        } else if (char == '"') {
          sb.write(char);
          inString = false;
        } else {
          int codeUnit = char.codeUnitAt(0);
          if (codeUnit < 32) {
            if (char == '\n') {
              sb.write('\\n');
            } else if (char == '\t') {
              sb.write('\\t');
            } else if (char == '\r') {
              sb.write('\\r');
            } else {
              // Skip other invalid control chars
            }
          } else {
            sb.write(char);
          }
        }
      } else {
        if (char == '"') {
          inString = true;
        }
        sb.write(char);
      }
    }
    
    return sb.toString();
  }
}
