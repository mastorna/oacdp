#!/usr/bin/env ruby
# Check a parts data file (e.g. src/_data/parts/vw-tpl-1963-08/ill32.yml).
#
#   ruby scripts/check-parts.rb FILE            # structure checks; exits 1 on any error
#   ruby scripts/check-parts.rb --final FILE    # also requires every row, callout,
#                                               # page stamp and position to be reviewed
#
# Ruby standard library only.

require_relative "parts/lib/parts"

# ---- whole-book machine catalog (one YAML per illustration, made by catalog.rb) ----
#   ruby scripts/check-parts.rb --catalog DIR
# Keys and callouts are not required here (not extracted yet). Every row must
# have its edition, PDF page, row order, status and confidence label.
if ARGV.delete("--catalog")
  dir = ARGV.first or abort "usage: ruby scripts/check-parts.rb --catalog DIR"
  files = Dir[File.join(dir, "*.yml")].sort
  abort "no YAML files in #{dir}" if files.empty?
  errors = []
  warns = Hash.new(0)
  ids = Hash.new(0)
  n_rows = 0
  labels = ["readings agree", "needs checking"]
  files.each do |f|
    d = Parts.load(f)
    name = File.basename(f)
    ed = d.dig("edition", "id")
    errors << "#{name}: edition.id missing" unless ed
    errors << "#{name}: edition.source_sha256 missing" unless d.dig("edition", "source_sha256").to_s.match?(/\A\h{64}\z/)
    pos_ids = (d["positions"] || []).map { |x| x["id"] }
    rows = d["rows"] || []
    n_rows += rows.length
    rows.each do |r|
      id = r["id"]
      ids[id] += 1
      errors << "#{name} #{id}: edition #{r['edition'].inspect} differs from #{ed.inspect}" unless r["edition"] == ed && ed
      errors << "#{name} #{id}: pdf_page missing" unless r["pdf_page"].is_a?(Integer)
      errors << "#{name} #{id}: row_order missing" unless r["row_order"].is_a?(Integer)
      errors << "#{name} #{id}: status #{r['status'].inspect} invalid" unless Parts::STATUSES.include?(r["status"])
      errors << "#{name} #{id}: confidence #{r['confidence'].inspect} invalid" unless labels.include?(r["confidence"])
      if (r["confidence"] == "readings agree") != Array(r["confidence_reasons"]).empty?
        errors << "#{name} #{id}: confidence and confidence_reasons disagree"
      end
      want = r["part_no"].to_s.gsub(/\s+/, "").upcase
      errors << "#{name} #{id}: part_no_norm #{r['part_no_norm'].inspect} should be #{want.inspect}" unless r["part_no_norm"] == want
      errors << "#{name} #{id}: position #{r['position'].inspect} not in positions" if r["position"] && !pos_ids.include?(r["position"])
      derived = Parts.derive!(Parts.deep_dup(r))
      %w[chassis_from chassis_to chassis_ranges option_codes].each do |k|
        errors << "#{name} #{id}: #{k} doesn't match the applicability text" unless derived[k] == r[k]
      end
      warns["printed page not found (row has PDF page only)"] += 1 if r["printed_page"].nil?
      warns["part number shape not recognised"] += 1 unless Parts.shape_ok?(r["part_no"])
      warns["no key"] += 1 if r["key"].nil?
    end
    rows.group_by { |r| r["pdf_page"] }.each do |pg, rs|
      orders = rs.map { |r| r["row_order"] }
      errors << "#{name} PDF #{pg}: row_order is not 1..#{rs.length}" unless orders.sort == (1..rs.length).to_a
    end
  end
  dup = ids.select { |_, n| n > 1 }
  errors << "duplicate row ids across files: #{dup.keys.first(10).inspect}#{dup.length > 10 ? ' …' : ''}" if dup.any?
  puts "#{dir}: #{files.length} files, #{n_rows} rows"
  warns.each { |k, v| puts "warning: #{v} rows: #{k}" }
  if errors.empty?
    puts "OK: every row has edition, PDF page, row order, status and confidence; derived fields match."
    exit 0
  end
  errors.first(50).each { |e| warn "error: #{e}" }
  warn "#{errors.length} error(s)."
  exit 1
end

final = ARGV.delete("--final")
path = ARGV.first or abort "usage: ruby scripts/check-parts.rb [--final] FILE"
data = Parts.load(path)

errors = []
warnings = []
err = ->(m) { errors << m }
warn_ = ->(m) { warnings << m }

rows = data["rows"] || []
callouts = data["callouts"] || []
pages = data["pages"] || []
positions = data["positions"] || []
ill = data["illustration"] || {}
edition = data.dig("edition", "id")

err.call("edition.id is missing") unless edition
err.call("edition.source_sha256 is missing") unless data.dig("edition", "source_sha256").to_s.match?(/\A\h{64}\z/)

# printed page <-> PDF page map, from the pages section
page_map = pages.to_h { |p| [p["printed_page"], p["pdf_page"]] }
first, last = ill.dig("lists", "pdf_pages") || [nil, nil]
drawing_pdf = ill.dig("drawing", "pdf_page")

# ---- 0. pages (addition B) ------------------------------------------------------
expected_pages = ([drawing_pdf] + (first..last).to_a).compact rescue []
missing_pages = expected_pages - pages.map { |p| p["pdf_page"] }
err.call("pages: missing PDF pages #{missing_pages.inspect}") if missing_pages.any?
pages.each do |p|
  where = "page #{p['printed_page']} (PDF #{p['pdf_page']})"
  err.call("#{where}: revision_stamp must be text or null") unless p["revision_stamp"].nil? || p["revision_stamp"].is_a?(String)
  err.call("#{where}: stamp_status #{p['stamp_status'].inspect} is not one of #{Parts::STATUSES}") unless Parts::STATUSES.include?(p["stamp_status"])
  err.call("#{where}: stamp not reviewed") if final && p["stamp_status"] == "unverified"
  if %w[verified corrected].include?(p["stamp_status"]) && (p["reviewed_by"].to_s.empty? || p["reviewed_at"].to_s.empty?)
    err.call("#{where}: reviewed stamp has no reviewed_by / reviewed_at")
  end
  if p["revision_stamp"].to_s.include?("[?]") && final
    err.call("#{where}: stamp still contains an unreadable mark [?]")
  end
end

# ---- 1. keys --------------------------------------------------------------------
keyed = rows.reject { |r| r["key"].nil? }
by_key = keyed.group_by { |r| r["key"] }
(1..33).each do |k|
  n = (by_key[k] || []).length
  err.call("key #{k}: #{n} keyed rows (expected exactly 1)") unless n == 1
end
(by_key.keys - (1..33).to_a).each { |k| err.call("key #{k.inspect}: outside 1-33 (rows #{by_key[k].map { |r| r['id'] }.join(', ')})") }

# ---- 2. callouts ------------------------------------------------------------------
labels = callouts.map { |c| c["label"] }
expected_labels = (1..33).map(&:to_s) + ["17"]
err.call("callouts: #{callouts.length} labels (expected 34)") unless callouts.length == 34
err.call("callouts: labels #{labels.tally.sort.to_h} do not match 1-33 with 17 twice") unless labels.sort == expected_labels.sort
callouts.each do |c|
  err.call("callout #{c['id']}: key #{c['key'].inspect} has no keyed row") unless by_key[c["key"]]&.length == 1
  err.call("callout #{c['id']}: page_px missing") unless c["page_px"].is_a?(Array) && c["page_px"].length == 2
  err.call("callout #{c['id']}: status #{c['status'].inspect} invalid") unless Parts::STATUSES.include?(c["status"])
  err.call("callout #{c['id']}: not reviewed") if final && c["status"] == "unverified"
end
(by_key.keys - callouts.map { |c| c["key"] }).each { |k| err.call("key #{k}: keyed row has no callout on the drawing") }

# ---- 3. part numbers and markers (addition C) ------------------------------------
rows.each do |r|
  id = r["id"]
  if r["shape_exception"].to_s.strip.empty?
    err.call("#{id}: part_no #{r['part_no'].inspect} does not match an expected shape") unless Parts.shape_ok?(r["part_no"])
  end
  err.call("#{id}: part_no starts with a marker; put it in the marker field") if r["part_no"].to_s =~ /\A[^0-9A-Za-z]/
  unless r["marker"].nil? || Parts::MARKERS.include?(r["marker"])
    err.call("#{id}: marker #{r['marker'].inspect} is not one of #{Parts::MARKERS.inspect}")
  end
  want = r["part_no"].to_s.gsub(/\s+/, "").upcase
  err.call("#{id}: part_no_norm #{r['part_no_norm'].inspect} should be #{want.inspect}") unless r["part_no_norm"] == want
end

# ---- 4. chassis ranges -------------------------------------------------------------
check_range = lambda do |where, text, rec|
  from, to = Parts.parse_chassis(text)
  { "chassis_from" => from, "chassis_to" => to }.each do |field, parsed|
    stored = rec[field]
    if parsed.nil? != stored.nil? || (parsed && stored && parsed["seq"] != stored["seq"])
      err.call("#{where}: #{field} #{stored.inspect} doesn't match the applicability text (parses as #{parsed.inspect})")
    end
    warn_.call("#{where}: #{field} #{stored['printed'].inspect} is outside the sequence rule (#{stored['format']}); seq left null") if stored && stored["seq"].nil?
  end
  f, t = rec.dig("chassis_from", "seq"), rec.dig("chassis_to", "seq")
  err.call("#{where}: chassis from #{f} is after to #{t}") if f && t && f > t
end
rows.each do |r|
  if r["chassis_ranges"]
    # one sub-range per printed line (each with its own quantity)
    err.call("#{r['id']}: chassis_ranges given but row-level chassis_from/to also set") if r["chassis_from"] || r["chassis_to"]
    err.call("#{r['id']}: #{r['chassis_ranges'].length} sub-ranges but quantity #{r['quantity'].inspect}") unless Array(r["quantity"]).length == r["chassis_ranges"].length
    r["chassis_ranges"].each_with_index { |cr, i| check_range.call("#{r['id']} line #{i + 1}", cr["text"], cr) }
  else
    check_range.call(r["id"], r["applicability"], r)
  end
end
# sequence contradictions within a position: consecutive ranges that overlap or go backwards (printed data; warning)
rows.group_by { |r| r["position"] }.each do |pos, rs|
  next if pos.nil?
  # rows whose ranges have a sequence value (rows outside the rule are reported above)
  ranged = rs.select { |r| (r["chassis_from"] || r["chassis_to"]) && [r["chassis_from"], r["chassis_to"]].compact.all? { |v| v["seq"] } }
  ranged.combination(2).each do |a, b|
    af, at = a.dig("chassis_from", "seq") || 0, a.dig("chassis_to", "seq") || Float::INFINITY
    bf, bt = b.dig("chassis_from", "seq") || 0, b.dig("chassis_to", "seq") || Float::INFINITY
    next unless af <= bt && bf <= at                       # overlapping ranges
    next if a["applicability"] == b["applicability"]       # same range printed twice (e.g. left/right) is fine
    next if a["description"] != b["description"] && a["quantity"] != b["quantity"] # different variants
    warn_.call("position #{pos}: #{a['part_no']} (#{a['applicability'].to_s.tr("\n", ' ')}) overlaps #{b['part_no']} (#{b['applicability'].to_s.tr("\n", ' ')})")
  end
end

# ---- 5. source pages -----------------------------------------------------------------
rows.each do |r|
  id = r["id"]
  %w[edition printed_page pdf_page row_order].each { |f| err.call("#{id}: #{f} missing") if r[f].nil? }
  err.call("#{id}: edition #{r['edition'].inspect} differs from #{edition.inspect}") unless r["edition"] == edition
  err.call("#{id}: pdf_page #{r['pdf_page']} outside #{first}-#{last}") unless first && (first..last).cover?(r["pdf_page"].to_i)
  err.call("#{id}: printed page #{r['printed_page']} belongs to PDF #{page_map[r['printed_page']]}, not #{r['pdf_page']}") unless page_map[r["printed_page"]] == r["pdf_page"]
end
rows.group_by { |r| r["pdf_page"] }.each do |pg, rs|
  orders = rs.map { |r| r["row_order"] }
  err.call("PDF #{pg}: row_order #{orders.inspect} is not 1..#{rs.length}") unless orders.sort == (1..rs.length).to_a
end
dup = rows.map { |r| r["id"] }.tally.select { |_, n| n > 1 }
err.call("duplicate row ids: #{dup.keys.inspect}") if dup.any?

# ---- 6. status consistency --------------------------------------------------------------
(rows + callouts).each do |r|
  id = r["id"]
  st = r["status"]
  err.call("#{id}: status #{st.inspect} is not one of #{Parts::STATUSES}") unless Parts::STATUSES.include?(st)
  case st
  when "verified", "corrected"
    err.call("#{id}: #{st} but no reviewed_by / reviewed_at") if r["reviewed_by"].to_s.empty? || r["reviewed_at"].to_s.empty?
    err.call("#{id}: corrected but no corrections recorded") if st == "corrected" && Array(r["corrections"]).empty?
  when "unverified"
    err.call("#{id}: unverified but has reviewer or corrections") if r["reviewed_by"] || Array(r["corrections"]).any?
  end
  err.call("#{id}: not reviewed") if final && st == "unverified" && rows.include?(r)
end

# ---- 7. positions (addition A) ---------------------------------------------------------
pos_ids = positions.map { |p| p["id"] }
rows.each do |r|
  if r["position"].nil?
    (r["key"] ? err : warn_).call("#{r['id']}: #{r['key'] ? "keyed row (key #{r['key']})" : 'row'} has no position")
  elsif !pos_ids.include?(r["position"])
    err.call("#{r['id']}: position #{r['position'].inspect} is not in the positions list")
  end
  err.call("#{r['id']}: position_status #{r['position_status'].inspect} invalid") unless %w[suggested confirmed changed].include?(r["position_status"])
  err.call("#{r['id']}: position still a suggestion") if final && r["position_status"] == "suggested"
end
positions.each do |p|
  members = rows.select { |r| r["position"] == p["id"] }
  if members.empty?
    warn_.call("position #{p['id']}: no rows")
  elsif members.none? { |r| r["key"] }
    warn_.call("position #{p['id']} (#{p['label']}): no keyed row")
  end
  if p["key"] && members.none? { |r| r["key"] == p["key"] }
    err.call("position #{p['id']}: says key #{p['key']} but no member row has that key")
  end
end

# ---- 8. the review tool must never be published ------------------------------------------
out = File.expand_path("../out", __dir__)
if Dir.exist?(out)
  hits = Dir.glob(File.join(out, "**", "*.{html,js,css,json,yml}")).select { |f| File.read(f, mode: "rb").include?("dev/review") }
  err.call("published site mentions the review tool: #{hits.map { |f| f.sub(out + '/', '') }.inspect}") if hits.any?
  err.call("published site contains a dev/ folder") if Dir.exist?(File.join(out, "dev"))
end

reviewed = ->(list, f = "status") { list.count { |x| %w[verified corrected].include?(x[f]) } }
puts "#{path}: #{rows.length} rows (#{reviewed.call(rows)} reviewed), #{callouts.length} callouts (#{reviewed.call(callouts)} reviewed), " \
     "#{pages.length} pages (#{reviewed.call(pages, 'stamp_status')} stamps reviewed), #{positions.length} positions " \
     "(#{rows.count { |r| r['position_status'] != 'suggested' }} row positions reviewed)"
warnings.each { |w| puts "warning: #{w}" }
if errors.empty?
  puts final ? "OK (final): everything is reviewed and consistent." : "OK: structure is consistent."
else
  errors.each { |e| warn "error: #{e}" }
  warn "#{errors.length} error(s)."
  exit 1
end
