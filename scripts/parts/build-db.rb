#!/usr/bin/env ruby
# Build outputs from the YAML files (which stay the source of truth):
#   OUT/catalog.sql        plain SQL (CREATE + INSERT)
#   OUT/catalog.db         loaded from catalog.sql with the sqlite3 command
#   OUT/search-index.json  compact rows + table of contents for a future site search
# Both are generated and never edited or committed.
#
#   ruby scripts/parts/build-db.rb --yaml DIR --page-map page-map.yml --out OUTDIR
#
# Ruby standard library only; the database is loaded by the `sqlite3` command
# (already installed). Without it, only catalog.sql and the JSON are written.

require "optparse"
require "json"
require "open3"
require_relative "lib/parts"
require_relative "lib/sql"

opts = {}
OptionParser.new do |o|
  o.on("--yaml DIR") { |v| opts[:yaml] = v }
  o.on("--page-map PATH") { |v| opts[:map] = v }
  o.on("--out DIR") { |v| opts[:out] = v }
end.parse!
%i[yaml map out].each { |k| abort "missing --#{k}" unless opts[k] }
REPO = File.expand_path("../..", __dir__)
abort "--out must be outside the repository" if File.expand_path(opts[:out]).start_with?(REPO + "/")

pm = Parts.load(opts[:map])
files = Dir[File.join(opts[:yaml], "*.yml")].sort
datas = files.map { |f| Parts.load(f) }
rows = datas.flat_map { |d| d["rows"].map { |r| r.merge("_slug" => d["illustration"]["slug"]) } }

sql = [+"PRAGMA foreign_keys = OFF;", "BEGIN;"]
sql << <<~DDL
  DROP TABLE IF EXISTS pages; DROP TABLE IF EXISTS illustrations; DROP TABLE IF EXISTS rows; DROP TABLE IF EXISTS readings;
  CREATE TABLE pages (pdf_page INTEGER PRIMARY KEY, printed_page TEXT, main_group TEXT, main_group_title TEXT,
    illustration TEXT, illustration_title TEXT, page_type TEXT, fold_out INTEGER, revision_stamp TEXT,
    printed_page_evidence TEXT, illustration_evidence TEXT, status TEXT);
  CREATE TABLE illustrations (slug TEXT PRIMARY KEY, number TEXT, title TEXT, main_group TEXT,
    drawing_pdf_pages TEXT, list_pdf_pages TEXT, fold_out_drawing INTEGER, rows INTEGER);
  CREATE TABLE rows (id TEXT PRIMARY KEY, edition TEXT, illustration TEXT, main_group TEXT, printed_page TEXT,
    pdf_page INTEGER, row_order INTEGER, key INTEGER, marker TEXT, part_no TEXT, part_no_norm TEXT,
    description TEXT, quantity TEXT, applicability TEXT, applicability_inline INTEGER,
    chassis_from TEXT, chassis_from_seq INTEGER, chassis_to TEXT, chassis_to_seq INTEGER,
    chassis_ranges TEXT, option_codes TEXT, type_and_model TEXT, position TEXT,
    confidence TEXT, confidence_reasons TEXT, cross_edition TEXT, status TEXT);
  CREATE TABLE readings (row_id TEXT, reader TEXT, key INTEGER, marker TEXT, part_no TEXT, description TEXT,
    quantity TEXT, applicability TEXT, type_and_model TEXT, text TEXT, min_conf INTEGER,
    PRIMARY KEY (row_id, reader));
DDL
pm["pages"].each do |p|
  sql << SQL.insert("pages", p.slice("pdf_page", "printed_page", "main_group", "main_group_title", "illustration",
                                     "illustration_title", "page_type", "fold_out", "revision_stamp", "status")
                               .merge("printed_page_evidence" => p.dig("evidence", "printed_page"),
                                      "illustration_evidence" => p.dig("evidence", "illustration")))
end
datas.each do |d|
  i = d["illustration"]
  sql << SQL.insert("illustrations", "slug" => i["slug"], "number" => i["number"], "title" => i["title"],
                                     "main_group" => i["main_group"], "drawing_pdf_pages" => i.dig("drawing", "pdf_pages"),
                                     "list_pdf_pages" => i.dig("lists", "pdf_pages"),
                                     "fold_out_drawing" => pm["illustrations"].find { |x| x["slug"] == i["slug"] }&.dig("fold_out_drawing"),
                                     "rows" => d["rows"].length)
end
qty = ->(q) { q.is_a?(Array) ? q.join(" / ") : q }
rows.each do |r|
  sql << SQL.insert("rows", r.slice("id", "edition", "main_group", "printed_page", "pdf_page", "row_order", "key", "marker",
                                    "part_no", "part_no_norm", "description", "applicability", "applicability_inline",
                                    "chassis_ranges", "option_codes", "type_and_model", "position", "confidence",
                                    "confidence_reasons", "cross_edition", "status")
                             .merge("illustration" => r["_slug"], "quantity" => qty.call(r["quantity"]),
                                    "chassis_from" => r.dig("chassis_from", "printed"), "chassis_from_seq" => r.dig("chassis_from", "seq"),
                                    "chassis_to" => r.dig("chassis_to", "printed"), "chassis_to_seq" => r.dig("chassis_to", "seq")))
  (r["readings"] || {}).each do |reader, x|
    next unless x
    sql << SQL.insert("readings", "row_id" => r["id"], "reader" => reader, "key" => x["key"].is_a?(Integer) ? x["key"] : x["key"]&.to_s,
                                  "marker" => x["marker"], "part_no" => x["part_no"], "description" => x["description"],
                                  "quantity" => qty.call(x["quantity"]), "applicability" => x["applicability"],
                                  "type_and_model" => x["type_and_model"], "text" => x["text"], "min_conf" => x["min_conf"])
  end
end
sql << <<~IDX
  CREATE INDEX rows_part ON rows (part_no_norm);
  CREATE INDEX rows_page ON rows (pdf_page);
  CREATE INDEX rows_ill ON rows (illustration);
  CREATE INDEX pages_ill ON pages (illustration);
  COMMIT;
IDX

out = opts[:out]
Dir.mkdir(out) unless Dir.exist?(out)
File.write(File.join(out, "catalog.sql"), sql.join("\n") + "\n")
db = File.join(out, "catalog.db")
File.delete(db) if File.exist?(db)
_o, e, s = Open3.capture3("sqlite3", db, stdin_data: File.read(File.join(out, "catalog.sql")))
if s.success?
  n, _e2, _s2 = Open3.capture3("sqlite3", db, "SELECT count(*) FROM rows;")
  puts "wrote #{db}: #{n.strip} rows"
else
  warn "sqlite3 failed (catalog.sql is still written): #{e}"
end

# ---- JSON search index ------------------------------------------------------------
toc = pm["main_groups"].map do |g|
  ills = pm["illustrations"].select { |i| i["main_group"] == g["id"] }
  { "main_group" => g["id"], "title" => g["title"],
    "illustrations" => ills.map { |i| { "number" => i["number"], "slug" => i["slug"], "title" => i["title"],
                                        "drawing_pdf_pages" => i["drawing_pdf_pages"], "list_pdf_pages" => i["list_pdf_pages"] } } }
end
index = {
  "edition" => pm["edition"]["id"], "generated_from" => "YAML files by scripts/parts/build-db.rb; machine readings only, unverified",
  "fields" => { "id" => "row id", "p" => "part number", "n" => "normalised part number", "d" => "description",
                "g" => "main group", "i" => "illustration", "pp" => "printed page", "pdf" => "PDF page",
                "c" => "confidence: a = readings agree, n = needs checking" },
  "toc" => toc,
  "pages" => pm["pages"].map { |p| [p["pdf_page"], p["printed_page"], p["main_group"], p["illustration"], p["page_type"]] },
  "rows" => rows.map do |r|
    { "id" => r["id"], "p" => r["part_no"], "n" => r["part_no_norm"], "d" => r["description"], "g" => r["main_group"],
      "i" => r["illustration"], "pp" => r["printed_page"], "pdf" => r["pdf_page"], "c" => r["confidence"] == "readings agree" ? "a" : "n" }
  end
}
File.write(File.join(out, "search-index.json"), JSON.generate(index))
puts "wrote #{File.join(out, 'search-index.json')}: #{index['rows'].length} rows, #{(File.size(File.join(out, 'search-index.json')) / 1024.0 / 1024).round(1)} MB"
