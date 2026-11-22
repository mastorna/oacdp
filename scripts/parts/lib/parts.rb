# Shared helpers for the parts-data scripts (extract, check, review tool).
# Ruby standard library only.

require "yaml"
require "zlib"
require "date"

module Parts
  # Part-number shapes as printed (spacing kept), without any leading marker.
  SHAPES = [
    /\A\d{3} \d{3} \d{3}(?: [A-Z]{1,2})?\z/,   # 211 609 237 C
    /\AN \d{2} \d{3} \d\z/                      # N 13 634 1
  ].freeze
  MARKERS = ["*"].freeze
  STATUSES = %w[unverified verified corrected].freeze

  module_function

  def shape_ok?(part_no)
    SHAPES.any? { |re| re.match?(part_no.to_s) }
  end

  # "*211 609 601 A" -> ["*", "211 609 601 A"]; "211 609 601 A" -> [nil, "211 609 601 A"]
  def split_marker(printed)
    s = printed.to_s.strip
    m = s.match(/\A([^0-9A-Za-z\s]+)\s*(.*)\z/)
    m ? [m[1], m[2]] : [nil, s]
  end

  def norm_part(part_no)
    _marker, part = split_marker(part_no)
    part.gsub(/\s+/, "").upcase
  end

  # ---- Chassis numbers ------------------------------------------------------
  # "20 - NNN NNN" serials and plain 6/7-digit serials are one ascending
  # sequence: seq = digits after "20-", or the 6/7-digit number. Anything else
  # (e.g. a 9-digit number) is recorded as printed with seq: nil and a flag.
  DASH = "[-–—]"
  NUM = /20\s*#{DASH}\s*\d{3}\s?\d{3}|\d{1,3}(?:[  ]\d{3})+|\d{6,9}/

  def chassis_value(printed)
    p = printed.strip
    if (m = p.match(/\A20\s*#{DASH}\s*(\d{3})\s?(\d{3})\z/))
      { "printed" => p, "seq" => (m[1] + m[2]).to_i, "format" => "20-NNN NNN" }
    else
      digits = p.gsub(/\D/, "")
      if [6, 7].include?(digits.length)
        { "printed" => p, "seq" => digits.to_i, "format" => "#{digits.length}-digit" }
      else
        { "printed" => p, "seq" => nil, "format" => "#{digits.length}-digit",
          "note" => "outside the stated sequence rule (20-NNN NNN or 6/7 digits); not parsed" }
      end
    end
  end

  # Returns [from, to] parsed only where the text states them (else nil).
  def parse_chassis(text)
    t = text.to_s.gsub(/\s+/, " ")
    from = (m = t.match(/from Chassis No\.\s*(#{NUM})/)) ? chassis_value(m[1]) : nil
    to = (m = t.match(/up to (?:Chassis No\.\s*)?(#{NUM})/)) ? chassis_value(m[1]) : nil
    [from, to]
  end

  # Option codes such as "M 216" exactly as printed, never interpreted.
  def option_codes(*texts)
    texts.compact.flat_map { |t| t.to_s.scan(/\bM ?\d{2,3}\b/) }.uniq
  end

  # Recompute the fields that are derived from what is printed:
  # part_no_norm, chassis_from / chassis_to (or chassis_ranges for rows that
  # print one quantity per line) and option_codes. Used by extract and the
  # review tool, so both always agree with check-parts.rb.
  def derive!(row)
    row["part_no_norm"] = norm_part(row["part_no"])
    appl = row["applicability"]
    qty = row["quantity"]
    if qty.is_a?(Array) && appl && appl.lines.length == qty.length
      row["chassis_ranges"] = appl.lines.zip(qty).map do |line, q|
        f, t = parse_chassis(line)
        { "text" => line.strip, "quantity" => q.to_s, "chassis_from" => f, "chassis_to" => t }
      end
      row["chassis_from"] = row["chassis_to"] = nil
    else
      row["chassis_ranges"] = nil
      row["chassis_from"], row["chassis_to"] = parse_chassis(appl)
    end
    row["option_codes"] = option_codes(appl, row["type_and_model"])
    row
  end

  # ---- Alignment ------------------------------------------------------------
  # Order-preserving alignment of two lists of strings by similarity
  # (Needleman-Wunsch style, gaps free, matches need ratio >= min).
  # Returns an array, one entry per item of `a`: index into `b`, or nil.
  def align(a, b, min: 0.45)
    sim = a.map { |x| b.map { |y| ratio(x, y) } }
    r, l = a.length, b.length
    best = Array.new(r + 1) { Array.new(l + 1, 0.0) }
    (r - 1).downto(0) do |i|
      (l - 1).downto(0) do |j|
        take = sim[i][j] >= min ? sim[i][j] + best[i + 1][j + 1] : -1
        best[i][j] = [take, best[i + 1][j], best[i][j + 1]].max
      end
    end
    out = []
    i = j = 0
    while i < r
      if j < l && sim[i][j] >= min && best[i][j] == sim[i][j] + best[i + 1][j + 1]
        out << j; i += 1; j += 1
      elsif j < l && best[i][j] == best[i][j + 1]
        j += 1
      else
        out << nil; i += 1
      end
    end
    out
  end

  # Similarity 0..1 based on longest-common-subsequence length.
  def ratio(x, y)
    return 0.0 if x.empty? || y.empty?
    prev = Array.new(y.length + 1, 0)
    x.each_char do |cx|
      cur = [0]
      y.each_char.with_index { |cy, j| cur << (cx == cy ? prev[j] + 1 : [prev[j + 1], cur[j]].max) }
      prev = cur
    end
    2.0 * prev.last / (x.length + y.length)
  end

  def squash(s)
    s.to_s.downcase.sub(/\.{2,}.*/m, "").gsub(/[^0-9a-z]/, "")[0, 60]
  end

  # ---- 1-bit PNG reading (for crops / callout snapping / rotation) ---------
  # Returns [width, height, rows] where rows[y] is a String of bytes, 1 = white.
  def read_png_1bit(path)
    data = File.binread(path)
    pos = 8
    idat = +""
    w = h = depth = ctype = nil
    while pos < data.bytesize
      len = data[pos, 4].unpack1("N")
      type = data[pos + 4, 4]
      body = data[pos + 8, len]
      pos += 12 + len
      case type
      when "IHDR" then w, h, depth, ctype = body.unpack("NNCC")
      when "IDAT" then idat << body
      end
    end
    raise "#{path}: expected 1-bit greyscale PNG" unless depth == 1 && ctype == 0
    raw = Zlib::Inflate.inflate(idat)
    stride = (w + 7) / 8
    prev = Array.new(stride, 0)
    rows = []
    i = 0
    h.times do
      f = raw.getbyte(i)
      line = raw.byteslice(i + 1, stride).bytes
      i += 1 + stride
      stride.times do |x|
        a = x.zero? ? 0 : line[x - 1]
        b = prev[x]
        c = x.zero? ? 0 : prev[x - 1]
        line[x] = case f
                  when 0 then line[x]
                  when 1 then (line[x] + a) & 255
                  when 2 then (line[x] + b) & 255
                  when 3 then (line[x] + ((a + b) >> 1)) & 255
                  when 4
                    p = a + b - c
                    pa, pb, pc = (p - a).abs, (p - b).abs, (p - c).abs
                    (line[x] + (pa <= pb && pa <= pc ? a : (pb <= pc ? b : c))) & 255
                  end
      end
      prev = line
      rows << line
    end
    [w, h, rows] # rows are packed bytes; bit set = white
  end

  def black?(rows, x, y)
    ((rows[y][x >> 3] >> (7 - (x & 7))) & 1).zero?
  end

  # ---- Stable YAML ---------------------------------------------------------
  HEADER = <<~TXT
    # Parts data. Generated by scripts/parts/extract.rb and updated by the
    # review tool (dev/review/server.rb). Check with: ruby scripts/check-parts.rb <this file>
    # Text and numbers only: no page images are stored in the repository.
  TXT

  def load(path)
    YAML.safe_load_file(path, permitted_classes: [Date, Time], aliases: false)
  end

  # Independent copy of nested hashes/arrays/strings, so YAML never writes
  # anchors/aliases (&1 / *1) for values that happen to be shared in memory.
  def deep_dup(obj)
    case obj
    when Hash then obj.each_with_object({}) { |(k, v), h| h[deep_dup(k)] = deep_dup(v) }
    when Array then obj.map { |v| deep_dup(v) }
    when String then obj.dup
    else obj
    end
  end

  # Atomic write: the new text is parsed back with the same safe loader
  # before it replaces the file, so a bad write can never replace good data.
  def dump(path, data)
    yaml = HEADER + YAML.dump(deep_dup(data), line_width: -1).sub(/\A---\n/, "")
    YAML.safe_load(yaml, permitted_classes: [Date, Time], aliases: false)
    tmp = "#{path}.tmp-#{Process.pid}"
    File.write(tmp, yaml)
    File.rename(tmp, path)
  end
end
