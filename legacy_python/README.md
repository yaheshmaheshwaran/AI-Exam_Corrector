# Superseded Python implementation

This is the original Tkinter version of Exam Corrector, kept for reference
while the Flutter Windows rewrite settles. **It is not part of the
application** — nothing in `lib/` imports it and it is not built or packaged.

Every part of it was carried across rather than reinvented:

| Python | Dart |
| --- | --- |
| `app/config.py` | `lib/core/config/app_config.dart` |
| `app/core/models.py` | `lib/models/` |
| `app/core/validation.py` | `lib/services/correction_validation_service.dart` |
| `app/services/pdf_extractor.py` | `lib/services/pdf_service.dart` |
| `app/services/ai/base.py` | `lib/services/ai/correction_service.dart` |
| `app/services/ai/prompt.py` | `lib/services/ai/correction_prompt.dart` |
| `app/services/ai/anthropic_service.py` | `lib/services/ai/anthropic_correction_service.dart` |
| `app/ui/main_window.py` | `lib/screens/home/home_screen.dart` + `lib/widgets/` |
| `app/ui/results_view.py` | `lib/widgets/results_view.dart` |

The correction prompt, the JSON response schema, the validation rules and every
teacher-facing error message are ported verbatim, so marking behaviour is
unchanged.

Delete this directory (and the `.venv/` at the project root) once you are happy
with the Flutter version.
