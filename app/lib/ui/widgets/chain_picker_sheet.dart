/// 'Which restaurant?' (design R7b, decision "Feedback actions"): after
/// 'Wrong restaurant' the user names the chain themselves, from the app's
/// own US chain table only (shared/chains/us_chains.json). Nothing here
/// comes from Apple Maps — the design rejected listing nearby place names,
/// which would store and show Map Data (Apple's developer license
/// Attachment 6) — so the list is the table, filtered by what is typed.
library;

import 'package:flutter/material.dart';

import '../../core/chain_match.dart' show chainTokens;
import '../../core/shared_generated.dart' show SharedChain, sharedUsChains;
import '../l10n.dart';

/// At most this many rows are listed for a query.
const int chainPickerMaxRows = 50;

/// The chain's name as the picker lists it: the table's Chinese name in
/// the Chinese UI when it has one, else its canonical name.
String chainPickerLabel(SharedChain chain, {required bool zh}) {
  final z = chain.zhName;
  return zh && z != null && z.isNotEmpty ? z : chain.name;
}

/// The table's chains matching [query] (its name, an alias or its Chinese
/// name contains what is typed, ignoring case, accents, apostrophes and
/// spaces), sorted by the listed name, [exclude] left out.
/// An empty query lists every chain. Only table rows, ever.
///
/// A name is searched with and without its leading "The": chainTokens
/// drops it from "The Cheesecake Factory" but keeps a query of just "The"
/// (or "Thecheese", one token), and the chain must not vanish while its
/// name is typed.
List<SharedChain> chainPickerMatches(
  String query, {
  String? exclude,
  bool zh = false,
}) {
  final q = chainTokens(query);
  final compact = q.join();
  bool matches(SharedChain c) {
    if (q.isEmpty) return true;
    for (final v in [c.name, ...c.aliases, if (c.zhName != null) c.zhName!]) {
      if (chainTokens(v).join().contains(compact) ||
          chainTokens(v, keepLeadingThe: true).join().contains(compact)) {
        return true;
      }
    }
    return false;
  }

  final out = [
    for (final c in sharedUsChains)
      if (c.key != exclude && matches(c)) c,
  ];
  out.sort(
    (a, b) => chainPickerLabel(
      a,
      zh: zh,
    ).toLowerCase().compareTo(chainPickerLabel(b, zh: zh).toLowerCase()),
  );
  return out;
}

class ChainPickerSheet extends StatefulWidget {
  const ChainPickerSheet({super.key, this.exclude});

  /// The chain the user just called wrong: not offered again.
  final String? exclude;

  @override
  State<ChainPickerSheet> createState() => _ChainPickerSheetState();
}

class _ChainPickerSheetState extends State<ChainPickerSheet> {
  final TextEditingController _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final zh = l.localeName.startsWith('zh');
    final rows = chainPickerMatches(
      _query.text,
      exclude: widget.exclude,
      zh: zh,
    );
    final shown = rows.take(chainPickerMaxRows).toList();
    final height = MediaQuery.sizeOf(context).height * 0.75;
    // The pinned search field covers the rows scrolled under it.
    final sheetTheme = theme.bottomSheetTheme;
    final background = sheetTheme.modalBackgroundColor ??
        sheetTheme.backgroundColor ??
        (theme.useMaterial3
            ? theme.colorScheme.surfaceContainerLow
            : theme.canvasColor);
    // One scroll view: the title scrolls away and the search field stays
    // pinned above the rows. With a fixed title and field over an
    // Expanded list, the keyboard (the field autofocuses) left the list
    // 0 px at the largest text size on a 320 pt phone, and 16 px on a
    // phone in landscape.
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SizedBox(
          height: height,
          child: CustomScrollView(
            key: const Key('chainPickerList'),
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Text(
                    l.assistPickerTitle,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              PinnedHeaderSliver(
                child: ColoredBox(
                  color: background,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: TextField(
                      key: const Key('chainPickerSearch'),
                      controller: _query,
                      autofocus: true,
                      textInputAction: TextInputAction.search,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        hintText: l.assistPickerSearch,
                        prefixIcon: const Icon(Icons.search),
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                ),
              ),
              if (shown.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      l.assistPickerNone,
                      key: const Key('chainPickerNone'),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                )
              else
                SliverList.builder(
                  itemCount: shown.length,
                  itemBuilder: (context, i) {
                    final c = shown[i];
                    final label = chainPickerLabel(c, zh: zh);
                    return ListTile(
                      key: Key('chainPick-${c.key}'),
                      title: Text(label),
                      // The English name under a Chinese one, so the
                      // chain is never a guess.
                      subtitle: label == c.name ? null : Text(c.name),
                      onTap: () => Navigator.pop(context, c.key),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shows the chain search; the picked chain's key, or null.
Future<String?> showChainPickerSheet(BuildContext context, {String? exclude}) =>
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => ChainPickerSheet(
        key: const Key('chainPickerSheet'),
        exclude: exclude,
      ),
    );
