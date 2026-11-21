#!/usr/bin/env ruby
# Build the page map of the whole book from the two machine readings:
# one entry per PDF page with its printed page, main group, illustration,
# page type, fold-out flag and revision stamp. Every entry is "unverified".
#
#   ruby scripts/parts/pagemap.rb --pdf ORIGINAL.pdf --work WORK --out page-map.yml
#
# WORK holds page-NNN.png and raw/{pdftext,tess}-NNN.tsv (run-readings.sh).
# Ruby standard library only.

require "optparse"
require "digest"
require_relative "lib/parts"
require_relative "lib/readings"
require_relative "lib/book"

opts = {}
OptionParser.new do |o|
  o.on("--pdf PATH") { |v| opts[:pdf] = v }
  o.on("--work DIR") { |v| opts[:work] = v }
  o.on("--out PATH") { |v| opts[:out] = v }
end.parse!
%i[pdf work out].each { |k| abort "missing --#{k}" unless opts[k] }

pages = Book.read_pages(opts[:work])
map = Book.page_map(pages)

data = {
  "edition" => {
    "id" => Book::EDITION,
    "title" => "VW Transporter Parts List 1960-1967 (August 1963)",
    "source_file" => File.basename(opts[:pdf]),
    "source_sha256" => Digest::SHA256.file(opts[:pdf]).hexdigest
  },
  "conventions" => {
    "made_by" => "scripts/parts/pagemap.rb from the PDF text layer and tesseract; nothing here is person-checked yet",
    "printed_page" => "as printed in the footer, e.g. \"6-5\", \"ST-9\"; filled from neighbouring pages where neither reading found it (evidence says so)",
    "main_group" => "the prefix of the printed page; titles are the book's own list on PDF 12",
    "illustration" => "as printed after \"Illustration\" in the footer, e.g. \"32\" or \"1+A1\"; filled from neighbours where missing",
    "page_type" => "drawing / parts_list / contents / index / other, by rules (see lib/book.rb)",
    "status" => "unverified until a person checks the entry"
  },
  "main_groups" => Book::MAIN_GROUPS.map { |k, v| { "id" => k, "title" => v } },
  "illustrations" => Book.illustrations(map),
  "pages" => map
}
Parts.dump(opts[:out], data)
types = map.map { |p| p["page_type"] }.tally
puts "wrote #{opts[:out]}: #{map.length} pages #{types}"
puts "printed page found by a reading: #{map.count { |p| p['evidence']['printed_page'] =~ /reading/ }}, filled: #{map.count { |p| p['evidence']['printed_page'] == 'filled from neighbours' }}, none: #{map.count { |p| p['printed_page'].nil? }}"
puts "illustrations: #{data['illustrations'].length}"
