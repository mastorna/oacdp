#!/usr/bin/env ruby
# Build or update the parts data file for one illustration from three
# independent readings:
#   A. the PDF's built-in text layer      (pdftotext -tsv)
#   B. tesseract at native resolution     (--dpi 300 --psm 4)
#   C. Claude's (AI) reading of the images (a YAML file you pass in)
# Rows already reviewed (status verified/corrected) are never overwritten.
#
# usage:
#   ruby scripts/parts/extract.rb --pdf ORIGINAL.pdf --work WORKDIR \
#        --reading claude-reading.yml --out src/_data/parts/vw-tpl-1963-08/ill32.yml
#
# WORKDIR must already hold page-NNN.png (pdfimages -png), raw/pdftext-NNN.tsv
# (pdftotext -tsv) and raw/tess-NNN.tsv (tesseract ... --dpi 300 --psm 4 tsv);
# see README "Parts data". WORKDIR must be outside the repository.

require "optparse"
require "csv"
require "digest"
require "open3"
require_relative "lib/parts"

opts = {}
OptionParser.new do |o|
  o.on("--pdf PATH") { |v| opts[:pdf] = v }
  o.on("--work DIR") { |v| opts[:work] = v }
  o.on("--reading PATH") { |v| opts[:reading] = v }
  o.on("--out PATH") { |v| opts[:out] = v }
end.parse!
%i[pdf work reading out].each { |k| abort "missing --#{k}" unless opts[k] }

REPO = File.expand_path("../..", __dir__)
abort "--work must be outside the repository" if File.expand_path(opts[:work]).start_with?(REPO + "/")

EDITION = "vw-tpl-1963-08"
LIST_PAGES = (342..349).to_a
DRAWING_PAGE = 341
PRINTED = { 341 => "6-4", 342 => "6-5", 343 => "6-6", 344 => "6-7", 345 => "6-8",
            346 => "6-9", 347 => "6-10", 348 => "6-11", 349 => "6-12" }.freeze

reading = Parts.load(opts[:reading])
work = opts[:work]

def png_size(path)
  File.binread(path, 24)[16, 8].unpack("NN")
end

# ---- machine readings -----------------------------------------------------
# Lines of words with pixel boxes: [{text:, words: [[text, conf]], x0:, y0:, x1:, y1:}]
def tsv_lines(path, scale: 1.0, page_level_key: "line_num")
  # Words are grouped into lines by vertical position across ALL blocks,
  # because pdftotext puts each table column in its own block.
  words = []
  CSV.read(path, col_sep: "\t", headers: true, quote_char: "\u0001").each do |r|
    next unless r["level"] == "5"
    t = r["text"].to_s.strip
    next if t.empty? || t.start_with?("###")
    l, tp, w, h = %w[left top width height].map { |c| r[c].to_f * scale }
    next if h <= 0 || h > 120     # skip noise blobs
    words << { t: t, conf: r["conf"].to_f, x0: l, y0: tp, x1: l + w, y1: tp + h, yc: tp + h / 2, h: h }
  end
  lines = []
  words.sort_by { |wd| wd[:yc] }.each do |wd|
    line = lines.last
    if line && (wd[:yc] - line[:yc]).abs < [line[:h], wd[:h]].max * 0.55
      line[:ws] << wd
      line[:yc] = line[:ws].sum { |x| x[:yc] } / line[:ws].length
      line[:h] = [line[:h], wd[:h]].max
    else
      lines << { ws: [wd], yc: wd[:yc], h: wd[:h] }
    end
  end
  lines.map do |line|
    ws = line[:ws].sort_by { |x| x[:x0] }
    { words: ws.map { |x| [x[:t], x[:conf], (x[:x0] + x[:x1]) / 2] }, text: ws.map { |x| x[:t] }.join(" "),
      x0: ws.map { |x| x[:x0] }.min, y0: ws.map { |x| x[:y0] }.min,
      x1: ws.map { |x| x[:x1] }.max, y1: ws.map { |x| x[:y1] }.max }
  end
end

HEADER_RE = /MAIN|GROUP|Key|Part No|Description|Quan|tity|Type and|HYDRAULIC|WHEEL DISCS|ROAD|Illustration|Printed in/i

# x-centre of the quantity column, from the "Quan-" header word (fallback ~1720 px).
def qty_column_x(lines)
  lines.each do |l|
    l[:words].each { |t, _c, xc| return xc if t =~ /\AQuan/i }
  end
  1720.0
end

# Quantity read from the quantity column of the item line and its continuation
# lines: a string, or a list when two quantities are printed on separate lines.
def qty_from(item, col_x)
  vals = item[:lines].flat_map do |l|
    l[:words].select { |_t, _c, xc| (xc - col_x).abs < 95 }
             .map { |t, _c, _x| t.gsub(/[.:;,|'"‘’“”_~\-]/, "") }
             .select { |t| t =~ /\A(\d{1,2}|[xX×])\z/ }
             .map { |t| t =~ /\A[xX×]\z/ ? "×" : t }
  end
  vals.empty? ? nil : (vals.length == 1 ? vals.first : vals)
end

def item_line?(line)
  t = line[:text]
  return false if HEADER_RE.match?(t) && !t.match?(/\d{3}/)
  return false if t.match?(/\A\W*(from|up|trom|fram|M ?2\d\d and|\()/i)
  t[0, 30].to_s.scan(/\d/).length >= 4 || t.match?(/\AN ?\d/)
end

# Split an item line into key, marker and part number (heuristic).
# The part number starts at the first token that looks like "N" or a 3+ digit
# group; the key is the last 1-2 digit token before it (punctuation ignored).
PART_START = /\A\W*[*•°]?\W*(?:N\z|N?\d{3,})/

def parse_item(text)
  t = text.gsub(/(?<!\d)(\d{1,2})[-–—](\d{3})/, '\\1 \\2')   # "21-211 609..." -> "21 211 609..."
  toks = t.split(/\s+/)
  start = toks.index { |x| x =~ PART_START } || 0
  key = nil
  toks[0...start].reverse_each do |x|
    if (m = x.match(/\A\W*(\d{1,2})\W*\z/))
      key = m[1]
      break
    end
  end
  toks = toks[start..] || []
  marker = nil
  if toks[0].to_s =~ /\A\W*([*•°])(.*)\z/
    marker = Regexp.last_match(1)
    toks[0] = Regexp.last_match(2)
    toks.shift if toks[0].empty?
  end
  part = []
  while (x = toks.first) && x !~ /[a-z]{2,}/ && part.join.gsub(/\W/, "").length < 11
    part << toks.shift
    break if part.join.gsub(/\W/, "").length >= 9 && toks.first.to_s !~ /\A[A-Z]{1,2}\z/
  end
  { "key" => key, "marker" => marker, "part_no" => part.join(" ").gsub(/[^0-9A-Za-z ]/, "").strip }
end

# Group item lines with their continuation lines.
def items_for(lines, page_height)
  items = []
  lines.each do |l|
    next if l[:y0] > page_height * 0.885                          # footer area (stamp, "Illustration 32", page no.)
    next if HEADER_RE.match?(l[:text]) && !l[:text].match?(/\d{3}/)
    if item_line?(l)
      items << { lines: [l] }
    elsif items.any?
      items.last[:lines] << l
    end
  end
  items.each do |it|
    first = it[:lines].first
    it[:text] = first[:text]
    it[:cont] = it[:lines][1..].map { |l| l[:text] }.join("\n")
    it[:box] = [it[:lines].map { |l| l[:x0] }.min, first[:y0], it[:lines].map { |l| l[:x1] }.max, it[:lines].map { |l| l[:y1] }.max]
    it[:min_conf] = first[:words].map(&:last).reject(&:negative?).min
  end
  items
end

def stamp_from(lines, height)
  l = lines.find { |x| x[:y0] > height * 0.85 && x[:text].match?(/\bTyp\b/i) }
  l && l[:text]
end

# ---- existing data (keep reviewed work) --------------------------------------
old = File.exist?(opts[:out]) ? Parts.load(opts[:out]) : {}
old_rows = (old["rows"] || []).to_h { |r| [r["id"], r] }
old_callouts = (old["callouts"] || []).to_h { |c| [c["id"], c] }
old_pages = (old["pages"] || []).to_h { |p| [p["pdf_page"], p] }
old_positions = (old["positions"] || []).to_h { |p| [p["id"], p] }
reviewed = ->(x) { x && %w[verified corrected].include?(x["status"]) }

def normalize_qty(q)
  q.is_a?(Array) ? q.map(&:to_s) : q.to_s
end

# Digits of the applicability text only: model codes ("M 215") and the
# quantities / "×" printed at the end of continuation lines are removed first,
# so punctuation noise and quantities don't count as differences.
# nil means the reading didn't capture applicability at all (not compared).
def digits(s)
  return nil if s.nil?
  s.to_s.lines.map { |l| l.gsub(/\bM ?\d{2,3}\b/, "").sub(/(?:(?:\A|\s+)(?:\d{1,2}|[xX×]))+\W*\s*\z/, "") }
   .join(" ").scan(/\d/).join
end

# ---- rows -------------------------------------------------------------------
rows_out = []
pages_out = []
report = { aligned: Hash.new(0), missed: Hash.new(0), rows: 0 }

PRINTED.each_key do |pdf_page|
  png = File.join(work, "page-#{pdf_page}.png")
  w, h = png_size(png)
  pdf_lines = tsv_lines(File.join(work, "raw", "pdftext-#{pdf_page}.tsv"), scale: w / 612.0)
  tess_lines = tsv_lines(File.join(work, "raw", "tess-#{pdf_page}.tsv"))
  mine_page = reading["pages"].find { |p| p["pdf_page"] == pdf_page } || {}

  page_entry = {
    "pdf_page" => pdf_page, "printed_page" => PRINTED[pdf_page],
    "image_px" => [w, h],
    "revision_stamp" => mine_page["revision_stamp"],
    "stamp_readings" => {
      "pdf_text" => stamp_from(pdf_lines, h), "tesseract" => stamp_from(tess_lines, h),
      "claude" => mine_page["revision_stamp"]
    },
    "margin_text" => mine_page["margin_text"],
    "notes" => mine_page["notes"],
    "stamp_status" => "unverified", "reviewed_by" => nil, "reviewed_at" => nil, "corrections" => []
  }
  prior = old_pages[pdf_page]
  page_entry = prior if prior && %w[verified corrected].include?(prior["stamp_status"])
  pages_out << page_entry
  next unless LIST_PAGES.include?(pdf_page)

  mine = reading["rows"].select { |r| r["page"] == pdf_page }
  sources = { "pdf_text" => items_for(pdf_lines, h), "tesseract" => items_for(tess_lines, h) }
  colx = { "pdf_text" => qty_column_x(pdf_lines), "tesseract" => qty_column_x(tess_lines) }
  matched = {}
  sources.each do |name, items|
    idx = Parts.align(mine.map { |r| Parts.squash(r["part"].to_s + r["desc"].to_s) },
                      items.map { |it| Parts.squash(it[:text]) })
    matched[name] = idx.map { |i| i && items[i] }
  end

  mine.each_with_index do |r, n|
    order = n + 1
    id = format("ill32-%s-%02d", PRINTED[pdf_page], order)
    marker, part = Parts.split_marker(r["part"])
    appl = r["appl"]
    from, to = Parts.parse_chassis(appl)
    ranges = nil
    if r["qty"].is_a?(Array) && appl && appl.lines.length == r["qty"].length
      # one quantity per printed line: each line is its own sub-range
      ranges = appl.lines.zip(r["qty"]).map do |line, q|
        f, t = Parts.parse_chassis(line)
        { "text" => line.strip, "quantity" => q.to_s, "chassis_from" => f, "chassis_to" => t }
      end
      from = to = nil
    end
    readings = {}
    matched.each do |name, items|
      it = items[n]
      if it.nil?
        readings[name] = nil
        report[:missed][name] += 1
        next
      end
      report[:aligned][name] += 1
      p = parse_item(it[:text])
      p["quantity"] = qty_from(it, colx[name])
      appl_text = if r["inline"]
                    # printed on the item line itself: take the text from the first word onwards
                    it[:text][/(?:from|up|trom|fram)\b.*/i]
                  else
                    it[:cont].empty? ? nil : it[:cont]
                  end
      readings[name] = p.merge("applicability" => appl_text, "text" => it[:text])
      readings[name]["min_conf"] = it[:min_conf]&.round if name == "tesseract"
    end
    readings["claude"] = {
      "key" => r["key"]&.to_s, "marker" => marker, "part_no" => part,
      "description" => r["desc"], "quantity" => normalize_qty(r["qty"]),
      "applicability" => appl, "type_and_model" => r["tm"], "read_on" => reading["read_on"].to_s
    }

    # disagreements between the readings that exist
    dis = []
    have = readings.values.compact
    cmp = lambda do |field, &f|
      vals = have.map { |x| f.call(x) }
      vals = vals.compact if %w[applicability quantity].include?(field) # a reading that missed it has no opinion
      vals = vals.uniq
      dis << field if vals.length > 1
    end
    cmp.call("part_no") { |x| Parts.norm_part(x["part_no"]) }
    cmp.call("marker") { |x| x["marker"].nil? ? nil : "*" }
    cmp.call("key") { |x| x["key"].to_s.empty? ? nil : x["key"].to_s }
    cmp.call("quantity") { |x| x["quantity"].nil? ? nil : Array(x["quantity"]).join("/") }
    cmp.call("applicability") { |x| digits(x["applicability"]) }

    # crop box: tesseract item, else text-layer item, else interpolate later
    src = matched["tesseract"][n] || matched["pdf_text"][n]
    bbox = src && [[src[:box][0] - 30, 0].max, [src[:box][1] - 25, 0].max, [w - 120, src[:box][2] + 40].max.clamp(0, w), [src[:box][3] + 25, h].min].map(&:round)

    row = {
      "id" => id, "edition" => EDITION, "printed_page" => PRINTED[pdf_page], "pdf_page" => pdf_page,
      "row_order" => order, "key" => r["key"], "marker" => marker, "part_no" => part,
      "part_no_norm" => Parts.norm_part(part), "description" => r["desc"],
      "quantity" => normalize_qty(r["qty"]), "applicability" => appl,
      "applicability_inline" => r["inline"] ? true : false,
      "chassis_from" => from, "chassis_to" => to, "chassis_ranges" => ranges,
      "option_codes" => Parts.option_codes(appl, r["tm"]),
      "type_and_model" => r["tm"], "row_mark" => r["row_mark"], "print_note" => r["note"],
      "position" => nil, "position_status" => "suggested",
      "bbox_px" => bbox, "bbox_source" => (matched["tesseract"][n] ? "tesseract" : (matched["pdf_text"][n] ? "pdf_text" : "interpolated")),
      "readings" => readings, "disagreements" => dis,
      "status" => "unverified", "reviewed_by" => nil, "reviewed_at" => nil, "corrections" => []
    }
    Parts.derive!(row)   # same derivation as the review tool uses
    rows_out << (reviewed.call(old_rows[id]) ? old_rows[id] : row)
    report[:rows] += 1
  end
end

# interpolate missing boxes from neighbours on the same page
rows_out.each_with_index do |r, i|
  next if r["bbox_px"]
  w, = png_size(File.join(work, "page-#{r['pdf_page']}.png"))
  prev = rows_out[0...i].reverse.find { |x| x["pdf_page"] == r["pdf_page"] && x["bbox_px"] }
  nxt = rows_out[(i + 1)..].find { |x| x["pdf_page"] == r["pdf_page"] && x["bbox_px"] }
  y0 = prev ? prev["bbox_px"][3] : 300
  y1 = nxt ? nxt["bbox_px"][1] : y0 + 250
  r["bbox_px"] = [150, y0, w - 150, [y1, y0 + 80].max]
end

# ---- positions (suggestions) ---------------------------------------------------
positions = reading["positions"].map do |p|
  o = old_positions[p["id"]]
  (o && o["status"] != "suggested") ? o : { "id" => p["id"], "label" => p["label"], "key" => p["key"], "status" => "suggested" }
end
rows_out.each do |r|
  next unless r["position_status"] == "suggested"
  full = [r["marker"], r["part_no"]].compact.join
  hit = reading["positions"].find do |p|
    p["parts"].include?(full) && (p["rows_on_page"].nil? || p["rows_on_page"] == r["pdf_page"])
  end
  r["position"] = hit && hit["id"]
end

# ---- callouts ---------------------------------------------------------------------
cw, ch = png_size(File.join(work, "page-#{DRAWING_PAGE}.png"))
rot_tsv = File.join(work, "raw", "tess-#{DRAWING_PAGE}-rotated-cw.tsv")
unless File.exist?(rot_tsv)
  # rotate the drawing 90 degrees clockwise (labels are printed sideways), as PBM
  _w, _h, bits = Parts.read_png_1bit(File.join(work, "page-#{DRAWING_PAGE}.png"))
  rw, rh = ch, cw
  stride = (rw + 7) / 8
  out = Array.new(rh) { "\0".b * stride }
  rh.times do |ny|          # ny = original x
    row = out[ny]
    rw.times do |nx|        # nx = H-1-original y
      oy = ch - 1 - nx
      row.setbyte(nx >> 3, row.getbyte(nx >> 3) | (0x80 >> (nx & 7))) if Parts.black?(bits, ny, oy)
    end
  end
  pbm = File.join(work, "page-#{DRAWING_PAGE}-rotated-cw.pbm")
  File.binwrite(pbm, "P4\n#{rw} #{rh}\n" + out.join)
  _o, e, s = Open3.capture3("tesseract", pbm, rot_tsv.sub(/\.tsv\z/, ""), "--dpi", "300", "--psm", "11",
                            "-c", "tessedit_char_whitelist=0123456789", "tsv")
  abort "tesseract failed on rotated drawing: #{e}" unless s.success?
end
rot_words = CSV.read(rot_tsv, col_sep: "\t", headers: true, quote_char: "\u0001")
                .select { |r| r["level"] == "5" && r["text"].to_s.strip =~ /\A\d{1,2}\z/ }
                .map do |r|
                  l, t, w2, h2 = %w[left top width height].map { |c| r[c].to_f }
                  cx, cy = l + w2 / 2, t + h2 / 2     # in rotated coords
                  { text: r["text"].strip, x: cy, y: ch - 1 - cx, conf: r["conf"].to_f } # back to page coords
                end
# Snap an approximate label position onto the nearest digit-sized ink:
# connected blobs 6-60 px in each direction (leader lines and drawing parts
# are larger), merged with neighbours within 14 px (two-digit labels).
_dw, _dh, DRAW_BITS = Parts.read_png_1bit(File.join(work, "page-#{DRAWING_PAGE}.png"))
def snap(x, y, w, h, radius: 75)
  x0, y0 = [x - radius, 0].max, [y - radius, 0].max
  x1, y1 = [x + radius, w - 1].min, [y + radius, h - 1].min
  seen = {}
  blobs = []
  (y0..y1).each do |yy|
    (x0..x1).each do |xx|
      next if seen[[xx, yy]] || !Parts.black?(DRAW_BITS, xx, yy)
      stack = [[xx, yy]]
      seen[[xx, yy]] = true
      bx0 = bx1 = xx
      by0 = by1 = yy
      n = 0
      until stack.empty?
        cx, cy = stack.pop
        n += 1
        bx0, bx1 = [bx0, cx].min, [bx1, cx].max
        by0, by1 = [by0, cy].min, [by1, cy].max
        [[1, 0], [-1, 0], [0, 1], [0, -1]].each do |dx, dy|
          nx, ny = cx + dx, cy + dy
          next if nx < x0 || nx > x1 || ny < y0 || ny > y1 || seen[[nx, ny]] || !Parts.black?(DRAW_BITS, nx, ny)
          seen[[nx, ny]] = true
          stack << [nx, ny]
        end
      end
      bw, bh = bx1 - bx0 + 1, by1 - by0 + 1
      blobs << [bx0, by0, bx1, by1] if bw.between?(6, 60) && bh.between?(6, 60) && n >= 25
    end
  end
  return nil if blobs.empty?
  centre = ->(b) { [(b[0] + b[2]) / 2.0, (b[1] + b[3]) / 2.0] }
  best = blobs.min_by { |b| c = centre.call(b); Math.hypot(c[0] - x, c[1] - y) }
  group = [best]
  loop do
    added = blobs.select do |b|
      !group.include?(b) && group.any? { |g| b[0] <= g[2] + 14 && g[0] <= b[2] + 14 && b[1] <= g[3] + 14 && g[1] <= b[3] + 14 }
    end
    break if added.empty?
    group.concat(added)
  end
  gx0, gy0 = group.map { |b| b[0] }.min, group.map { |b| b[1] }.min
  gx1, gy1 = group.map { |b| b[2] }.max, group.map { |b| b[3] }.max
  return nil if gx1 - gx0 > 70 || gy1 - gy0 > 90 # merged into a drawing part, not a label
  [((gx0 + gx1) / 2.0).round, ((gy0 + gy1) / 2.0).round]
end

seen = Hash.new(0)
callouts = reading["callouts"].map do |label, x, y|
  seen[label] += 1
  id = "c#{label}#{seen[label] > 1 ? "-#{seen[label]}" : ''}"
  near = rot_words.select { |wd| wd[:text] == label && Math.hypot(wd[:x] - x, wd[:y] - y) < 90 }
                  .min_by { |wd| Math.hypot(wd[:x] - x, wd[:y] - y) }
  snapped = near ? nil : snap(x, y, cw, ch)
  # never snap onto another callout's label
  if snapped && reading["callouts"].any? { |l2, x2, y2| !(l2 == label && x2 == x && y2 == y) && Math.hypot(snapped[0] - x2, snapped[1] - y2) < Math.hypot(snapped[0] - x, snapped[1] - y) }
    snapped = nil
  end
  px = if near then [near[:x].round, near[:y].round]
       elsif snapped then snapped
       else [x, y]
       end
  c = {
    "id" => id, "label" => label, "key" => label.to_i,
    "page_px" => px, "page_frac" => [(px[0].to_f / cw).round(4), (px[1].to_f / ch).round(4)],
    "rotated" => true,
    "readings" => { "claude_px" => [x, y], "tesseract_rotated_px" => near && [near[:x].round, near[:y].round] },
    "position_source" => if near then "tesseract (rotated), matched to Claude's label"
                         elsif snapped then "Claude's approximate position snapped to the nearest label-sized ink"
                         else "Claude (approximate)"
                         end,
    "status" => "unverified", "reviewed_by" => nil, "reviewed_at" => nil, "corrections" => []
  }
  reviewed.call(old_callouts[id]) ? old_callouts[id] : c
end

data = {
  "edition" => {
    "id" => EDITION,
    "title" => "VW Transporter Parts List 1960-1967 (August 1963)",
    "source_file" => File.basename(opts[:pdf]),
    "source_sha256" => Digest::SHA256.file(opts[:pdf]).hexdigest
  },
  "illustration" => {
    "number" => 32, "title" => "Hydraulic brakes", "main_group" => 6,
    "drawing" => { "printed_page" => "6-4", "pdf_page" => 341 },
    "lists" => { "printed_pages" => "6-5 to 6-12", "pdf_pages" => [342, 349] }
  },
  "conventions" => {
    "chassis_sequence" => "\"20-NNN NNN\" serials and 6/7-digit serials are one ascending sequence: seq = the digits after \"20-\", or the 6/7-digit number. Other forms keep seq: null.",
    "key" => "null when the key column shows a dash",
    "marker" => "a sign printed before the part number, kept as printed; meaning unknown, not interpreted",
    "quantity" => "as printed; a list when two quantities are printed on separate lines; \"×\" is printed as shown",
    "unreadable" => "\"[?]\" marks a character a reader could not read with certainty",
    "extracted_fields" => "prefilled from the Claude reading; a person confirms or corrects every row in the review tool",
    "readings" => "pdf_text = the PDF's built-in OCR text layer; tesseract = tesseract 5 at native ~300 dpi, psm 4; claude = AI reading of the page image"
  },
  "pages" => pages_out,
  "callouts" => callouts,
  "positions" => positions,
  "rows" => rows_out
}

require "fileutils"
FileUtils.mkdir_p(File.dirname(opts[:out]))
Parts.dump(opts[:out], data)
puts "wrote #{opts[:out]}: #{rows_out.length} rows, #{callouts.length} callouts, #{positions.length} positions, #{pages_out.length} pages"
puts "aligned rows: #{report[:aligned]}; missed: #{report[:missed]}"
puts "rows with disagreements: #{rows_out.count { |r| r['disagreements'].any? }}"
puts "callouts placed by rotated tesseract: #{callouts.count { |c| c['readings']['tesseract_rotated_px'] }}/#{callouts.length}"
