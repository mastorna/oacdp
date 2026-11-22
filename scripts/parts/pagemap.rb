#!/usr/bin/env ruby
# Build the page map of the whole book from the two machine readings:
# one entry per PDF page with its printed page, main group, illustration,
# page type, fold-out flag and revision stamp. Every entry is "unverified".
#
#   ruby scripts/parts/pagemap.rb --pdf ORIGINAL.pdf --work WORK --out page-map.yml \
#        [--decisions page-decisions.yml]
#
# --decisions: a person's decisions (page-decisions.yml) applied after the
# machine readings; the machine's own values stay in each page's evidence.
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
  o.on("--decisions PATH") { |v| opts[:decisions] = v }
end.parse!
%i[pdf work out].each { |k| abort "missing --#{k}" unless opts[k] }

pages = Book.read_pages(opts[:work])
map = Book.page_map(pages)

# ---- a person's decisions ------------------------------------------------------
notes = Hash.new { |h, k| h[k] = [] }
decided = []
if opts[:decisions]
  (Parts.load(opts[:decisions])["decisions"] || []).each do |d|
    (d["pages"] || []).each do |dp|
      e = map.find { |p| p["pdf_page"] == dp["pdf_page"] } or abort "decision #{d['id']}: no PDF page #{dp['pdf_page']}"
      machine = e.slice("illustration", "printed_page")
      %w[illustration printed_page].each { |f| e[f] = dp[f] if dp.key?(f) }
      e["footer"] = dp["footer"] if dp["footer"]
      e["decision"] = d["id"]
      e["evidence"]["decision"] = "#{d['id']} (#{d['decided']}): machine had #{machine.map { |k, v| "#{k} #{v.inspect}" }.join(', ')}"
      decided << e["pdf_page"]
    end
    (d["illustration_notes"] || {}).each { |num, text| notes[num.to_s] << text.strip }
    # pages scanned twice: the copy is kept in the map, marked duplicate_of the
    # page that is used, and left out of illustrations, rows and clash counts
    (d["duplicates"] || []).each do |dup|
      a, b = dup["pdf_pages"]
      (a..b).each do |n|
        copy = map.find { |p| p["pdf_page"] == n }
        orig = map.find { |p| p["pdf_page"] == n + dup["same_as_offset"] } or abort "decision #{d['id']}: no PDF page #{n + dup['same_as_offset']}"
        used, dupl = Array(d["prefer_copy"]).include?(n) ? [copy, orig] : [orig, copy]
        dupl["duplicate_of"] = used["pdf_page"]
        dupl["decision"] = d["id"]
        dupl["evidence"]["decision"] = "#{d['id']} (#{d['decided']}): same page as PDF #{used['pdf_page']}, which is used"
        [used, dupl].each { |p| p["same_printed_page_as"] = nil }
        # the same page: what one scan read and the other missed is filled in (PDF 260 <- 190: Illustration 22)
        %w[printed_page main_group main_group_title illustration illustration_title].each do |f|
          next unless used[f].nil? && dupl[f]
          used[f] = dupl[f]
          used["evidence"]["#{f}_from_copy"] = "from PDF #{dupl['pdf_page']}, another scan of the same page"
        end
        decided << dupl["pdf_page"]
      end
    end
  end
  # titles and main group for decided pages: the same as other pages of that illustration
  map.select { |p| p["decision"] }.each do |e|
    other = map.find { |p| p["illustration"] == e["illustration"] && !p["decision"] && p["illustration_title"] }
    e["illustration_title"] = other && other["illustration_title"]
    e["main_group"] ||= e["printed_page"].to_s[/\A(ST|SP|S|L|\d)-/, 1]
    e["main_group_title"] ||= e["main_group"] && Book::MAIN_GROUPS[e["main_group"]]
  end
end

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
    "status" => "unverified until a person checks the entry",
    "decision" => "set where a person decided a value (src/_data/parts/vw-tpl-1963-08/page-decisions.yml); the machine's value is in evidence.decision",
    "duplicate_of" => "this PDF page is another scan of that PDF page, which is the one used (page-decisions.yml); duplicates are left out of illustrations and rows",
    "footer" => "what the page's footer prints, kept where a decision differs from it; illustrations list such pages in footer_says_this_illustration"
  },
  "main_groups" => Book::MAIN_GROUPS.map { |k, v| { "id" => k, "title" => v } },
  "illustrations" => Book.illustrations(map.reject { |p| p["duplicate_of"] }).map do |i|
    footer_pages = map.select { |p| p.dig("footer", "illustration") == i["number"] && p["illustration"] != i["number"] }.map { |p| p["pdf_page"] }
    i.merge("notes" => notes[i["number"]], "footer_says_this_illustration" => footer_pages)
  end,
  "pages" => map
}
Parts.dump(opts[:out], data)
types = map.map { |p| p["page_type"] }.tally
puts "wrote #{opts[:out]}: #{map.length} pages #{types}"
puts "printed page found by a reading: #{map.count { |p| p['evidence']['printed_page'] =~ /reading/ }}, filled: #{map.count { |p| p['evidence']['printed_page'] == 'filled from neighbours' }}, none: #{map.count { |p| p['printed_page'].nil? }}"
puts "illustrations: #{data['illustrations'].length}"
puts "decisions applied to PDF pages: #{decided.join(', ')}" if decided.any?
