import 'package:flutter/material.dart';
import 'models/embedding_model.dart';
import 'widgets/universal_model_card.dart';

class EmbeddingModelsScreen extends StatefulWidget {
  const EmbeddingModelsScreen({super.key});

  @override
  State<EmbeddingModelsScreen> createState() => _EmbeddingModelsScreenState();
}

class _EmbeddingModelsScreenState extends State<EmbeddingModelsScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          MediaQuery.of(context).padding.top + 116,
          16,
          MediaQuery.of(context).padding.bottom + 16,
        ),
        child: Column(
          children: [
            const Text(
              'RAG Embedding Models',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Download and manage embedding models for Retrieval-Augmented Generation',
              style: TextStyle(
                fontSize: 13,
                color: Colors.white.withOpacity(0.7),
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Expanded(
              child: ListView.builder(
                itemCount: EmbeddingModel.values.length,
                itemBuilder: (context, index) {
                  final model = EmbeddingModel.values[index];
                  return UniversalModelCard(model: model);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
