# PDFCopy app icon

`AppIcon.png` is the reviewed public source artwork. It depicts a white page and highlighted text on a blue/teal tile, with transparent outer margins. The image was generated with the built-in image-generation tool; no private PDFs, screenshots, or document content were supplied.

The build runs `scripts/build-icon.sh` to resize the artwork into the standard macOS icon representations and assemble `.build/AppIcon.icns`. `scripts/build-app.sh` copies that file to `PDFCopy.app/Contents/Resources/AppIcon.icns`. The bundle's `CFBundleIconFile` points to `AppIcon`.

The source PNG is explicitly allowed by `.gitignore`; the broader exclusions for private screenshots and generated test images remain in place. Compiled iconsets and app bundles stay in ignored build directories.

## Generation prompt

Use case: logo-brand. Asset type: finished macOS app icon for PDFCopy, a private on-device PDF text selection and copying utility. Create one polished square 1024x1024 raster icon, not a mockup or sheet of variants. A clean rounded-square macOS tile with a deep blue-to-teal surface, a centered white paper page with a small folded corner, three simple dark text strokes, and a vivid cyan text-selection highlight across the middle stroke with two subtle selection end marks. Refined softly dimensional materials, restrained edge lighting and depth, calm professional native Mac utility aesthetic. Strong single silhouette and generous margins, readable at tiny Dock sizes. Straight-on orthographic view. Icon fills about 88 percent of the canvas; outside the rounded-square tile is genuinely transparent. No words, letters, numbers, magnifying glasses, padlocks, brand marks, watermarks, desktop background, or extra objects.
