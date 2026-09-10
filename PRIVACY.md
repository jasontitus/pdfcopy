# Privacy and local data

## App behavior

PDFCopy uses Apple's Vision framework for on-device OCR. The app has no account system, analytics, remote OCR service, third-party SDK, or application network code. It does not upload PDFs or extracted text.

The selected PDF and derived text layers are held in memory while open. When Remember OCR is enabled (the default), completed derived PDFs are also stored in a device-local cache for faster reopening. These copies contain document content and recognized text. The original PDF is never overwritten. The cache uses content-hash filenames and an engine/OS version, is excluded from backups, is limited to 256 MB / 20 entries, and removes entries after 30 days without access when next accessed. iOS cache files use complete file protection; cache files use owner-only permissions. Password-protected PDFs are never cached. Saved Text Settings can clear the cache or disable caching; disabling also clears existing copies. Clear does not remove the currently displayed PDF from memory. It prevents outstanding recognition work from recreating cleared cache entries. This is ordinary file deletion, not guaranteed secure erasure. Focused-area OCR previews remain in memory and are not cached. A PDF password is used to unlock the document; the app does not save it to preferences or a credential store.

Copy explicitly writes the selected content to the system clipboard. Clipboard managers, Universal Clipboard, destination apps, OS diagnostics, and files already stored in a synced folder follow the user's system settings. The Mac development app is not a hardened sandbox. The iOS app uses the standard application sandbox and security-scoped Files access. Neither is a secure-erasure tool. A document provider may download a PDF from the user’s existing cloud storage before opening it. Search queries and results remain in memory and are cleared when another PDF opens.

## Tests and development

The default tests generate synthetic PDFs. Private PDF tests are opt-in through `PDFCOPY_TEST_DOCUMENTS`. They write extracted text, page images, document filenames, and selection diagnostics under `.build/validation` by default. `PDFCOPY_TEST_OUTPUT` can redirect that output; a custom destination may not be covered by this repository's ignore rules.

Keep private input documents outside the repository. Never upload private PDFs, OCR output, screenshots, credentials, or unsanitized logs to issues, pull requests, or CI artifacts. Use a synthetic reproduction when reporting a bug. Check window titles and file paths as well as visible page content before sharing screenshots.

The public [validation summary](VALIDATION.md) contains anonymized aggregate results only. Local test artifacts, application bundles, and personal document references are excluded from the published source.

## Before publishing changes

Review the exact staged files and commit metadata, not just the working directory. Ignore rules prevent ordinary additions but can be overridden with `git add -f`. A secret scanner supplements manual review; it does not prove that arbitrary personal data is absent.
