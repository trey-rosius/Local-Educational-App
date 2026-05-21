import 'dart:ui';
import 'package:flutter/material.dart';
import '../model_selection_screen.dart';
import '../embedding_models_screen.dart';
import '../services/memory_guard.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBodyBehindAppBar: true,
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(112),
          child: ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: AppBar(
                backgroundColor: Colors.white.withOpacity(0.06),
                elevation: 0,
                iconTheme: const IconThemeData(color: Colors.white),
                title: const Text(
                  'AI Configuration',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                centerTitle: true,
                bottom: PreferredSize(
                  preferredSize: const Size.fromHeight(48),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                              color: Colors.white.withOpacity(0.18)),
                        ),
                        child: TabBar(
                          indicator: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                const Color(0xFF82B1FF).withOpacity(0.45),
                                const Color(0xFFB388FF).withOpacity(0.35),
                              ],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                                color:
                                    const Color(0xFF82B1FF).withOpacity(0.55)),
                          ),
                          indicatorSize: TabBarIndicatorSize.tab,
                          indicatorPadding: const EdgeInsets.all(4),
                          labelColor: Colors.white,
                          unselectedLabelColor: Colors.white.withOpacity(0.65),
                          labelStyle: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                          unselectedLabelStyle:
                              const TextStyle(fontSize: 13),
                          dividerColor: Colors.transparent,
                          tabs: const [
                            Tab(
                              height: 40,
                              icon: Icon(Icons.psychology, size: 18),
                              iconMargin: EdgeInsets.only(bottom: 2),
                              text: 'Inference',
                            ),
                            Tab(
                              height: 40,
                              icon: Icon(Icons.storage, size: 18),
                              iconMargin: EdgeInsets.only(bottom: 2),
                              text: 'Embedding',
                            ),
                            Tab(
                              height: 40,
                              icon: Icon(Icons.memory, size: 18),
                              iconMargin: EdgeInsets.only(bottom: 2),
                              text: 'Performance',
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        body: const TabBarView(
          children: [
            ModelSelectionScreen(),
            EmbeddingModelsScreen(),
            _PerformanceTab(),
          ],
        ),
      ),
    );
  }
}

class _PerformanceTab extends StatefulWidget {
  const _PerformanceTab();

  @override
  State<_PerformanceTab> createState() => _PerformanceTabState();
}

class _PerformanceTabState extends State<_PerformanceTab> {
  @override
  void initState() {
    super.initState();
    MemoryGuard.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    MemoryGuard.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final guard = MemoryGuard.instance;
    final ramMb = guard.detectedRamMb;
    final ramText = ramMb == null
        ? 'unknown'
        : '${(ramMb / 1024).toStringAsFixed(1)} GB ($ramMb MB)';

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        20,
        // Clear the parent AppBar (preferredSize 112) + breathing room.
        MediaQuery.of(context).padding.top + 116,
        20,
        MediaQuery.of(context).padding.bottom + 24,
      ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Performance Tier',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'The app auto-detects your device\'s RAM and picks a tier '
              'that balances generation quality against memory pressure. '
              'Override only if you know your device handles more (or '
              'less) than the detected default.',
              style: TextStyle(
                color: Colors.white.withOpacity(0.7),
                fontSize: 13,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 18),

            // ── Detected card ────────────────────────────────────────
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.06),
                    border: Border.all(color: Colors.white.withOpacity(0.18)),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.memory,
                          color: Color(0xFF82B1FF), size: 28),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Detected: ${guard.detectedTier.label}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Total RAM: $ramText',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.65),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (guard.isUsingOverride)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.amber.withOpacity(0.18),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                                color: Colors.amber.withOpacity(0.55)),
                          ),
                          child: const Text(
                            'OVERRIDDEN',
                            style: TextStyle(
                              color: Colors.amber,
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.6,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 18),

            // ── Override picker ──────────────────────────────────────
            const Text(
              'Override',
              style: TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            _tierTile(
              label: 'Auto (recommended)',
              subtitle: 'Use the detected tier: ${guard.detectedTier.label}',
              selected: !guard.isUsingOverride,
              onTap: () => guard.setOverride(null),
            ),
            for (final t in PerformanceTier.values)
              _tierTile(
                label: 'Force ${t.label}',
                subtitle: t.oneLineSummary,
                selected: guard.manualOverride == t,
                onTap: () => guard.setOverride(t),
              ),

            const SizedBox(height: 24),
            const Text(
              'Current budgets',
              style: TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            _budgetRow('Active tier', guard.tier.label),
            _budgetRow('Model maxTokens', '${guard.maxTokens}'),
            _budgetRow('Max RAG context (chars)', '${guard.maxContextChars}'),
            _budgetRow('Max question/card count', '${guard.maxQuestionCount}'),
            _budgetRow('RAG chunks (workshop/lesson)',
                '${guard.ragChunksForLookup}'),
            const SizedBox(height: 24),

            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.amber.withOpacity(0.10),
                border: Border.all(color: Colors.amber.withOpacity(0.45)),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.info_outline,
                      color: Colors.amber, size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Note: flutter_gemma 0.15.1 does not have a safe '
                      'weight-unload primitive (model.close() causes a '
                      'native double-free), so on-device RAM is managed '
                      'via prompt budgets + KV-cache release after each '
                      'generation rather than fully evicting the model.',
                      style: TextStyle(
                        color: Colors.amber.shade100,
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
  }

  Widget _tierTile({
    required String label,
    required String subtitle,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: selected
                  ? const Color(0xFF82B1FF).withOpacity(0.18)
                  : Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected
                    ? const Color(0xFF82B1FF).withOpacity(0.65)
                    : Colors.white.withOpacity(0.14),
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: selected
                      ? const Color(0xFF82B1FF)
                      : Colors.white.withOpacity(0.45),
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.62),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _budgetRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: Colors.white.withOpacity(0.75),
                fontSize: 13,
              ),
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}
