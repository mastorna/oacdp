#!/usr/bin/env ruby
# Machine-only rows for every parts-list page of the book, from the two
# machine readings matched to each other (no AI or person reading).
# Writes one YAML file per illustration in the same layout as ill32.yml.
# Every row is "unverified" and carries a confidence label:
#   "readings agree"  both readings found it, normalised part numbers equal and
#                     well-shaped, marker/key/quantity/applicability digits
#                     equal wherever both readings captured them
#   "needs checking"  anything else (confidence_reasons says why)
#
#   ruby scripts/parts/catalog.rb --pdf ORIGINAL.pdf --work WORK \
#        --page-map page-map.yml --out OUTDIR [--cross-edition parts-5867.txt]
#
# OUTDIR is data/parts/vw-tpl-1963-08/catalog/ (committed, text only; never
# under src/). WORK (page images, raw readings) must be outside the repository. Ruby standard library only.

require "optparse"
require "digest"
require "fileutils"
require_relative "lib/parts"
require_relative "lib/readings"
require_relative "lib/book"
require_relative "lib/rows"

opts = {}
OptionParser.new do |o|
  o.on("--pdf PATH") { |v| opts[:pdf] = v }
  o.on("--work DIR") { |v| opts[:work] = v }
  o.on("--page-map PATH") { |v| opts[:map] = v }
  o.on("--out DIR") { |v| opts[:out] = v }
  o.on("--cross-edition PATH") { |v| opts[:cross] = v }
end.parse!
%i[pdf work map out].each { |k| abort "missing --#{k}" unless opts[k] }
REPO = File.expand_path("../..", __dir__)
abort "--work must be outside the repository" if File.expand_path(opts[:work]).start_with?(REPO + "/")
# the YAML (text only) may go in the repository's data/ folder, never in src/ (Jekyll would load it)
abort "--out must not be inside src/" if File.expand_path(opts[:out]).start_with?(File.join(REPO, "src") + "/")

pm = Parts.load(opts[:map])
sha = Digest::SHA256.file(opts[:pdf]).hexdigest
cross = opts[:cross] && File.readlines(opts[:cross], chomp: true).reject(&:empty?)
cross_full = cross&.to_h { |x| [x, true] }
cross_base = cross&.to_h { |x| [x[0, 9], true] }

dup_printed = pm["pages"].map { |p| p["printed_page"] }.compact.tally.select { |_k, v| v > 1 }.keys
list_pages = pm["pages"].select { |p| p["page_type"] == "parts_list" && !p["duplicate_of"] }
                        .map { |p| dup_printed.include?(p["printed_page"]) ? p.merge("_id_page" => "p#{p['pdf_page']}") : p }
by_ill = list_pages.group_by { |p| p["illustration"] ? Book.slug(p["illustration"]) : "ill-unknown-#{(p['main_group'] || 'x').downcase}" }

FileUtils.mkdir_p(opts[:out])
Dir[File.join(opts[:out], "*.yml")].each { |f| File.delete(f) }   # generated output: rebuilt every run
totals = Hash.new(0)
by_ill.each do |slug, pages|
  ill = pm["illustrations"].find { |i| i["slug"] == slug }
  rows = []
  pages.each do |p|
    n = format("%03d", p["pdf_page"])
    w, h = Readings.png_size(File.join(opts[:work], "page-#{n}.png"))
    tess = Readings.tsv_lines(File.join(opts[:work], "raw", "tess-#{n}.tsv"))
    pdf, geo = Book.pdf_lines(File.join(opts[:work], "raw", "pdftext-#{n}.tsv"), w, h)
    pdf = [] unless geo   # rotated fold-out: text-layer positions unusable
    page_rows = Rows.for_page(p, tess, pdf, w, h, slug)
    page_rows.each do |r|
      r["main_group"] = p["main_group"]
      r["illustration"] = p["illustration"]
      r["cross_edition"] = if p["main_group"] != "6" || cross.nil? then "not_available"
                           elsif cross_full[r["part_no_norm"]] then "found_in_1958_67"
                           elsif cross_base[r["part_no_norm"].to_s[0, 9]] then "base_number_found_in_1958_67"
                           else "not_found_in_1958_67"
                           end
    end
    rows.concat(page_rows)
  end
  positions = Rows.positions!(rows, slug)
  data = {
    "edition" => { "id" => Book::EDITION, "title" => "VW Transporter Parts List 1960-1967 (August 1963)",
                   "source_file" => File.basename(opts[:pdf]), "source_sha256" => sha },
    "illustration" => {
      "number" => ill && ill["number"], "slug" => slug, "title" => ill && ill["title"],
      "main_group" => ill ? ill["main_group"] : pages.first["main_group"],
      "drawing" => ill && ill["drawing_pdf_pages"].any? ? { "pdf_pages" => ill["drawing_pdf_pages"] } : nil,
      "lists" => { "pdf_pages" => pages.map { |p| p["pdf_page"] } }
    },
    "conventions" => {
      "made_by" => "scripts/parts/catalog.rb: machine readings only (pdf_text = the PDF's built-in OCR text layer; tesseract = tesseract 5 at native ~300 dpi, psm 4). No AI or person reading.",
      "part_no" => "the chosen reading's part number with the book's usual spacing (\"211 609 237 C\") when its shape is recognised, otherwise as read; each reading's raw text is in readings",
      "confidence" => "\"readings agree\" or \"needs checking\"; computed only from the two machine readings and the part-number shape rules",
      "cross_edition" => "Main Group 6 only: whether the part number also appears in tesseract's reading of the site's 1958-67 scans. Not found does not mean wrong.",
      "position" => "suggested: a keyed row starts a position; following rows without a key join it",
      "status" => "unverified until a person confirms or corrects the row"
    },
    "pages" => pages.map { |p| p.slice("pdf_page", "printed_page", "revision_stamp", "stamp_readings").merge("stamp_status" => "unverified") },
    "callouts" => [],
    "positions" => positions,
    "rows" => rows
  }
  Parts.dump(File.join(opts[:out], "#{slug}.yml"), data)
  totals[:files] += 1
  totals[:rows] += rows.length
  totals[:agree] += rows.count { |r| r["confidence"] == "readings agree" }
end
puts "printed page numbers given to more than one PDF page (row ids use the PDF page there): #{dup_printed.length}"
puts "wrote #{totals[:files]} files to #{opts[:out]}: #{totals[:rows]} rows, #{totals[:agree]} \"readings agree\" (#{(100.0 * totals[:agree] / [totals[:rows], 1].max).round(1)}%)"
