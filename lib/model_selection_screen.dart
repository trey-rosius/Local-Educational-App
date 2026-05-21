import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_gemma/pigeon.g.dart';
import 'model_download_screen.dart';
import 'models/model.dart';
import 'widgets/glass_theme.dart';

bool get _isDesktop =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux);

enum SortType {
  defaultOrder('Default'),
  alphabetical('Alphabetical'),
  size('Size');

  const SortType(this.displayName);
  final String displayName;
}

class ModelSelectionScreen extends StatefulWidget {
  const ModelSelectionScreen({super.key});

  @override
  State<ModelSelectionScreen> createState() => _ModelSelectionScreenState();
}

class _ModelSelectionScreenState extends State<ModelSelectionScreen> {
  SortType selectedSort = SortType.defaultOrder;
  bool showFilters = false;

  // Filter states
  bool filterMultimodal = false;
  bool filterFunctionCalls = false;
  bool filterThinking = false;

  // Convert size string to MB for sorting
  double _sizeToMB(String size) {
    final numStr = size.replaceAll(RegExp(r'[^0-9.]'), '');
    final num = double.tryParse(numStr) ?? 0;

    if (size.toUpperCase().contains('GB')) {
      return num * 1024; // Convert GB to MB
    } else if (size.toUpperCase().contains('TB')) {
      return num * 1024 * 1024; // Convert TB to MB
    }
    return num; // Assume MB if no unit
  }

  List<Model> _sortModels(List<Model> models) {
    switch (selectedSort) {
      case SortType.alphabetical:
        return [...models]..sort((a, b) => a.displayName.compareTo(b.displayName));
      case SortType.size:
        return [...models]..sort((a, b) => _sizeToMB(a.size).compareTo(_sizeToMB(b.size)));
      case SortType.defaultOrder:
        return models; // Keep original order
    }
  }

  List<Model> _filterModels(List<Model> models) {
    return models.where((model) {
      // Feature filters
      if (filterMultimodal && !model.supportImage) return false;
      if (filterFunctionCalls && !model.supportsFunctionCalls) return false;
      if (filterThinking && !model.isThinking) return false;

      return true;
    }).toList();
  }

  void _clearFilters() {
    setState(() {
      filterMultimodal = false;
      filterFunctionCalls = false;
      filterThinking = false;
    });
  }

  String _getModelsWord(int count) {
    if (count == 1) {
      return 'model';
    } else {
      return 'models';
    }
  }

  @override
  Widget build(BuildContext context) {
    // Show all models on all platforms
    var models = Model.values.toList();

    // On desktop, only show models with desktopUrl (litertlm format required)
    if (_isDesktop) {
      models = models.where((model) => model.localModel || model.supportsDesktop).toList();
    }

    // On web, only show models with webUrl or local models
    if (kIsWeb) {
      models = models.where((model) => model.localModel || model.webUrl != null).toList();
    }

    // Apply filtering then sorting
    models = _filterModels(models);
    models = _sortModels(models);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          // Just enough to clear the parent AppBar (preferredSize 112) + small breathing room.
          MediaQuery.of(context).padding.top + 116,
          16,
          MediaQuery.of(context).padding.bottom + 16,
        ),
        child: Column(
          children: [
            // Filters section
            Container(
              margin: const EdgeInsets.only(bottom: 6.0),
              child: Column(
                children: [
                  // Filter header
                  InkWell(
                    onTap: () {
                      setState(() {
                        showFilters = !showFilters;
                      });
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 8.0),
                      child: Row(
                        children: [
                          Icon(
                            showFilters ? Icons.filter_list : Icons.filter_list_outlined,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            'Filters',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                          const Spacer(),
                          Icon(
                            showFilters ? Icons.expand_less : Icons.expand_more,
                            color: Colors.white,
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Filter options
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    height: showFilters ? null : 0,
                    child: showFilters
                        ? Container(
                            padding: const EdgeInsets.all(12.0),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.08),
                              borderRadius: BorderRadius.circular(14.0),
                              border: Border.all(
                                  color: Colors.white.withOpacity(0.18)),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // Features
                                const Text(
                                  'Features:',
                                  style:
                                      TextStyle(color: Colors.white, fontWeight: FontWeight.w500),
                                ),
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 8,
                                  children: [
                                    FilterChip(
                                      label: const Text('Multimodal'),
                                      selected: filterMultimodal,
                                      onSelected: (bool selected) {
                                        setState(() {
                                          filterMultimodal = selected;
                                        });
                                      },
                                      selectedColor: Colors.orange[700],
                                      labelStyle: TextStyle(
                                        color: filterMultimodal ? Colors.white : null,
                                      ),
                                    ),
                                    FilterChip(
                                      label: const Text('Function Calls'),
                                      selected: filterFunctionCalls,
                                      onSelected: (bool selected) {
                                        setState(() {
                                          filterFunctionCalls = selected;
                                        });
                                      },
                                      selectedColor: Colors.purple[600],
                                      labelStyle: TextStyle(
                                        color: filterFunctionCalls ? Colors.white : null,
                                      ),
                                    ),
                                    FilterChip(
                                      label: const Text('Thinking'),
                                      selected: filterThinking,
                                      onSelected: (bool selected) {
                                        setState(() {
                                          filterThinking = selected;
                                        });
                                      },
                                      selectedColor: Colors.indigo[600],
                                      labelStyle: TextStyle(
                                        color: filterThinking ? Colors.white : null,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                // Clear filters button
                                Center(
                                  child: TextButton(
                                    onPressed: _clearFilters,
                                    child: const Text(
                                      'Clear Filters',
                                      style: TextStyle(color: Colors.orange),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          )
                        : null,
                  ),
                ],
              ),
            ),
            // Sort selector
            Container(
              margin: const EdgeInsets.only(bottom: 6.0),
              child: Row(
                children: [
                  const Text(
                    'Sort:',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButton<SortType>(
                      value: selectedSort,
                      isExpanded: true,
                      dropdownColor: const Color(0xFF1B1F2A),
                      underline: Container(
                        height: 1,
                        color: Colors.white.withOpacity(0.20),
                      ),
                      style: const TextStyle(color: Colors.white),
                      icon: const Icon(Icons.arrow_drop_down, color: Colors.white),
                      items: SortType.values.map((type) {
                        return DropdownMenuItem<SortType>(
                          value: type,
                          child: Text(type.displayName),
                        );
                      }).toList(),
                      onChanged: (SortType? newValue) {
                        if (newValue != null) {
                          setState(() {
                            selectedSort = newValue;
                          });
                        }
                      },
                    ),
                  ),
                ],
              ),
            ),
            // Results counter
            Container(
              margin: const EdgeInsets.only(bottom: 4.0),
              child: Text(
                'Showing ${models.length} ${_getModelsWord(models.length)}',
                style: TextStyle(
                  color: Colors.grey[400],
                  fontSize: 14,
                ),
              ),
            ),
            // Models list
            Expanded(
              child: ListView.builder(
                itemCount: models.length,
                itemBuilder: (context, index) {
                  final model = models[index];
                  return ModelCard(model: model);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ModelCard extends StatefulWidget {
  final Model model;

  const ModelCard({super.key, required this.model});

  @override
  State<ModelCard> createState() => _ModelCardState();
}

class _ModelCardState extends State<ModelCard> {
  late PreferredBackend selectedBackend;

  @override
  void initState() {
    super.initState();
    selectedBackend = widget.model.preferredBackend;
  }

  // Check if model supports both backends
  bool get supportsBothBackends {
    // Models that have explicit CPU/GPU support
    // For now, we'll allow switching for all models except local ones
    return !widget.model.localModel;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            decoration: GlassTheme.panel(radius: 20),
            child: ListTile(
              contentPadding: const EdgeInsets.all(16.0),
              title: Text(
                widget.model.displayName,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16.0,
                ),
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 6.0),
                  if (supportsBothBackends) ...[
                    Row(
                      children: [
                        Text(
                          'Backend: ',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.85),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(width: 8),
                        SegmentedButton<PreferredBackend>(
                          segments: const [
                            ButtonSegment<PreferredBackend>(
                              value: PreferredBackend.cpu,
                              label: Text('CPU',
                                  style: TextStyle(fontSize: 12)),
                            ),
                            ButtonSegment<PreferredBackend>(
                              value: PreferredBackend.gpu,
                              label: Text('GPU',
                                  style: TextStyle(fontSize: 12)),
                            ),
                          ],
                          selected: {selectedBackend},
                          onSelectionChanged:
                              (Set<PreferredBackend> selection) {
                            setState(() {
                              selectedBackend = selection.first;
                            });
                          },
                          style: ButtonStyle(
                            visualDensity: VisualDensity.compact,
                            backgroundColor: WidgetStateProperty.resolveWith(
                                (states) {
                              if (states.contains(WidgetState.selected)) {
                                return const Color(0xFF82B1FF)
                                    .withOpacity(0.30);
                              }
                              return Colors.white.withOpacity(0.06);
                            }),
                            foregroundColor:
                                WidgetStateProperty.all(Colors.white),
                            side: WidgetStateProperty.all(
                              BorderSide(
                                  color: Colors.white.withOpacity(0.25)),
                            ),
                            padding: WidgetStateProperty.all(
                              const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 0),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ] else ...[
                    Text(
                      'Backend: ${widget.model.preferredBackend.name.toUpperCase()}',
                      style: TextStyle(
                        color: widget.model.preferredBackend ==
                                PreferredBackend.gpu
                            ? const Color(0xFF80E27E)
                            : const Color(0xFF82B1FF),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                  const SizedBox(height: 6.0),
                  Text(
                    'Size: ${widget.model.size}',
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.55),
                        fontSize: 13),
                  ),
                  if (widget.model.supportsFunctionCalls ||
                      widget.model.supportImage ||
                      widget.model.isThinking) ...[
                    const SizedBox(height: 8.0),
                    Wrap(
                      spacing: 6.0,
                      runSpacing: 4.0,
                      children: [
                        if (widget.model.supportsFunctionCalls)
                          _buildTag('Function Calls',
                              const Color(0xFFB388FF)),
                        if (widget.model.supportImage)
                          _buildTag('Multimodal',
                              const Color(0xFFFFB74D)),
                        if (widget.model.isThinking)
                          _buildTag('Thinking',
                              const Color(0xFF82B1FF)),
                      ],
                    ),
                  ],
                ],
              ),
              trailing: Icon(
                Icons.arrow_forward_ios,
                color: Colors.white.withOpacity(0.5),
                size: 16,
              ),
              onTap: () {
              // Local models are already installed; just dismiss to the
              // caller (settings / model picker) so the app can use the
              // model from the Study Hub.
              if (widget.model.localModel) {
                Navigator.pop(context, true);
              } else {
                // Network models - show download screen with token input
                Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (context) => ModelDownloadScreen(
                      model: widget.model,
                      selectedBackend: selectedBackend,
                    ),
                  ),
                );
              }
            },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTag(String label, Color accent) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: accent.withOpacity(0.20),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: accent.withOpacity(0.55)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          color: accent,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
