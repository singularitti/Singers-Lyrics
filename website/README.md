# App showcase

Created on 2026-10-31 to introduce Singers Lyrics through the supplied Mac, iPhone, and iPad screenshots. This is a buildless, responsive website with English and Simplified Chinese copy, screenshot enlargement, documentation links, and the published macOS v1.0.0 download.

## Files and publishing

- `index.html`: page content, accessible screenshot links, and release links.
- `styles.css`: responsive layouts, device frames, and reduced-motion support.
- `script.js`: optional language switching and screenshot dialogs. The page and image links remain usable without JavaScript. Only the selected language is stored locally; the site includes no analytics or third-party scripts, fonts, or embeds.
- `assets/`: web-ready image derivatives described below.
- `.nojekyll`: preserves static-file serving.
- `../.github/workflows/pages.yml`: deploys this directory to GitHub Pages when it or the workflow changes on `main`. It can also be run manually. Repository Pages settings use GitHub Actions as the source.

Preview from the repository root with `python3 -m http.server 4173 --bind 127.0.0.1 --directory website`, then visit `http://127.0.0.1:4173`. No package installation or build step is required.

## Image provenance

The original screenshots remain in `~/Downloads`; they were not moved or committed. The published files are derived from those originals, with metadata stripped during WebP encoding. The visible app content is not synthesized or retouched.

| Source | Published derivative | Preparation |
| --- | --- | --- |
| `~/Downloads/lyrcis mac.png` | `assets/mac-workspace.webp` | Resized from 5344 × 3044 to 2672 × 1522; transparency preserved |
| Same Mac PNG | `assets/mac-workspace-small.webp` | 1344-pixel-wide responsive version |
| `~/Downloads/lyrics ipad.png` | `assets/ipad-settings.webp` | Original 2266 × 1488 dimensions; settings and displayed sync status preserved |
| `~/Downloads/lyrics iphone.heic` | `assets/iphone-editor.webp` | Converted to PNG before WebP encoding; removed the top 160 pixels containing the system status bar and unrelated live activity; app interface preserved at 1179 × 2396 |
| App asset `SingersLyrics/Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256.png` | `assets/app-icon.webp` | Existing app artwork converted to WebP |

Conversion uses macOS `sips` for HEIC decoding and `cwebp -q 92 -m 6 -metadata none` for browser assets. Mac image variants additionally use `-resize 2672 0` and `-resize 1344 0`; the iPhone derivative uses `-crop 0 160 1179 2396`. Device outlines and backgrounds are CSS, not part of the screenshots. Temporary conversion files are not published.

## Content maintenance

Feature claims come from the repository README and app documentation. The iPad image demonstrates settings, not completed synchronization. Apple Music playback needs the relevant account access and permissions; iCloud synchronization is optional and requires setup. iPhone and iPad setup links point to the build instructions, with no App Store availability claim.

Update both the English HTML and the Chinese dictionary in `script.js` when changing copy. Update both download buttons and the version link together when adopting a newer verified release. Keep all asset paths relative so the site works under the repository's GitHub Pages subpath.
