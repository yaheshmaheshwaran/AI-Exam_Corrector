
import 'package:flutter/material.dart';

import 'package:exam_corrector/shared/ui/frosted.dart';

/// Opens a dialog the way `showDialog` does. With glass blur on, the window
/// behind is softly blurred and only faintly dimmed, so the dialog floats as
/// a frosted sheet without a heavy dark scrim. With it off, this is
/// `showDialog` exactly.
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  if (!glassActive(context)) {
    return showDialog<T>(context: context, builder: builder, barrierDismissible: barrierDismissible);
  }
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierColor: Colors.black.withValues(alpha: 0.06),
    builder: (BuildContext context) => Stack(
      children: <Widget>[
        // Taps pass through to the barrier, so a click outside still closes.
        const Positioned.fill(child: IgnorePointer(child: _DialogFrost())),
        builder(context),
      ],
    ),
  );
}

/// The blur behind a dialog, following the glass blur setting as it
/// changes — so the switch in Settings shows its effect at once.
class _DialogFrost extends StatelessWidget {
  const _DialogFrost();

  @override
  Widget build(BuildContext context) {
    final double sigma = 10 * glassStrength(context);
    if (sigma <= 0) return const SizedBox.expand();
    return BackdropFilter(
      filter: glassFilter(sigma),
      child: const SizedBox.expand(),
    );
  }
}
