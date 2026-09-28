
import 'package:flutter/material.dart';

import 'package:exam_corrector/widgets/ui/frosted.dart';

/// Opens a dialog the way `showDialog` does. With transparency on, the
/// window behind is softly blurred as well as dimmed, so the dialog stands
/// out without a heavy dark scrim; the dialog itself stays solid. With it
/// off, this is `showDialog` exactly.
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  if (!glassActive(context)) {
    return showDialog<T>(context: context, builder: builder, barrierDismissible: barrierDismissible);
  }
  final bool dark = Theme.of(context).brightness == Brightness.dark;
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierColor: Colors.black.withValues(alpha: dark ? 0.35 : 0.1),
    builder: (BuildContext context) => Stack(
      children: <Widget>[
        // Taps pass through to the barrier, so a click outside still closes.
        const Positioned.fill(child: IgnorePointer(child: _DialogFrost())),
        builder(context),
      ],
    ),
  );
}

/// The blur behind a dialog, following the transparency setting as it
/// changes — so moving the slider in Settings shows its effect at once.
class _DialogFrost extends StatelessWidget {
  const _DialogFrost();

  @override
  Widget build(BuildContext context) {
    final double sigma = 12 * glassStrength(context);
    if (sigma <= 0) return const SizedBox.expand();
    return BackdropFilter(
      filter: glassFilter(sigma),
      child: const SizedBox.expand(),
    );
  }
}
