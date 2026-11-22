# OACDP: living drawings and design guide

Written by Claude (claude.ai) on 2026-11-21 from the "OACDP brake diagram concept" design canvas (rounds 1-5, approved by Lincoln). Use it as the brief for building the real interactive pages in the Jekyll site. The concept itself is in `concept-reference.html`, kept outside the repository in `/workspaces/oacdp-notes/design/` and never committed, because it contains a traced manual page (a design-canvas file: read its `<style>` block and the `class Component` script for exact behaviour; its `/_blob/...` image links only work inside claude.ai).

Status of the concept's data: transcribed by Claude for the mockup, **not verified**. The site must use the repo's data files (`src/_data/parts/...`) and show their verification status.

---

## Part 1. How the drawings are made ("living drawings")

The drawings are **traced from VW's original page pixels into vector shapes**, not redrawn or AI-generated. Every line is the draughtsman's original line work. Reference implementation: `trace_ill32_reference.py`, also kept in `/workspaces/oacdp-notes/design/` and never committed (Python; numpy, pillow, scipy, scikit-image, all free).

### Pipeline
1. **Source pixels.** Extract the page's embedded image with `pdfimages -png` (never a render or screenshot): exact 300 dpi 1-bit pixels.
2. **Orient and crop.** Rotate 90 degrees clockwise (the drawings are printed sideways), crop to the drawing area, and map to a user space of half the pixel size (Illustration 32: crop 260,330 to 3300,1830, viewBox 0 0 1520 750).
3. **Separate the ink.** Connected-component labelling (`scipy.ndimage.label`, 8-connectivity). On clean exploded drawings each part's outline is mostly one component.
4. **Assign components to keys.** Components larger than 2,500 px are assigned by their centre to hand-drawn key regions, **first match wins**, so order the regions from small/specific to large/general. Everything else (leader lines, numbers, small hardware) goes to one shared "lines" layer. Hand-tuning took about 15-30 minutes per drawing.
5. **Trace smooth outlines.** Per component: pad, upsample 2x (linear), Gaussian blur (sigma 1.4), `skimage.measure.find_contours` at level 0.5 (0.42 for the lines layer so thin strokes survive), simplify with `approximate_polygon` (tolerance 1.2), drop components under 4 px.
6. **Write SVG.** One `<path>` per key (all its components concatenated) plus one `<path>` for the lines layer, all with `fill-rule: evenodd` so holes stay hollow. Also output each key's bounding box (for hit areas and camera focus) and each callout label's position (for rings).

### Known limits
- No detail is added beyond the scan; tracing only makes the existing detail sharp.
- Small parts stay in the lines layer unless given their own region.
- Leader lines touching a part merge into it; automatic closing of gaps damaged digits and was reverted.
- Each drawing needs per-drawing region tuning and a person's check that parts got the right keys. Record which keys have their own shape.

### Recommended for the repo
- Make the tracer a repeatable tool under `scripts/` that reads its per-drawing settings (crop, regions, label positions) from a small data file, and writes generated SVG/JSON outside `src/` or into a clearly generated folder. Ruby is the repo's tooling language; Python with scikit-image or the free `potrace` CLI are acceptable for this one step if documented. No paid tools. Never commit page images.

---

## Part 2. Design system

### Principles
- **Muted, quiet base; period colour only where it means something** (selection, navigation, status).
- **VW simplicity:** generous space, geometric type, few colours, clear hierarchy.
- **The drawing is the hero.** Everything else supports finding and confirming a part.
- **The original scan is always one click away.**

### Colour tokens (Type 2, 1959-63 inspired)
| Token | Hex | Use |
|---|---|---|
| page | `#FAFAF8` | Page background (off-white, not beige) |
| surface | `#FFFFFF` | Cards, stage, list |
| ink | `#111111` / `#000000` | Drawing lines, body text |
| ink-muted | `#5B5F60` / `#3E4243` | Secondary text |
| line | `#E4E6E6`, `#CFD3D4` | Hairlines, borders |
| sealing-wax-red | `#9E1B22` | Selection, active nav underline, focus outline, key dots |
| red-hover | `#B8343B` | Hovered part fill |
| beige-grey | `#B9AE97` | Paired with red (logo history, segmented control "on", accents) |
| pearl-white | `#ECE9DF` | Logo top half; text on the dark bus band |
| mouse-grey | `#8E8F8A` | Logo bottom half; base hue of the bus band gradient |
| mango-green | `#B9C06E` | "Fits" status |
| amber | `#E9B04F` | "Use another part" status dot on dark |
| dimmed part | `#A7A9A4` | Non-hovered parts while another is hovered |
| selected row | `#F1ECE2` + 5px red inset left bar | Selected list row |

Contrast: never put white text on flat Mouse Grey (too faint); on the bus band use Pearl White on the darkened gradient. Keep text at 4.5:1 or better.

### Typography
- **Jost** (geometric, Futura-like, free under the SIL Open Font License), weights 300-700 (300, 400, 500, 600 and 700). The concept loads it from Google Fonts; **the site should self-host it** (privacy, no third-party requests, works offline). Include weight 300 (used by the nav numbers).
- Tabular, lining numerals (`font-variant-numeric: tabular-nums lining-nums`) for every part number, chassis number and key.
- Sizes: page titles 30px/500; section titles 22-24px/600; body 15-16px; small labels 12-14px. Eyebrow labels: 12px, 600, uppercase, letter-spacing 0.18em.

### Components
1. **Header.** White, hairline bottom border. Logo: a 40px circle, Pearl White top half, Mouse Grey bottom half, 1px `#6F716C` ring, next to "OACDP" (22px/700, letter-spacing 0.08em) and the full project name below (13px, muted). Right side: Manuals, Parts, About the archive, and a rounded search field ("Part number or part name").
2. **"Your bus" band.**
   - Background: 115-degree linear gradient `#555752 -> #62645F -> #4A4C48 -> #3A3C39` (each stop keeps Pearl White text at 4.5:1 or better; the earlier `#7A7C76` stop failed), `background-size: 180%`, slowly drifting (22s, ease-in-out, alternate).
   - Fine grain overlay: SVG `feTurbulence` noise as a data-URI background, opacity about 0.22, `mix-blend-mode: overlay`.
   - Soft Pearl White radial glow at the top right.
   - Text Pearl White; eyebrow "YOUR BUS"; title "Type 2 Transporter, 1958 to 1967"; help text "The chassis number is on the M-plate in the cab and stamped in the engine bay."
   - Chassis field: darkened (black at 15%; the concept's Pearl White 10% tint drops Pearl White text to 4.0:1 on the `#62645F` stop, this keeps 6.2:1 or better), Pearl White text, 1px Pearl White border at 45% (80% on hover), backdrop blur, Pearl White focus outline.
   - Status chip: dark translucent pill with a coloured dot (Mango Green = fits, amber = use another part, Pearl White = neutral), `aria-live="polite"`.
3. **Main-group navigation** (Lincoln likes this one).
   - A strip between hairlines, no pills. Each tab: large light number (30px/300) above the group name (14px).
   - Hover: soft background `#F1EFEA`, number lifts 3px, a 3px Sealing Wax Red underline sweeps in from the left (`transform: scaleX(0 -> 1)`, 0.4s).
   - Current group: red text and the underline stays. Scrolls sideways on phones.
4. **Drawing stage.** White card, 18px radius, full width. Toolbar: zoom in/out, fit all, and a segmented "Traced / Original scan" switch. A chip shows the selected part's name and number. Caption below says what the user is looking at.
5. **Parts list.** Columns: key dot, part no., description, qty, "For your bus" (fit status). Rows are buttons; selected row gets the red inset bar.
6. **Detail panel.** Key, description, part number, quantity, applicability (verbatim), fit verdict, earlier/later versions with their own fit, a thumbnail of the original list page that opens full size, and (planned) "History of this part" timeline with Progressive Refinements notes.
7. **Status labels.** "Checked by a person" / "Machine-read, readings agree" / "Machine-read, needs checking" on every part record, never hidden.

---

## Part 3. Motion and interaction

### Easing and timing
- Standard easing: `cubic-bezier(.2,.8,.2,1)` (fast start, gentle settle).
- Hover colour/opacity: 0.25-0.35s. Lifts and underlines: 0.4-0.45s. Camera flights: 0.75s `cubic-bezier(.2,.75,.2,1)`. Scan/tracing crossfade: 0.45s.
- Ambient motion (band drift, ring pulse) is slow (2.4s-22s) and subtle.
- **`prefers-reduced-motion: reduce`** turns off the drift, pulse, lifts and camera transitions; colour changes stay but shorten.

### The drawing
- **Camera:** one `<g>` holds the scan image, traced layers, hit areas and rings, transformed with `translate(center) scale(s) translate(-cx, -cy)`, `transform-origin: 0 0`. Zoom 1x-6x, clamped so the drawing never leaves the frame. Wheel zoom about the pointer (non-passive listener), drag to pan (pointer capture only after 6px of movement so clicks still work), two-finger pinch, zoom buttons, fit-all.
- **Select** (click part, ring or list row): camera flies to the part's box; part turns Sealing Wax Red, lifts 3px with a soft red shadow; its ring fills lightly and **pulses**.
- **Hover** (part, ring or list row): the part lifts 7px and scales 1.5% with a deeper red shadow and turns `#B8343B`; **all other parts fade to `#A7A9A4` and the lines layer to 40%** (focus effect); its ring thickens to 4px; a **floating label** (dark pill: red key circle + part name, kept at constant size by scaling it by 1/zoom, flipping to the left near the edge) appears by its callout. Hovering a list row does the same in the drawing.
- **Traced / Original:** crossfade in the same camera, so zoom and position persist.
- **Hit areas:** invisible boxes over each part and 17px rings over each callout number; larger than the thin outlines so they are easy to hit; parts use `transform-box: fill-box; transform-origin: center` so lifts work on SVG paths.

### Accessibility (acceptance criteria, not polish)
- Everything in the drawing is reachable from the parts list by keyboard; list rows also trigger the hover highlight on focus.
- Visible focus: 3px Sealing Wax Red outline, 2px offset (Pearl White on the dark band).
- Don't rely on colour alone: fit status always has text; selection also lifts and shows the label.
- The drawing has a text alternative pointing to the list. Touch: tap selects (no hover); pinch and drag work.
- Works without JavaScript at a basic level: the list, part details and the original scan remain usable.

---

## Part 4. Cost and privacy rules
- Free only: no paid fonts, libraries, APIs or hosting tiers. Warn Lincoln before anything that could cost money.
- Self-host fonts; no trackers.
- No framework is needed: plain SVG, CSS and a small script, consistent with the static Jekyll site.
