/// The API-key connection type (user-designed IA, 2026-08-02 v2: each
/// connection type gets its OWN page). Six vendors as a checkmark list;
/// the selected vendor's key + model configuration appears below it.
/// Pay-per-photo, key on this phone.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../../ai_consent.dart';
import '../../services.dart' show SettingsStore;
import '../../l10n.dart';
import '../../theme/tokens.dart';
import '../../widgets/grouped.dart';
import 'settings_kit.dart';
import 'provider_page.dart'
    show
        defaultModelFor,
        kApiKeyChoices,
        kCustomModelSentinel,
        kKnownModels,
        isCuratedModel,
        modelChoiceLabel,
        noteLabel,
        providerLabel;

class ApiKeyProviderPage extends StatefulWidget {
  const ApiKeyProviderPage({super.key, required this.settings});
  final SettingsStore settings;

  @override
  State<ApiKeyProviderPage> createState() => _ApiKeyProviderPageState();
}

class _ApiKeyProviderPageState extends State<ApiKeyProviderPage> {
  late final TextEditingController _keyController;
  late final TextEditingController _modelController;
  late bool _customModel;

  /// Show the key while checking a paste (U5); hidden by default.
  bool _keyVisible = false;

  bool get _apiActive => widget.settings.provider != 'server';

  @override
  void initState() {
    super.initState();
    _keyController = TextEditingController(
        text: _apiActive ? widget.settings.apiKey : '');
    _modelController = TextEditingController(text: widget.settings.model);
    _customModel =
        !isCuratedModel(widget.settings.provider, widget.settings.model);
  }

  @override
  void dispose() {
    _keyController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  Future<void> _selectProvider(String id) async {
    if (id == widget.settings.provider) return;
    HapticFeedback.selectionClick();
    // A new AI recipient while Watch Camera Roll is on: ask now (App Store
    // 5.1.2(i)); Not now keeps the previous provider.
    if (!await confirmAiRecipientChange(context, widget.settings,
            provider: id, serverBackend: widget.settings.serverBackend) ||
        !mounted) {
      return;
    }
    await widget.settings.update(provider: id);
    if (!mounted) return;
    setState(() {
      // Key/model fields are provider-scoped: reload them from the newly
      // selected provider's stored values.
      _keyController.text = widget.settings.apiKey;
      _modelController.text = widget.settings.model;
      _customModel =
          !isCuratedModel(widget.settings.provider, widget.settings.model);
    });
  }

  String _modelHelperText(BuildContext context) {
    final provider = widget.settings.provider;
    final model = defaultModelFor(provider);
    final l = context.l10n;
    return switch (provider) {
      'qwen' => l.modelHelperQwen(model),
      'doubao' => l.modelHelperDoubao(model),
      'glm' => l.modelHelperGlm(model),
      'deepseek' => l.modelHelperDeepseek(model),
      'openrouter' => l.modelHelperOpenrouter(model),
      _ => l.modelHelperDefault(model),
    };
  }

  /// Where the key comes from — the footer's job.
  String _keyFooter(BuildContext context) =>
      switch (widget.settings.provider) {
        'gemini' => context.l10n.apiKeyFooterGemini,
        'openai' => context.l10n.apiKeyFooterOpenai,
        'anthropic' => context.l10n.apiKeyFooterAnthropic,
        'qwen' => context.l10n.apiKeyFooterQwen,
        'doubao' => context.l10n.apiKeyFooterDoubao,
        'glm' => context.l10n.apiKeyFooterGlm,
        'deepseek' => context.l10n.apiKeyFooterDeepseek,
        'xai' => context.l10n.apiKeyFooterXai,
        'openrouter' => context.l10n.apiKeyFooterOpenrouter,
        _ => context.l10n.apiKeyFooterDefault,
      };

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    return GroupedPage(
      title: context.l10n.apiPageTitle,
      children: [
        GroupedSection(
          header: context.l10n.apiProviderHeader,
          footer: context.l10n.apiProviderFooter,
          separatorInset: AppSpace.separatorInset,
          children: [
            for (final (id, name, note) in kApiKeyChoices)
              GroupedRow(
                key: Key('providerChoice-$id'),
                title: name,
                value: noteLabel(context.l10n, note),
                selected: settings.provider == id,
                showChevron: false,
                trailing: settings.provider == id
                    ? Icon(Icons.check_rounded,
                        size: 20, color: context.colors.accent)
                    : const SizedBox(width: 20),
                onTap: () => _selectProvider(id),
              ),
          ],
        ),
        if (_apiActive) ...[
          GroupedSection(
            header: context.l10n.apiKeyHeader,
            footer: _keyFooter(context),
            children: [
              cellField(TextField(
                key: const Key('apiKeyField'),
                controller: _keyController,
                obscureText: !_keyVisible,
                autocorrect: false,
                // Show key turns obscuring off, and with it Android's
                // no-suggestions/password flags: the keyboard offered
                // suggestions and could learn the secret into its
                // dictionary. Off for good, shown or not.
                enableSuggestions: false,
                enableIMEPersonalizedLearning: false,
                // Saves as you type — a paste-then-switch-tab can never
                // lose the key.
                onChanged: (v) => settings.update(apiKey: v.trim()),
                onSubmitted: (v) => settings.update(apiKey: v.trim()),
                onTapOutside: (_) =>
                    settings.update(apiKey: _keyController.text.trim()),
                decoration: cellFieldDecoration(
                  context,
                  labelText: context.l10n
                      .apiKeyLabel(providerLabel(settings.provider)),
                ).copyWith(
                  suffixIcon: IconButton(
                    key: const Key('apiKeyVisibility'),
                    tooltip: _keyVisible
                        ? context.l10n.apiKeyHide
                        : context.l10n.apiKeyShow,
                    icon: Icon(_keyVisible
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined),
                    onPressed: () =>
                        setState(() => _keyVisible = !_keyVisible),
                  ),
                ),
              )),
            ],
          ),
          GroupedSection(
            header: context.l10n.modelHeader,
            footer: _customModel ? _modelHelperText(context) : null,
            separatorInset: AppSpace.separatorInset,
            children: [
              cellField(KeyedSubtree(
                key: ValueKey('modelPicker-${settings.provider}'),
                child: DropdownButtonFormField<String>(
                  key: const Key('modelPicker'),
                  isExpanded: true,
                  // Body text like every row: Material's titleMedium made
                  // the model read as a heading and cut its label short.
                  style: Theme.of(context)
                      .textTheme
                      .bodyLarge
                      ?.copyWith(color: context.colors.label),
                  initialValue: _customModel
                      ? kCustomModelSentinel
                      : settings.model,
                  decoration: cellFieldDecoration(context),
                  items: [
                    for (final (id, label)
                        in kKnownModels[settings.provider] ??
                            const <(String, String)>[])
                      DropdownMenuItem(
                          value: id,
                          child: Text(
                              modelChoiceLabel(context.l10n, label))),
                    DropdownMenuItem(
                        value: kCustomModelSentinel,
                        child: Text(context.l10n.modelCustomRow)),
                  ],
                  // The closed picker shows the choice on one line,
                  // ellipsised; the open menu keeps every label whole.
                  selectedItemBuilder: (context) => [
                    for (final (_, label)
                        in kKnownModels[settings.provider] ??
                            const <(String, String)>[])
                      Text(modelChoiceLabel(context.l10n, label),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(context.l10n.modelCustomRow,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                  onChanged: (v) async {
                    if (v == null) return;
                    if (v == kCustomModelSentinel) {
                      setState(() => _customModel = true);
                      return;
                    }
                    await settings.update(model: v);
                    if (!mounted) return;
                    setState(() {
                      _customModel = false;
                      _modelController.text = v;
                    });
                  },
                ),
              )),
              if (_customModel)
                cellField(TextField(
                  key: const Key('modelField'),
                  controller: _modelController,
                  autocorrect: false,
                  onSubmitted: (v) => settings.update(model: v.trim()),
                  onTapOutside: (_) => settings.update(
                      model: _modelController.text.trim()),
                  decoration: cellFieldDecoration(
                    context,
                    labelText: context.l10n.modelCustomLabel,
                  ),
                )),
            ],
          ),
        ] else
          GroupedSection(
            footer: context.l10n.apiInactiveFooter,
            children: const [],
          ),
      ],
    );
  }
}
