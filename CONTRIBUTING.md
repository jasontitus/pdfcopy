# Contributing

Build on macOS 14 or later using Xcode with Swift 5.9 or later. Follow the [README](README.md) to run the app and tests.

Keep changes focused on the primary workflow: open a PDF, select text, copy, and paste into another app. Read [PLAN.md](PLAN.md) for scope and [VALIDATION.md](VALIDATION.md) for known limitations. The iOS interface, search, image copying, and document questions are future work.

For OCR or selection fixes, add a synthetic regression case that exercises the observed failure. Preserve existing native text, page appearance, selection coordinates, and source files. Run `swift test` and include the relevant result in the pull request.

For bug reports, describe the macOS version, steps, expected behavior, and actual behavior. Include a minimal synthetic example where possible. Do not attach private documents or extracted content; see [PRIVACY.md](PRIVACY.md).
