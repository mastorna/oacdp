#!/usr/bin/env ruby
# Part numbers found by tesseract in the site's 1958-67 Main Group 6 scans,
# one normalised number per line (e.g. "211609237C", "N136341"). Used by
# catalog.rb --cross-edition as independent evidence for Main Group 6 rows.
# The scans are only read; tesseract output goes to WORK (outside the repo).
#
#   ruby scripts/parts/cross-edition.rb --scans out/5867part --work WORK --out parts-5867.txt
#
# Ruby standard library only (calls the installed tesseract).

require "optparse"
require "open3"
require "fileutils"

opts = { first: 305, last: 335 }
OptionParser.new do |o|
  o.on("--scans DIR") { |v| opts[:scans] = v }
  o.on("--work DIR") { |v| opts[:work] = v }
  o.on("--out PATH") { |v| opts[:out] = v }
end.parse!
%i[scans work out].each { |k| abort "missing --#{k}" unless opts[k] }
REPO = File.expand_path("../..", __dir__)
abort "--work must be outside the repository" if File.expand_path(opts[:work]).start_with?(REPO + "/")

raw = File.join(opts[:work], "raw5867")
FileUtils.mkdir_p(raw)
found = []
(opts[:first]..opts[:last]).step(2).each do |n|
  png = File.join(opts[:scans], "#{n}.png")
  next warn("missing #{png}") unless File.file?(png)
  txt = File.join(raw, "#{n}.txt")
  unless File.size?(txt)
    _o, e, s = Open3.capture3("tesseract", png, txt.sub(/\.txt\z/, ""), "--psm", "3")
    abort "tesseract failed on #{png}: #{e}" unless s.success?
  end
  t = File.read(txt)
  t.scan(/(?<!\d)(\d{3})\s?(\d{3})\s?(\d{3})(?!\d)(?:\s?([A-Z]{1,2})\b)?/) { |a, b, c, suf| found << "#{a}#{b}#{c}#{suf}" }
  t.scan(/\bN\s?(\d{2})\s?(\d{3})\s?(\d)\b/) { |a, b, c| found << "N#{a}#{b}#{c}" }
end
found = found.uniq.sort
File.write(opts[:out], found.join("\n") + "\n")
puts "wrote #{opts[:out]}: #{found.length} distinct part numbers"
