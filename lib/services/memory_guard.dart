import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:system_info_plus/system_info_plus.dart';

/// Four-tier performance ladder. The app auto-detects the device's total
/// RAM at startup and picks the highest tier that still leaves comfortable
/// headroom for the OS + Gemma 4 E2B's KV cache. Users can override via
/// Settings → Performance for testing or extra safety.
enum PerformanceTier {
  /// ≤ 4 GB devices (older iPhones, budget Androids). Tightest budgets.
  ultraLean,

  /// 5-6 GB devices (iPhone 12 Pro through 14 Pro, iPhone 13 Pro Max).
  /// Conservative — matches what the original "Lean Memory Mode" did.
  lean,

  /// 7-8 GB devices (iPhone 15/16 Pro, modern mid-range Androids).
  balanced,

  /// 9+ GB devices (iPhone 17+ rumored, iPad Pro, all desktops).
  full,
}

/// Memory guardrails for running Gemma 4 E2B across the range of devices
/// the app supports. Centralizes all the knobs that trade off generation
/// quality vs. memory pressure into one place; callers just ask for
/// `MemoryGuard.instance.maxTokens` etc. and get tier-correct values.
///
/// On a 6 GB device the .task file plus its KV cache plus the OS surface
/// can OOM-kill the app under prompt+response token loads above ~3.5K
/// total. The `lean` tier stays comfortably below that ceiling; `full`
/// is reserved for devices that can take the full 4096-token budget.
///
/// NOTE on model eviction: an earlier design considered unloading Gemma
/// when only the embedder is needed (and vice versa). flutter_gemma 0.15.1
/// does not have a safe weight-unload primitive — calling `model.close()`
/// leaves a dangling native pointer that the next `getActiveModel()` call
/// returns, causing a double-free crash ("pointer being freed was not
/// allocated"). Until the plugin exposes a real eviction API we keep the
/// inference engine alive as a singleton and manage pressure via prompt
/// size + KV-cache release (`chat.close()` after every generation).
class MemoryGuard extends ChangeNotifier {
  MemoryGuard._();
  static final MemoryGuard instance = MemoryGuard._();

  static const _overridePrefKey = 'memory_guard.override_tier';

  /// Auto-detected tier from device RAM. Falls back to [PerformanceTier.lean]
  /// if detection fails or is unavailable (e.g. web).
  PerformanceTier _detected = PerformanceTier.lean;

  /// User's manual tier override. `null` means "use auto-detected".
  PerformanceTier? _override;

  /// Total physical memory in MB, as reported by system_info_plus. `null`
  /// if detection failed.
  int? _detectedRamMb;

  /// The tier currently in effect. Override takes precedence over auto.
  PerformanceTier get tier => _override ?? _detected;

  PerformanceTier get detectedTier => _detected;
  PerformanceTier? get manualOverride => _override;
  int? get detectedRamMb => _detectedRamMb;
  bool get isUsingOverride => _override != null;

  /// Call once at startup before any generation. Detects RAM and loads
  /// any saved user override.
  Future<void> initialize() async {
    // Load override preference first.
    try {
      final prefs = await SharedPreferences.getInstance();
      final overrideName = prefs.getString(_overridePrefKey);
      if (overrideName != null && overrideName != 'auto') {
        _override = PerformanceTier.values.firstWhere(
          (t) => t.name == overrideName,
          orElse: () => PerformanceTier.lean,
        );
      }
    } catch (_) {
      // shared_preferences unavailable — keep _override = null (auto).
    }

    // Detect tier from total RAM.
    _detected = await _detectTier();
    notifyListeners();
  }

  Future<PerformanceTier> _detectTier() async {
    if (kIsWeb) {
      // Web can't reliably introspect host RAM and tab memory budgets
      // are aggressive — stay conservative.
      return PerformanceTier.lean;
    }
    try {
      final ramMb = await SystemInfoPlus.physicalMemory;
      if (ramMb != null && ramMb > 0) {
        _detectedRamMb = ramMb;
        return _tierForRam(ramMb);
      }
    } catch (e) {
      debugPrint('MemoryGuard: RAM detection failed: $e');
    }
    // Desktop without detection succeeding — assume plenty of RAM.
    if (Platform.isMacOS || Platform.isLinux || Platform.isWindows) {
      return PerformanceTier.full;
    }
    // Mobile without detection succeeding — stay conservative.
    return PerformanceTier.lean;
  }

  /// Maps total RAM (MB) → tier. Thresholds tuned for the iOS/Android
  /// device ladder. Devices report slightly less RAM than their nominal
  /// spec (kernel reserves some), so the cutoffs are intentionally
  /// generous on the low side.
  static PerformanceTier _tierForRam(int totalMb) {
    if (totalMb < 4500) return PerformanceTier.ultraLean; // ≤ 4 GB nominal
    if (totalMb < 7000) return PerformanceTier.lean; // 5-6 GB nominal
    if (totalMb < 9000) return PerformanceTier.balanced; // 7-8 GB nominal
    return PerformanceTier.full; // 9+ GB nominal
  }

  /// Set or clear the user override. Pass `null` to revert to auto.
  Future<void> setOverride(PerformanceTier? tier) async {
    if (_override == tier) return;
    _override = tier;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_overridePrefKey, tier?.name ?? 'auto');
    } catch (_) {}
    notifyListeners();
  }

  // ─── Budgets (tier-driven) ──────────────────────────────────────────────

  /// Token budget for `getActiveModel(maxTokens: ...)`. The model's hard
  /// context cap is 4096; lower tiers stay below it to keep KV-cache RAM
  /// pressure manageable.
  int get maxTokens {
    switch (tier) {
      case PerformanceTier.ultraLean:
        return 2560;
      case PerformanceTier.lean:
        return 3072;
      case PerformanceTier.balanced:
        return 4096;
      case PerformanceTier.full:
        return 4096;
    }
  }

  /// Hard cap on the size of the RAG context block in characters. ~4
  /// chars/token, so 4000 chars ≈ 1000 tokens.
  int get maxContextChars {
    switch (tier) {
      case PerformanceTier.ultraLean:
        return 3000;
      case PerformanceTier.lean:
        return 4000;
      case PerformanceTier.balanced:
        return 6500;
      case PerformanceTier.full:
        return 9000;
    }
  }

  /// Soft ceiling on question/card count the user can request. UI can
  /// clamp the count picker's max value to this.
  int get maxQuestionCount {
    switch (tier) {
      case PerformanceTier.ultraLean:
        return 5;
      case PerformanceTier.lean:
        return 8;
      case PerformanceTier.balanced:
        return 12;
      case PerformanceTier.full:
        return 15;
    }
  }

  /// How many RAG chunks to retrieve for a generation of [count]
  /// questions/cards. Tool-call types have a tight prompt budget because
  /// the schema itself adds ~200 tokens of overhead, so they get fewer.
  int ragChunksForGeneration({required int count, required bool toolCall}) {
    switch (tier) {
      case PerformanceTier.ultraLean:
        return toolCall ? 2 : (count >= 10 ? 4 : 3);
      case PerformanceTier.lean:
        return toolCall ? (count >= 10 ? 3 : 2) : (count >= 10 ? 5 : 4);
      case PerformanceTier.balanced:
        return toolCall ? (count >= 10 ? 5 : 4) : (count >= 10 ? 8 : 6);
      case PerformanceTier.full:
        return toolCall
            ? (count >= 10 ? 8 : 6)
            : (count >= 15 ? 16 : (count >= 10 ? 12 : 10));
    }
  }

  /// RAG chunks for non-counted lookups (workshop outline, lesson body).
  int get ragChunksForLookup {
    switch (tier) {
      case PerformanceTier.ultraLean:
        return 3;
      case PerformanceTier.lean:
        return 4;
      case PerformanceTier.balanced:
        return 6;
      case PerformanceTier.full:
        return 8;
    }
  }

  /// Truncates [context] to [maxContextChars], appending a marker so
  /// downstream callers (and the model) see that the input was capped.
  String capContext(String context) {
    final ctx = context.trim();
    if (ctx.length <= maxContextChars) return ctx;
    return '${ctx.substring(0, maxContextChars)}\n[…context truncated for memory safety]';
  }
}

extension PerformanceTierLabel on PerformanceTier {
  /// Human-readable name for the Settings UI.
  String get label {
    switch (this) {
      case PerformanceTier.ultraLean:
        return 'Ultra-Lean';
      case PerformanceTier.lean:
        return 'Lean';
      case PerformanceTier.balanced:
        return 'Balanced';
      case PerformanceTier.full:
        return 'Full';
    }
  }

  String get oneLineSummary {
    switch (this) {
      case PerformanceTier.ultraLean:
        return '≤4 GB devices · safest budgets';
      case PerformanceTier.lean:
        return '5-6 GB devices · iPhone 13 Pro Max';
      case PerformanceTier.balanced:
        return '7-8 GB devices · iPhone 15/16 Pro';
      case PerformanceTier.full:
        return '9+ GB devices · iPad Pro, desktop';
    }
  }
}
