import 'package:flutter/material.dart';

/// A compile-time test-only warning; production builds do not display it.
/// This is a visual warning, not a security boundary: the build must also be
/// configured for the isolated test Supabase project and a separate origin.
class IsolatedPreviewBanner extends StatelessWidget {
  final Widget child;
  final bool enabled;

  const IsolatedPreviewBanner({
    super.key,
    required this.child,
    this.enabled = const bool.fromEnvironment('FITNESS_ISOLATED_PREVIEW'),
  });

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return Column(
      // The route overlay blocks semantics behind it. Put the banner after
      // the Navigator in paint/semantic order, while keeping it visually on
      // top. Screen-reader users must receive the same safety warning.
      verticalDirection: VerticalDirection.up,
      children: [
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: child,
          ),
        ),
        Material(
          color: const Color(0xff70400b),
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              child: SizedBox(
                width: double.infinity,
                child: Text(
                  'ТЕСТОВАЯ ВЕРСИЯ · Только вымышленные записи. '
                  'Не связана с вашим рабочим дневником.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
