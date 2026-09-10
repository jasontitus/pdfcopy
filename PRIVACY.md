# Privacy and local data

## App behavior

PDFCopy uses Apple's Vision framework for on-device OCR. The app has no account system, analytics, remote OCR service, third-party SDK, or application network code. It does not upload PDFs or extracted text.

The selected PDF and derived text layers are held in memory. The app does not save OCR results, overwrite the original file, or create a persistent document library. Reopening a file runs recognition again. A PDF password is used to unlock the document; the app does not save it to preferences or a credential store.

Copy explicitly writes the selected content to the system clipboard. Clipboard managers, Universal Clipboard, destination apps, OS diagnostics, and files already stored in a synced folder follow the user's system settings. The development app is not a hardened sandbox or a secure-erasure tool.

## Tests and development

The default tests generate synthetic PDFs. Private PDF tests are opt-in through `PDFCOPY_TEST_DOCUMENTS`. They write extracted text, page images, document filenames, and selection diagnostics under `.build/validation` by default. `PDFCOPY_TEST_OUTPUT` can redirect that output; a custom destination may not be covered by this repository's ignore rules.

Keep private input documents outside the repository. Never upload private PDFs, OCR output, screenshots, credentials, or unsanitized logs to issues, pull requests, or CI artifacts. Use a synthetic reproduction when reporting a bug. Check window titles and file paths as well as visible page content before sharing screenshots.

The public [validation summary](VALIDATION.md) contains anonymized aggregate results only. Local test artifacts, application bundles, and personal document references are excluded from the published source.

## Before publishing changes

Review the exact staged files and commit metadata, not just the working directory. Ignore rules prevent ordinary additions but can be overridden with `git add -f`. A secret scanner supplements manual review; it does not prove that arbitrary personal data is absent.
