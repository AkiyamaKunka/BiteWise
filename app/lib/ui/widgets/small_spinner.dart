import 'package:flutter/cupertino.dart' show CupertinoActivityIndicator;
import 'package:flutter/material.dart';

/// The small inline progress indicator that stands in for a button icon
/// or a row's trailing widget while that action runs: the platform's own
/// (iOS: the activity indicator, sized to [size]; elsewhere a thin ring),
/// as CircularProgressIndicator.adaptive picks — but at the requested
/// size, which .adaptive's fixed 20-pt iOS indicator ignores.
class SmallSpinner extends StatelessWidget {
  const SmallSpinner({super.key, this.size = 16});

  final double size;

  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    final ios =
        platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;
    return SizedBox(
      width: size,
      height: size,
      child: ios
          ? CupertinoActivityIndicator(radius: size / 2)
          : const CircularProgressIndicator(strokeWidth: 2),
    );
  }
}
