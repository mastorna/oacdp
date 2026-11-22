# Shared helpers that turn the two machine readings of a page (pdftotext -tsv
# and tesseract tsv) into lines and list items. Used by extract.rb
# (one illustration, with an AI reading) and catalog.rb (the whole book).
# Ruby standard library only. Moved unchanged out of extract.rb.

require "csv"

module Readings
  module_function

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
# not_item: optional lambda; a line it accepts is never the start of an item
# (used by catalog.rb; extract.rb passes none, so its behaviour is unchanged).
def items_for(lines, page_height, not_item: nil)
  items = []
  lines.each do |l|
    next if l[:y0] > page_height * 0.885                          # footer area (stamp, "Illustration 32", page no.)
    next if HEADER_RE.match?(l[:text]) && !l[:text].match?(/\d{3}/)
    if item_line?(l) && !(not_item && not_item.call(l))
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

# Digits of the applicability text only: model codes ("M 215") and the
# quantities / "×" printed at the end of continuation lines are removed first,
# so punctuation noise and quantities don't count as differences.
# nil means the reading didn't capture applicability at all (not compared).
def digits(s)
  return nil if s.nil?
  s.to_s.lines.map { |l| l.gsub(/\bM ?\d{2,3}\b/, "").sub(/(?:(?:\A|\s+)(?:\d{1,2}|[xX×]))+\W*\s*\z/, "") }
   .join(" ").scan(/\d/).join
end
end
