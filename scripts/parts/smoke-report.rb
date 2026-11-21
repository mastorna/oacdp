#!/usr/bin/env ruby
# Smoke-test report for the whole-book machine extraction, plus the 50-row
# spot-check selection. With --sample (AI readings in the claude-reading.yml
# format), it also measures each machine reading against them.
#
#   ruby scripts/parts/smoke-report.rb --yaml DIR --page-map page-map.yml --work WORK \
#        --report report.md --spot-yml spot-check-50.yml --spot-md spot-check.md \
#        [--sample claude-sample.yml ...] [--metrics-out m.json] [--before before.json]
#
# --metrics-out writes the headline figures as JSON; --before reads such a
# file from an earlier run and puts a before/after table at the top.
#
# Ruby standard library only.

require "optparse"
require "date"
require "json"
require_relative "lib/parts"
require_relative "lib/readings"
require_relative "lib/rows"
require_relative "lib/book"

opts = { samples: [] }
OptionParser.new do |o|
  o.on("--yaml DIR") { |v| opts[:yaml] = v }
  o.on("--page-map PATH") { |v| opts[:map] = v }
  o.on("--work DIR") { |v| opts[:work] = v }
  o.on("--report PATH") { |v| opts[:report] = v }
  o.on("--spot-yml PATH") { |v| opts[:spot_yml] = v }
  o.on("--spot-md PATH") { |v| opts[:spot_md] = v }
  o.on("--sample PATH") { |v| opts[:samples] << v }
  o.on("--metrics-out PATH") { |v| opts[:metrics_out] = v }
  o.on("--before PATH") { |v| opts[:before] = v }
end.parse!
%i[yaml map work report].each { |k| abort "missing --#{k}" unless opts[k] }

SEED = 1963
pm = Parts.load(opts[:map])
datas = Dir[File.join(opts[:yaml], "*.yml")].sort.map { |f| Parts.load(f) }
rows = datas.flat_map { |d| d["rows"].map { |r| r.merge("_slug" => d["illustration"]["slug"]) } }
agree = ->(r) { r["confidence"] == "readings agree" }
pct = ->(a, b) { b.zero? ? "–" : format("%.1f%%", 100.0 * a / b) }
out = []
M = {}   # headline figures for --metrics-out / --before
groups = Book::MAIN_GROUPS.keys
pages = pm["pages"]

# ---- run facts -------------------------------------------------------------------------
times = File.exist?(File.join(opts[:work], "timings.log")) ? File.readlines(File.join(opts[:work], "timings.log")).filter_map { |l| l[/ (\d+)ms/, 1]&.to_i } : []
out << "# Whole-book extraction smoke test: VW Transporter Parts List 1960-1967 (August 1963)"
out << ""
out << "- **Generated:** #{Date.today} by `scripts/parts/smoke-report.rb` (re-run it to refresh)."
out << "- **Readings:** the PDF's text layer and tesseract 5.3.4 (native 300 dpi, psm 4) on all #{pages.length} PDF pages. No paid service was used."
out << "- **Status of everything here:** machine output, **unverified**. Nothing is on the public site."
out << "- **Tesseract time:** #{times.length} pages, average #{times.empty? ? '–' : (times.sum / times.length / 1000.0).round(1)} s per page per job, 2 jobs in parallel (about #{(times.sum / 2 / 60000.0).round} min in total)."
out << ""
out << "<!-- BEFORE-AFTER -->"
out << "## Summary"
types = pages.map { |p| p["page_type"] }.tally
out << "| | |"
out << "|---|---|"
out << "| PDF pages | #{pages.length} (#{types.sort.map { |k, v| "#{k} #{v}" }.join(', ')}) |"
out << "| Fold-out pages | #{pages.count { |p| p['fold_out'] }} |"
out << "| Illustrations found in footers | #{pm['illustrations'].length} |"
out << "| List rows | #{rows.length} |"
out << "| \"readings agree\" | #{rows.count(&agree)} (#{pct.call(rows.count(&agree), rows.length)}) |"
out << "| \"needs checking\" | #{rows.count { |r| !agree.call(r) }} |"
out << "| Rows whose part number has a recognised shape | #{rows.count { |r| Rows.norm_shape_ok?(r['part_no_norm']) }} (#{pct.call(rows.count { |r| Rows.norm_shape_ok?(r['part_no_norm']) }, rows.length)}) |"
out << ""
M["pages_list"] = types["parts_list"].to_i
M["pages_drawing"] = types["drawing"].to_i
M["rows"] = rows.length
M["agree_pct"] = 100.0 * rows.count(&agree) / [rows.length, 1].max
M["shape_pct"] = 100.0 * rows.count { |r| Rows.norm_shape_ok?(r["part_no_norm"]) } / [rows.length, 1].max

# ---- per main group ---------------------------------------------------------------------
out << "## Per main group"
out << "| Group | Title | PDF pages | List pages | Drawing pages | Rows | % readings agree | % part-number shape OK |"
out << "|---|---|---|---|---|---|---|---|"
(groups + [nil]).each do |g|
  ps = pages.select { |p| p["main_group"] == g }
  rs = rows.select { |r| r["main_group"] == g }
  next if ps.empty? && rs.empty?
  out << "| #{g || '(unknown)'} | #{g ? Book::MAIN_GROUPS[g] : 'printed page not found'} | #{ps.length} | #{ps.count { |p| p['page_type'] == 'parts_list' }} | #{ps.count { |p| p['page_type'] == 'drawing' }} | #{rs.length} | #{pct.call(rs.count(&agree), rs.length)} | #{pct.call(rs.count { |r| Rows.norm_shape_ok?(r['part_no_norm']) }, rs.length)} |"
end
out << ""
out << "Why rows need checking (a row can have several reasons):"
out << ""
rows.flat_map { |r| r["confidence_reasons"] }.tally.sort_by { |_k, v| -v }.each { |k, v| out << "- `#{k}`: #{v}" }
out << ""

# ---- page map quality --------------------------------------------------------------------
ev = pages.map do |p|
  p.dig("evidence", "printed_page").to_s.sub(/ \(.*\z/, "").sub(/PDF [\d and]+/, "PDF N").sub(/\A(conflict|unconfirmed reading)\b.*/, '\\1')
end.tally
out << "## Page map (the future table of contents)"
out << "Saved as `src/_data/parts/vw-tpl-1963-08/page-map.yml`, one entry per PDF page, all unverified."
out << ""
out << "Printed page numbers are large and bold and sit in the dark, speckled bottom margin. Full-page tesseract and the text layer often miss them. So numbers are taken from a reading only when a neighbouring page confirms them, and the rest are filled in or counted from those anchors:"
out << ""
ev.sort_by { |_k, v| -v }.each { |k, v| out << "- #{k.empty? ? '(none)' : k}: #{v}" }
out << ""
clash = pages.map { |p| p["printed_page"] }.compact.tally.select { |_k, v| v > 1 }
M["clashes"] = clash.length
M["printed_none"] = pages.count { |p| %w[parts_list drawing].include?(p["page_type"]) && p["printed_page"].nil? }
out << "- **Clashes:** #{clash.length} printed page numbers are given to more than one PDF page (#{clash.values.sum} pages), so at least one of each pair is wrong. Rows on those pages use the PDF page in their id. Examples: #{clash.keys.first(8).join(', ')}."
out << "- Revision stamps found: #{pages.count { |p| p['revision_stamp'] }} pages (both readings agree on #{pages.count { |p| p.dig('evidence', 'stamp') == 'both readings' }})."
ill_ev = pages.map { |p| p.dig("evidence", "illustration").to_s.split(";").first.to_s.sub(/ \(.*/, "").sub(/".*"/, "") }.reject(&:empty?).tally
out << "- Illustration numbers: " + ill_ev.sort_by { |_k, v| -v }.map { |k, v| "#{k}: #{v}" }.join("; ") + "."
out << ""

# ---- illustrations --------------------------------------------------------------------------
ills = pm["illustrations"]
out << "## Illustrations and drawings"
out << "- Illustrations found: #{ills.length} (by footer number)."
out << "- With at least one drawing page: #{ills.count { |i| i['drawing_pdf_pages'].any? }}; with a fold-out drawing: #{ills.count { |i| i['fold_out_drawing'] }}; with list pages but no drawing page found: #{ills.count { |i| i['drawing_pdf_pages'].empty? && i['list_pdf_pages'].any? }}."
out << "- Drawing pages in the book: #{pages.count { |p| p['page_type'] == 'drawing' }}, of which fold-outs: #{pages.count { |p| p['page_type'] == 'drawing' && p['fold_out'] }}."
out << "- Titles from the book's contents pages: #{ills.count { |i| i['title'] }} of #{ills.length}."
M["illustrations"] = ills.length
M["ill_titles"] = ills.count { |i| i["title"] }
M["ill_with_drawing"] = ills.count { |i| i["drawing_pdf_pages"].any? }
out << ""

# ---- worst pages -----------------------------------------------------------------------------
by_page = rows.group_by { |r| r["pdf_page"] }
med = by_page.values.map(&:length).sort[by_page.length / 2] || 0
worst = pages.select { |p| p["page_type"] == "parts_list" }.map do |p|
  rs = by_page[p["pdf_page"]] || []
  a = rs.count(&agree)
  why = []
  why << "fold-out" if p["fold_out"]
  why << "no rows found" if rs.empty?
  why << "few rows (#{rs.length}, median #{med})" if rs.any? && rs.length < med / 2
  one = rs.count { |r| (r["confidence_reasons"] & %w[only_text_layer only_tesseract]).any? }
  why << "#{one} rows seen by one reading only" if one > rs.length / 3 && rs.any?
  bad = rs.count { |r| r["confidence_reasons"].include?("bad_shape") }
  why << "#{bad} part numbers garbled" if bad > rs.length / 3 && rs.any?
  why << "section #{p['main_group']} layout (#{Book::MAIN_GROUPS[p['main_group']]})" if %w[L ST SP S].include?(p["main_group"])
  why << "no printed page found" unless p["printed_page"]
  [p, rs.length, rs.empty? ? 0.0 : a.to_f / rs.length, why]
end
worst = worst.sort_by { |_p, n, r, _w| [r, n] }.first(15)
out << "## The 15 worst list pages"
out << "| PDF page | Printed | Group | Rows | % agree | Why |"
out << "|---|---|---|---|---|---|"
worst.each { |p, n, r, why| out << "| #{p['pdf_page']} | #{p['printed_page'] || '–'} | #{p['main_group'] || '–'} | #{n} | #{(100 * r).round}% | #{why.join('; ')} |" }
out << ""

# ---- shared parts ---------------------------------------------------------------------------
good = rows.select { |r| Rows.norm_shape_ok?(r["part_no_norm"]) && r["illustration"] }
ill_by_part = good.group_by { |r| r["part_no_norm"] }.transform_values { |rs| rs.map { |r| r["illustration"] }.uniq }
shared = ill_by_part.select { |_k, v| v.length > 1 }
out << "## Shared parts (one part number in more than one illustration)"
out << "Counted only over rows whose part number has a recognised shape (#{good.length} rows, #{ill_by_part.length} distinct numbers). Machine readings can make two different numbers look alike or split one number into two, so these are indications."
out << ""
out << "- Part numbers in more than one illustration: **#{shared.length}** (#{pct.call(shared.length, ill_by_part.length)} of distinct numbers)."
out << "- By number of illustrations: " + shared.values.map(&:length).tally.sort.map { |k, v| "#{k}: #{v}" }.join(", ") + "."
agreed_shared = shared.keys.count { |k| good.any? { |r| r["part_no_norm"] == k && agree.call(r) } }
out << "- Of these, seen at least once as \"readings agree\": #{agreed_shared}."
out << ""
out << "Top 20:"
out << ""
out << "| Part number | Illustrations | Which | Description (first seen) |"
out << "|---|---|---|---|"
shared.sort_by { |k, v| [-v.length, k] }.first(20).each do |k, v|
  first = good.find { |r| r["part_no_norm"] == k }
  out << "| #{first['part_no']} | #{v.length} | #{v.first(8).join(', ')}#{v.length > 8 ? ' …' : ''} | #{first['description'].to_s.gsub('|', '/')[0, 50]} |"
end
out << ""

# ---- cross edition ---------------------------------------------------------------------------
g6 = rows.select { |r| r["main_group"] == "6" }
out << "## Cross-edition evidence (Main Group 6 only)"
if g6.empty? || g6.all? { |r| r["cross_edition"] == "not_available" }
  out << "Not available in this run."
else
  out << "Part numbers from tesseract's reading of the site's 1958-67 Main Group 6 scans, compared with this book's Main Group 6 rows. \"Not found\" does not mean wrong: a part can be new by 1963, or misread in the older scan."
  out << ""
  out << "| | readings agree | needs checking |"
  out << "|---|---|---|"
  %w[found_in_1958_67 base_number_found_in_1958_67 not_found_in_1958_67].each do |k|
    out << "| #{k} | #{g6.count { |r| agree.call(r) && r['cross_edition'] == k }} | #{g6.count { |r| !agree.call(r) && r['cross_edition'] == k }} |"
  end
end
out << ""

# ---- unparsed engine ranges / checking hours ---------------------------------------------------
eng = rows.count { |r| r["applicability"].to_s.match?(/Engine/i) }
out << "## Other counts"
out << "- Rows whose applicability mentions an Engine No. (kept verbatim, not parsed as chassis ranges): #{eng}."
out << "- Rows with a parsed chassis range: #{rows.count { |r| r['chassis_from'] || r['chassis_to'] || r['chassis_ranges'] }}."
out << ""
n_need = rows.count { |r| !agree.call(r) }
n_ok = rows.count(&agree)
lo = (n_need * 30 + n_ok * 10) / 3600.0
hi = (n_need * 40 + n_ok * 10) / 3600.0
out << "## Estimated person-checking time at the current agreement rate"
out << "- \"needs checking\" rows × 30–40 s + \"readings agree\" rows × ~10 s (quick confirm): **#{lo.round}–#{hi.round} hours** for #{rows.length} rows."
out << "- Rows that both machine readings missed are not in this count; the sample comparison below estimates how many there are."
out << ""

# ---- spot check ---------------------------------------------------------------------------------
rng = Random.new(SEED)
pick_a = rows.select(&agree).sample(30, random: rng)
pick_n = rows.reject(&agree).sample(20, random: rng)
spot = (pick_a + pick_n).sort_by { |r| [r["pdf_page"], r["row_order"]] }
if opts[:spot_yml] && File.exist?(opts[:spot_yml]) &&
   Parts.load(opts[:spot_yml])["rows"].any? { |r| %w[verified corrected].include?(r["status"]) }
  warn "#{opts[:spot_yml]} already has reviewed rows: not overwritten"
  opts[:spot_yml] = nil
end
if opts[:spot_yml]
  spot_pages = spot.map { |r| r["pdf_page"] }.uniq
  sdata = {
    "edition" => datas.first["edition"],
    "illustration" => { "number" => "spot-check", "title" => "50 random rows (seed #{SEED}): 30 \"readings agree\", 20 \"needs checking\"",
                        "main_group" => nil, "drawing" => nil, "lists" => { "pdf_pages" => spot_pages } },
    "conventions" => datas.first["conventions"].merge(
      "spot_check" => "Mark a row verified if every field matches the page, corrected if you had to change anything. Accuracy = verified / checked, per confidence label."),
    "pages" => spot_pages.map do |n|
      p = pages.find { |x| x["pdf_page"] == n }
      p.slice("pdf_page", "printed_page", "revision_stamp", "stamp_readings").merge("stamp_status" => "unverified")
    end,
    "callouts" => [], "positions" => spot.map { |r| r["position"] }.compact.uniq.map { |id| { "id" => id, "label" => id, "status" => "suggested" } },
    "rows" => spot.map { |r| r.reject { |k, _| k == "_slug" } }
  }
  Parts.dump(opts[:spot_yml], sdata)
end
if opts[:spot_md]
  md = ["# Spot check: 50 random rows", "",
        "Seed #{SEED}. 30 rows labelled \"readings agree\" and 20 labelled \"needs checking\", in page order.",
        "Check them in the review tool (see the report). Overall accuracy is weighted by how common each label is:",
        "#{pct.call(n_ok, rows.length)} of rows are \"readings agree\". With 30 and 20 rows, each label's estimate is within roughly ±10–15 percentage points.", "",
        "| # | Row | PDF page | Label | Part number | Description | Qty |", "|---|---|---|---|---|---|---|"]
  spot.each_with_index { |r, i| md << "| #{i + 1} | #{r['id']} | #{r['pdf_page']} | #{r['confidence']} | #{r['part_no']} | #{r['description'].to_s.gsub('|', '/')} | #{Array(r['quantity']).join('/')} |" }
  File.write(opts[:spot_md], md.join("\n") + "\n")
end
out << "## Spot check for a person"
out << "50 rows (seed #{SEED}): 30 \"readings agree\" + 20 \"needs checking\". The list is in `spot-check.md` and the data in `src/_data/parts/vw-tpl-1963-08/spot-check-50.yml`. Start the review tool with:"
out << ""
out << "    bundle exec ruby dev/review/server.rb --data src/_data/parts/vw-tpl-1963-08/spot-check-50.yml \\"
out << "      --images /workspaces/oacdp-notes/data-catalog/work --reviewer yourname"
out << ""
out << "Mark a row **verified** if every field matches the page, **corrected** if anything had to change. Accuracy per label = verified ÷ 50-row share; overall = weighted by the label shares above."
out << ""

# ---- sample comparison -------------------------------------------------------------------------
if opts[:samples].any?
  samples = opts[:samples].map { |f| Parts.load(f) }
  s_rows = samples.flat_map { |s| s["rows"] }
  s_pages = samples.flat_map { |s| s["pages"] || [] }
  pages_in = s_rows.map { |r| r["page"] }.uniq.sort
  stats = Hash.new { |h, k| h[k] = Hash.new(0) }
  spurious = 0
  label_ok = Hash.new(0)
  # keys compared as printed, without spaces ("A 66" = "A66"; 66 != "A 66")
  key_s = ->(k) { k.nil? ? nil : k.to_s.gsub(/\s+/, "").upcase }
  pages_in.each do |pg|
    mine = s_rows.select { |r| r["page"] == pg }
    mach = rows.select { |r| r["pdf_page"] == pg }.sort_by { |r| r["row_order"] }
    idx = Parts.align(mine.map { |r| Parts.squash(r["part"].to_s + r["desc"].to_s) },
                      mach.map { |r| Parts.squash(r["part_no"].to_s + r["description"].to_s) })
    spurious += mach.length - idx.compact.uniq.length
    mine.each_with_index do |c, i|
      m = idx[i] && mach[idx[i]]
      cn = Parts.norm_part(c["part"])
      ck = key_s.call(c["key"])
      cq = Rows.qty_s(c["qty"].is_a?(Array) ? c["qty"].map(&:to_s) : c["qty"]&.to_s)
      cd = Readings.digits(c["appl"]).to_s
      { "pdf_text" => m && m.dig("readings", "pdf_text"), "tesseract" => m && m.dig("readings", "tesseract"), "chosen" => m }.each do |name, x|
        st = stats[name]
        st[:rows] += 1
        next unless x
        st[:found] += 1
        pn = Parts.norm_part(x["part_no"]) == cn
        ky = key_s.call(x["key"]) == ck
        qy = Rows.qty_s(x["quantity"]) == cq
        ap = Readings.digits(x["applicability"]).to_s == cd
        st[:part] += 1 if pn
        st[:key] += 1 if ky
        st[:qty] += 1 if qy
        st[:appl] += 1 if ap
        st[:all] += 1 if pn && ky && qy && ap
        next unless name == "chosen"
        lab = agree.call(x) ? :agree : :need
        label_ok[[lab, :n]] += 1
        label_ok[[lab, :part]] += 1 if pn
        label_ok[[lab, :all]] += 1 if pn && ky && qy && ap
      end
    end
  end
  out << "## Accuracy against my (AI) sample reading"
  out << "Sample: #{samples.map { |s| s['sample_note'] || s['reader'] }.compact.uniq.join('; ')}."
  out << "#{s_rows.length} rows on #{pages_in.length} PDF pages (#{pages_in.join(', ')})."
  out << "**My reading is a reference, not person-checked truth**; the spot check gives the person-checked figure."
  out << ""
  out << "| | Rows found | Part number | Key | Quantity | Applicability digits | All four |"
  out << "|---|---|---|---|---|---|---|"
  %w[pdf_text tesseract chosen].each do |n|
    st = stats[n]
    out << "| #{n == 'chosen' ? 'Chosen value (catalog)' : n} | #{pct.call(st[:found], st[:rows])} | #{pct.call(st[:part], st[:rows])} | #{pct.call(st[:key], st[:rows])} | #{pct.call(st[:qty], st[:rows])} | #{pct.call(st[:appl], st[:rows])} | #{pct.call(st[:all], st[:rows])} |"
  end
  out << ""
  ch = stats["chosen"]
  %i[found part key qty appl all].each { |k| M["s_#{k}_pct"] = 100.0 * ch[k] / [ch[:rows], 1].max }
  M["s_missed"] = ch[:rows] - ch[:found]
  M["s_rows"] = ch[:rows]
  M["agree_part_prec"] = 100.0 * label_ok[[:agree, :part]] / [label_ok[[:agree, :n]], 1].max
  M["agree_all_prec"] = 100.0 * label_ok[[:agree, :all]] / [label_ok[[:agree, :n]], 1].max
  M["s_spurious"] = spurious
  out << "- Machine rows on these pages that match none of my rows (extra or split rows): #{spurious}."
  out << "- Rows both machine readings missed: #{stats['chosen'][:rows] - stats['chosen'][:found]} of #{stats['chosen'][:rows]} (#{pct.call(stats['chosen'][:rows] - stats['chosen'][:found], stats['chosen'][:rows])})."
  missed_share = (stats["chosen"][:rows] - stats["chosen"][:found]).to_f / [stats["chosen"][:rows], 1].max
  out << "- At that rate, roughly **#{(rows.length * missed_share / (1 - missed_share)).round} rows** in the whole book are missed by both readings and would have to be added by a person (about #{(rows.length * missed_share / (1 - missed_share) * 60 / 3600.0).round} hours at 1 minute each)."
  out << "- **How far the label can be trusted:** of found rows labelled \"readings agree\", #{pct.call(label_ok[[:agree, :part]], label_ok[[:agree, :n]])} have the same part number as my reading and #{pct.call(label_ok[[:agree, :all]], label_ok[[:agree, :n]])} match on all four fields (#{label_ok[[:agree, :n]]} rows). For \"needs checking\": #{pct.call(label_ok[[:need, :part]], label_ok[[:need, :n]])} and #{pct.call(label_ok[[:need, :all]], label_ok[[:need, :n]])} (#{label_ok[[:need, :n]]} rows)."
  if s_pages.any?
    pmap = pages.to_h { |p| [p["pdf_page"], p] }
    cmp = ->(f, g) { s_pages.count { |sp| sp.key?(f) && pmap[sp["pdf_page"]] && pmap[sp["pdf_page"]][g].to_s == sp[f].to_s } }
    have = ->(f) { s_pages.count { |sp| sp.key?(f) && pmap[sp["pdf_page"]] } }
    %w[printed_page illustration page_type].each { |f| M["pm_#{f}"] = "#{cmp.call(f, f)}/#{have.call(f)}" }
    with_stamp = s_pages.select { |sp| sp["revision_stamp"] && pmap[sp["pdf_page"]] }
    no_stamp = s_pages.select { |sp| sp.key?("revision_stamp") && sp["revision_stamp"].nil? && pmap[sp["pdf_page"]] }
    out << "- **Page map on the sample pages:** printed page #{cmp.call('printed_page', 'printed_page')}/#{have.call('printed_page')}, illustration #{cmp.call('illustration', 'illustration')}/#{have.call('illustration')}, page type #{cmp.call('page_type', 'page_type')}/#{have.call('page_type')}."
    out << "- **Revision stamps:** of #{with_stamp.length} stamps I read, the map has the same text on #{with_stamp.count { |sp| pmap[sp['pdf_page']]['revision_stamp'] == sp['revision_stamp'] }} (those with an unreadable mark \"[?]\" can't match); of #{no_stamp.length} pages without a stamp, the map invents none on #{no_stamp.count { |sp| pmap[sp['pdf_page']]['revision_stamp'].nil? }}."
    out << ""
    out << "Page-map differences on the sample pages (mine → map):"
    out << ""
    s_pages.each do |sp|
      m = pmap[sp["pdf_page"]] or next
      diffs = %w[printed_page illustration page_type].select { |f| sp.key?(f) && m[f].to_s != sp[f].to_s }
      next if diffs.empty?
      out << "- PDF #{sp['pdf_page']}: " + diffs.map { |f| "#{f} #{sp[f].inspect} → #{m[f].inspect}" }.join("; ")
    end
  end
  out << ""
  out << "## Fix round: status of the issues the sample showed"
  out << "The AI sample is unchanged from the first run, so the before/after table at the top compares like with like."
  out << ""
  out << "1. **Printed pages with a letter (\"1-50a\", \"S-22a\")**: read when a footer shows them. Most footers can't be read at all (dark, speckled margins), so inserted pages are also found from **key numbers that rewind** (PDF 64 keys to 28 → PDF 65–66 keys 35–42 → PDF 67 keys from 29). Page counting never runs through an inserted page or a fold-out, and when one number lands on two PDF pages, the filled or counted one is dropped. Clashes: see the table. More pages now have no printed page, by design: a blank is better than a wrong number."
  out << "2. **Out-of-order inserted pages**: an illustration is never filled across a key boundary, an inserted page or an SP-set page. PDF 65–66 now have no illustration instead of the wrong \"3\"."
  out << "3. **Full illustration labels** (\"22a\", \"39a\", \"33+A33\", \"38+A38+B38+C38\") are kept whole. A shortened reading is completed from a neighbouring page that shows the longer label. A loose letter after the number only counts when a page number follows it (\"39 a 8-50\"), not speckle (\"32 a . ;\")."
  out << "4. **Keys with a drawing letter** are kept as printed (\"A 66\", \"A 18/36\") with `key_prefix`. The letter is kept only when the page's illustration has that drawing (\"1+A1\" has A); otherwise it is speckle read as a letter. A date in the key column (\"8/64\") is not a key. Remaining key misses are mostly OCR: the letter or the key isn't read at all (PDF 33 \"A 66\" is read as \"66\")."
  out << "5. **Titles from the book's contents pages**: contents pages are found by their \"NN Title … Illustration\" lines, and the title is attached to the illustration. Sub-groups that share an illustration are joined with \"; \". Some groups' contents pages are not read well enough yet. **The book contradicts itself once:** its Engine contents page (PDF 16) lists \"07 Pistons … 2\" and \"27 Fuel pump, Fuel lines … 6\", but the inserted Pistons pages (PDF 65–66, \"1-50a\", \"1-50b\") print \"Illustration 6\". Both were checked on the page. This is for a person to decide."
  out << "6. **Sideways fold-out drawings**: on fold-out pages the text layer is rotated against the image, so only tesseract decides whether the page is a list. PDF 721 is now a drawing."
  out << "7. **SP-set pages and colour/date lines** are kept verbatim and labelled \"needs checking\" with `sp_set_layout` or `colour_date_lines`. A colour/date line (\"8/63 – 7/64 395 ice blue – 81\", \"001 blue\") no longer starts a row of its own: it stays with the row above. That removed about 300 false rows."
  out << ""
  out << "Sample caveat: for PDF 721 (a sideways fold-out drawing) I looked only at the top half, so \"no printed page\" in my sample may be wrong; a fold-out counts as one numbered page (counting through PDF 19, 21 and 42 gives PDF 33 = 1-19, as printed)."
  out << ""
  out << "Not in this round: 3-digit keys (\"113\" on PDF 463) are still read as the start of the part number."
  out << ""
else
  out << "## Accuracy against my (AI) sample reading"
  out << "Not done yet: this is the machine-only first version of the report."
  out << ""
end

File.write(opts[:metrics_out], JSON.pretty_generate(M) + "\n") if opts[:metrics_out]
table = []
if opts[:before]
  b = JSON.parse(File.read(opts[:before]))
  fmt = ->(v) { v.is_a?(Float) ? format("%.1f", v) : v.to_s }
  labels = {
    "rows" => "List rows", "agree_pct" => "% \"readings agree\"", "shape_pct" => "% part numbers with a recognised shape",
    "s_found_pct" => "Sample: % rows found", "s_part_pct" => "Sample: % part number right",
    "s_key_pct" => "Sample: % key right (as printed)", "s_qty_pct" => "Sample: % quantity right",
    "s_appl_pct" => "Sample: % applicability digits right", "s_all_pct" => "Sample: % all four right",
    "s_missed" => "Sample: rows missed by both readings", "s_spurious" => "Sample: extra or split machine rows",
    "agree_part_prec" => "\"readings agree\" rows: % part number right", "agree_all_prec" => "\"readings agree\" rows: % all four right",
    "pm_printed_page" => "Page map: printed page right (sample pages)", "pm_illustration" => "Page map: illustration right (sample pages)",
    "pm_page_type" => "Page map: page type right (sample pages)", "clashes" => "Printed page numbers given to 2+ PDF pages",
    "printed_none" => "Drawing/list pages with no printed page", "illustrations" => "Illustrations found",
    "ill_titles" => "Illustrations with a title from the contents pages", "ill_with_drawing" => "Illustrations with a drawing page",
    "pages_list" => "List pages", "pages_drawing" => "Drawing pages"
  }
  table << "## Before and after the fix round"
  table << "Same AI sample, same comparison rules; \"before\" is the first full run (commit 2bbbb64)."
  table << ""
  table << "| | Before | After |"
  table << "|---|---|---|"
  labels.each { |k, l| table << "| #{l} | #{fmt.call(b[k])} | #{fmt.call(M[k])} |" if b.key?(k) || M.key?(k) }
  table << ""
end
out = out.flat_map { |l| l == "<!-- BEFORE-AFTER -->" ? table : [l] }
File.write(opts[:report], out.join("\n") + "\n")
puts "wrote #{opts[:report]}"
