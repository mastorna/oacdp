# Parts data, VW Transporter Parts List 1960-1967 (August 1963)

Machine-read data for the whole book. **Nothing here is checked by a person yet.**

- `catalog/`: one YAML file per illustration, plus `ill-unknown-<group>.yml` for list
  pages not yet matched to an illustration. Every row is `unverified` and labelled
  `readings agree` (two machine readings agree and the part number has a normal
  shape) or `needs checking` (with `confidence_reasons`). Made by
  `scripts/parts/catalog.rb`; check with `ruby scripts/check-parts.rb --catalog
  data/parts/vw-tpl-1963-08/catalog`.
- `ai-sample-reading.yml`: an AI reading of 32 sample pages (Illustrations 3, 46 and 60
  and 20 random list pages, seed 1963), used to measure the machine readings.
- `qa-reports.jsonl`: problems reported from the parts preview (one JSON object per
  line), when there are any.

Related, elsewhere in the repository:
- `src/_data/parts/vw-tpl-1963-08/page-map.yml`: the page map (future table of contents).
- `src/_data/parts/vw-tpl-1963-08/page-decisions.yml`: decisions a person made.
- `src/_data/parts/vw-tpl-1963-08/ill32.yml`: Illustration 32 with the AI reading and callouts.

This folder is outside `src/`, so the site build does not load it. Page images,
raw OCR output, the SQLite file and the JSON search index are not committed; they
are rebuilt (see README "Parts data").
