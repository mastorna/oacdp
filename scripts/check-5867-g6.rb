#!/usr/bin/env ruby
# Check that the scan viewer's data file for the Type 2 Parts Manual
# (1958-1967), Main Group 6, agrees with the existing index tables in
# src/5867part.html, and that there is exactly one viewer page per scan.
#
#   ruby scripts/check-5867-g6.rb          # check; exits 1 on any mismatch
#   ruby scripts/check-5867-g6.rb --print  # print YAML built from table #f6
#
# Only Ruby's standard library is used. Run from the repository root.

require "yaml"

ROOT      = File.expand_path("..", __dir__)
INDEX     = File.join(ROOT, "src", "5867part.html")
DATA      = File.join(ROOT, "src", "_data", "parts5867_g6.yml")
STUBS     = File.join(ROOT, "src", "_scans5867g6")
SCANS     = File.join(ROOT, "out", "5867part")
TYPES     = %w[diagram list special].freeze

# Return the HTML between <h3 id="ID"> and the next </table>.
def block(html, id)
  start = html.index(%(<h3 id="#{id}">)) or abort "Can't find <h3 id=\"#{id}\"> in #{INDEX}"
  stop  = html.index("</table>", start) or abort "Can't find the end of table #{id}"
  html[start...stop]
end

def clean(text)
  text.gsub(/<[^>]+>/, "").gsub(/\s+/, " ").strip
end

# Rows of the full index table #f6: [{scan, type, description}, ...]
def full_index_rows(html)
  block(html, "f6").scan(%r{<tr>(.*?)</tr>}m).map do |(row)|
    cells = row.scan(%r{<td[^>]*>(.*?)</td>}m).map { |(c)| clean(c) }
    { "scan" => Integer(cells[0]), "type" => cells[1], "description" => cells[2] }
  end
end

# Scan numbers linked from the quick index #q6.
def quick_index_scans(html)
  block(html, "q6").scan(%r{href="5867part/(\d+)\.png"}).map { |(n)| Integer(n, 10) }
end

html = File.read(INDEX, encoding: "UTF-8")
table = full_index_rows(html)

if ARGV.include?("--print")
  puts YAML.dump("pages" => table).sub(/\A---\n/, "")
  exit 0
end

errors   = []
warnings = []

data  = YAML.safe_load_file(DATA)
pages = data.fetch("pages")

# 1. Data file matches table #f6, row by row.
if pages.length != table.length
  errors << "#{DATA}: #{pages.length} pages, but table #f6 has #{table.length} rows"
end
pages.zip(table).each_with_index do |(mine, theirs), i|
  next unless mine && theirs
  %w[scan type description].each do |key|
    a = mine[key].is_a?(String) ? clean(mine[key]) : mine[key]
    next if a == theirs[key]
    errors << "Row #{i + 1} #{key}: data file says #{a.inspect}, table #f6 says #{theirs[key].inspect}"
  end
end

# 2. Quick index #q6 lists the same scans.
quick = quick_index_scans(html)
if quick != pages.map { |p| p["scan"] }
  errors << "Quick index #q6 lists #{quick.inspect}, data file lists #{pages.map { |p| p["scan"] }.inspect}"
end

# 3. Odd, consecutive scan numbers and known page types.
pages.each_cons(2) do |a, b|
  errors << "Scans #{a["scan"]} and #{b["scan"]} are not consecutive odd numbers" unless b["scan"] == a["scan"] + 2
end
pages.each do |p|
  errors << "Scan #{p["scan"]} is not an odd number" unless p["scan"].odd?
  errors << "Scan #{p["scan"]} has unknown type #{p["type"].inspect}" unless TYPES.include?(p["type"])
end

# 4. Exactly one viewer stub per scan.
stubs    = Dir.children(STUBS).grep(/\A\d+\.html\z/).map { |f| Integer(f.sub(".html", ""), 10) }.sort
expected = pages.map { |p| p["scan"] }.sort
(expected - stubs).each { |n| errors << "Missing viewer stub src/_scans5867g6/#{n}.html" }
(stubs - expected).each { |n| errors << "Extra viewer stub src/_scans5867g6/#{n}.html (not in the data file)" }

# 4b. Each stub's title names its scan and description.
pages.each do |p|
  f = File.join(STUBS, "#{p["scan"]}.html")
  next unless File.exist?(f)
  front = YAML.safe_load(File.read(f)[/\A---\n(.*?)\n---\n/m, 1].to_s) || {}
  want  = "#{data["manual"]}, #{data["group_short"]}, scan #{p["scan"]}: #{clean(p["description"])}"
  errors << "src/_scans5867g6/#{p["scan"]}.html title is #{front["title"].inspect}, expected #{want.inspect}" unless front["title"] == want
end

# 5. Scans present in the overlay (warning only: the overlay is optional).
if Dir.exist?(SCANS)
  pages.each do |p|
    f = File.join(SCANS, "#{p["scan"]}.png")
    warnings << "Scan not found (overlay): out/5867part/#{p["scan"]}.png" unless File.exist?(f)
  end
else
  warnings << "out/5867part/ not found; the overlay isn't installed, so scans can't be previewed"
end

warnings.each { |w| warn "warning: #{w}" }
if errors.empty?
  puts "OK: #{pages.length} scans in #{File.basename(DATA)} match tables #f6 and #q6 and the viewer stubs."
else
  errors.each { |e| warn "error: #{e}" }
  exit 1
end
