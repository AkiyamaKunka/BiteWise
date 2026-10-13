import 'package:flutter/material.dart';

/// The small inline progress indicator that stands in for a button icon
/// or a row's trailing widget while that action runs.
class SmallSpinner extends StatelessWidget {
  const SmallSpinner({super.key, this.size = 16});

  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
      width: size,
      height: size,
      child: const CircularProgressIndicator(strokeWidth: 2));
}
