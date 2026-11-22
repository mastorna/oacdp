# OACDP: Obsolete Air Cooled Documentation Project

1. About
1. Dependencies
1. Building
1. Viewing
1. Developing
1. License

## About:

The Obsolete Air Cooled Documentation Project is focused on providing access to
hard to find, out of print resources for air cooled automobile enthusiasts.  This 
repository is the source for building the site.  It uses Jekyll, a ruby
static site generator.  (It originally used webgen 0.5.10, which no longer
runs on current Ruby; see docs/decisions/0001-move-build-to-jekyll.md.)

## Dependencies


  + [Ruby](https://www.ruby-lang.org) 3.x (tested with 3.4) and [Bundler](https://bundler.io)
  + [Jekyll](https://jekyllrb.com) 4.x (installed by Bundler from the Gemfile)
  + [GNU tar w/ bzip2 support](http://www.gnu.org/software/tar/)
  + [the oacdp overlay](http://oacdp/mirroring.html)
  + [git](http://git-scm.com)

## Building

First fetch the oacdp source:

	git clone https://github.com/elliottjohnson/oacdp.git oacdp
	cd oacdp

Install Jekyll and its dependencies (once):

	bundle install

Then use Jekyll to render the site from src/ into out/:

	bundle exec jekyll build

Then extract the overlay to install the content (the scanned documents
are not kept in git):

	tar -xvvjpf /the/path/to/your/oacdp-overlay.tar.bz2

The overlay folders inside out/ (5054part/, pdfs/, zips/, ...) are listed
under `keep_files` in _config.yml, so rebuilding does not delete them.

## Viewing

Use a web browser to open the "oacdp/out/index.html" file.  I've used only 
relative url's within the site to keep things locally viewable.

Or run a local preview server, which rebuilds when files in src/ change:

	bundle exec jekyll serve --host 0.0.0.0 --port 4000

and browse to http://localhost:4000/index.html.  In a GitHub Codespace,
open the PORTS tab and click the globe icon next to port 4000.

## Scan viewer

The Type 2 Parts Manual (1958-1967), Main Group 6 (road wheels, brakes)
has a page-by-page viewer at `5867g6-305.html` ... `5867g6-335.html`,
linked from the Main Group 6 quick index on `5867part.html`.

  + `src/_data/parts5867_g6.yml` holds each scan's page number, type and
    description, copied from the "Main Group 6" full index table in
    `src/5867part.html`.
  + `src/_scans5867g6/` has one small stub file per scan; the
    `src/_layouts/viewer.html` layout builds each page from the data file.
  + `src/viewer/` holds the viewer's own CSS and a small script (zoom,
    pan, arrow keys). Everything works without the script.

After changing the table or the data file, check that they still agree:

	ruby scripts/check-5867-g6.rb

The viewer shows scans from `out/5867part/` (from the overlay). Without
the overlay, each page shows a message with a link to the scan on
oacdp.org instead of a broken image.

## Parts data

Verified parts lists, one data file per illustration, in
`src/_data/parts/<edition>/`. The first is Illustration 32 (Hydraulic
brakes) of the VW Transporter Parts List 1960-1967, August 1963 edition:
`src/_data/parts/vw-tpl-1963-08/ill32.yml`. It is not shown on the site yet.

Each list row records its edition, printed and PDF page, the part number as
printed (any leading mark such as `*` kept in its own `marker` field), the
description, quantity and applicability text verbatim, the parsed chassis
range, option codes as printed, three independent readings (the PDF's text
layer, tesseract, and an AI reading), and its review status. A person
confirms or corrects every row; nothing is "verified" until they do.

The data file holds text and numbers only. The page images it was read from
stay outside the repository (never commit scans, crops or PDFs).

Check a data file (add `--final` once everything has been reviewed):

	ruby scripts/check-parts.rb src/_data/parts/vw-tpl-1963-08/ill32.yml
	ruby scripts/parts/test_parts.rb

Review it in the local, dev-only review tool (never published; it lives in
`dev/`, outside `src/`). The images folder must be outside the repository:

	bundle exec ruby dev/review/server.rb \
	  --data src/_data/parts/vw-tpl-1963-08/ill32.yml \
	  --images /path/outside/repo/with/page-NNN.png \
	  --reviewer yourname

then open http://127.0.0.1:4001/ (in a Codespace: the PORTS tab, port 4001).

To re-run the extraction, first make the page images and the two machine
readings in a folder outside the repository, then run `extract.rb`. Rows
that were already reviewed are kept as they are:

	pdfimages -png -f 341 -l 349 ORIGINAL.pdf WORK/p     # then rename to page-341.png ...
	pdftotext -tsv -f N -l N ORIGINAL.pdf WORK/raw/pdftext-N.tsv
	tesseract WORK/page-N.png WORK/raw/tess-N --dpi 300 --psm 4 tsv
	ruby scripts/parts/extract.rb --pdf ORIGINAL.pdf --work WORK \
	  --reading READING.yml --out src/_data/parts/vw-tpl-1963-08/ill32.yml

### Whole-book machine catalog (smoke test)

The whole August 1963 book can be machine-read into the same row format
using the machine readings (no AI or person reading). The YAML files, the
source of truth, are committed in `data/parts/vw-tpl-1963-08/catalog/`
(outside `src/`, so the site build doesn't load them), with the page map
(`src/_data/parts/vw-tpl-1963-08/page-map.yml`) and the person's decisions
(`page-decisions.yml`). The SQLite file and the JSON search index are
rebuilt from them and are not committed; nor are page images or raw OCR. Every row is `unverified` and labelled `readings agree` or
`needs checking`.

	scripts/parts/run-readings.sh ORIGINAL.pdf WORK              # images + both readings, restartable (~25 min)
	ruby scripts/parts/footer-readings.rb --pdf ORIGINAL.pdf --work WORK   # cleaned footer strips, 3rd reading (~13 min)
	ruby scripts/parts/pagemap.rb --pdf ORIGINAL.pdf --work WORK --out src/_data/parts/vw-tpl-1963-08/page-map.yml \
	  --decisions src/_data/parts/vw-tpl-1963-08/page-decisions.yml
	ruby scripts/parts/cross-edition.rb --scans out/5867part --work WORK --out WORK/parts-5867.txt
	ruby scripts/parts/catalog.rb --pdf ORIGINAL.pdf --work WORK \
	  --page-map src/_data/parts/vw-tpl-1963-08/page-map.yml --out data/parts/vw-tpl-1963-08/catalog --cross-edition WORK/parts-5867.txt
	ruby scripts/check-parts.rb --catalog data/parts/vw-tpl-1963-08/catalog
	ruby scripts/parts/build-db.rb --yaml data/parts/vw-tpl-1963-08/catalog --page-map src/_data/parts/vw-tpl-1963-08/page-map.yml --out OUT
	ruby scripts/parts/smoke-report.rb --yaml data/parts/vw-tpl-1963-08/catalog --page-map src/_data/parts/vw-tpl-1963-08/page-map.yml \
	  --work WORK --report OUT/report.md --spot-yml src/_data/parts/vw-tpl-1963-08/spot-check-50.yml \
	  --spot-md OUT/spot-check.md [--sample AI-READING.yml ...]

`catalog.db` is built with the `sqlite3` command, so no gem is needed.

### Parts preview (local only)

A local preview of a parts section in the new OACDP design: a table of
contents, one page per illustration (scan with zoom/rotate, part card,
parts table, chassis-number fit check) and a part-number search. It is
built from the whole-book machine data and the scans in the notes folder,
into a folder outside the repository, and is never published:

	scripts/parts/preview.sh          # build and serve http://127.0.0.1:4002/parts/
	scripts/parts/preview.sh --build  # build only
	bundle exec ruby scripts/parts/test_preview.rb

Each illustration page has "Report a problem" buttons (for a part and for
the page). Reports are saved by the preview server
(`scripts/parts/preview-server.rb`, 127.0.0.1 only) to
`data/parts/vw-tpl-1963-08/qa-reports.jsonl`, one line each, so they can be
committed and worked through. Set your name with `PP_REVIEWER=yourname`.

The plugin (`src/_plugins/parts_preview.rb`) does nothing unless
`_config.preview.yml` is layered on, so the normal site build is unchanged.

## Deploying

If you wish to deploy from source you can execute the publish.sh
script found in the scripts/ directory in the root of your checkout.
Make sure you supply a writeable, webviewable directory on your
local machine.

	scripts/publish.sh /path/to/a/writable/webdir/oacdp      

## Developing

I highly recommend setting up a github account, but it's not a requirement. 
[Email](http://oacdp.org/contact.html) if you are interested in commiting.

## License

The work being done is under the GNUv3.0 license.  See the file LICENSE in
the base of this repository for more information.

