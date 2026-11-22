# Machine-only list rows: the two readings of a page matched to each other,
# one value chosen per field, and the confidence rule. Used by catalog.rb.
# Ruby standard library only.

require_relative "parts"
require_relative "readings"
require_relative "book"

module Rows
  NORM_SHAPES = [/\A\d{9}[A-Z]{0,2}\z/, /\AN\d{6}\z/].freeze
  COL = 95 # half-width of the quantity column, px (as in Readings.qty_from)

  module_function

  def norm_shape_ok?(norm)
    NORM_SHAPES.any? { |re| re.match?(norm.to_s) }
  end

  # The book's usual spacing for a recognised shape, else nil.
  def canonical(norm)
    if (m = norm.to_s.match(/\A(\d{3})(\d{3})(\d{3})([A-Z]{1,2})?\z/))
      [m[1], m[2], m[3], m[4]].compact.join(" ")
    elsif (m = norm.to_s.match(/\AN(\d{2})(\d{3})(\d)\z/))
      "N #{m[1]} #{m[2]} #{m[3]}"
    end
  end

  # Lines that belong to the list body: below the column header, without
  # all-capital sub-headings ("PISTONS") that would otherwise be read as
  # continuation text of the row above.
  def body_lines(lines, h)
    hdr = lines.select { |l| l[:y0] < h * 0.25 && l[:text].match?(/Part\s*No|Descrip|Quan/i) }
    top = hdr.any? ? hdr.map { |l| l[:y1] }.max : h * 0.06
    lines.reject do |l|
      t = l[:text]
      l[:y1] <= top + 5 ||
        (t !~ /\d/ && t !~ /[a-z]/ && t.scan(/[A-Z]/).length >= 4)
    end
  end

  def words_text(ws)
    ws.map(&:first).join(" ").strip
  end

  # Description: the text after the key and part number, up to the dot leaders.
  def description(text, part_no)
    toks = text.split(/\s+/)
    target = part_no.to_s.gsub(/[^0-9A-Za-z]/, "")
    idx = 0
    unless target.empty?
      acc = +""
      toks.each_with_index do |t, i|
        acc << t.gsub(/[^0-9A-Za-z]/, "")
        if acc.end_with?(target)
          idx = i + 1
          break
        end
      end
    end
    d = toks[idx..].to_a.join(" ")
    d = d.sub(/\s*(?:[.·•,'‘’:;~_…]\s*){3,}.*\z/m, "")
    d = d.sub(/(?:\s+(?:\d{1,2}|[xX×]))+\W*\z/, "")
    d.strip.empty? ? nil : d.strip
  end

  # The key as printed, from the text before the part number: 35, "A 66",
  # "B 23", "A 18/36". Returns [key, prefix]; key is an Integer for a plain
  # key (as in ill32.yml), a String when it carries a drawing letter or "/".
  def key_as_printed(text, parsed_key)
    t = text.gsub(/(?<!\d)(\d{1,2})[-–—](\d{3})/, '\\1 \\2')
    toks = t.split(/\s+/)
    start = toks.index { |x| x =~ Readings::PART_START } || 0
    pre = toks[0...start].join(" ").gsub(%r{[^A-Za-z0-9/ ]}, " ").squeeze(" ").strip
    m = pre.match(%r{(?:(?<![A-Za-z])([A-D])\s*)?(\d{1,3}(?:\s*/\s*\d{1,3})?)\z})
    return [parsed_key&.to_i, nil] unless m
    num = m[2].gsub(/\s+/, "")
    return ["#{m[1]} #{num}", m[1]] if m[1]
    return [nil, nil] if num.include?("/")   # "8/64" in the key column is a date, not a key
    [num.to_i, nil]
  end

  # Lines that need a person: colour codes with date ranges ("8/63 – 7/64 395
  # ice blue – 81") or bare colour lines ("395 ice blue"). Kept verbatim.
  COLOUR_DATE_RE = %r{\b\d{1,2}/\d{2}\s*[-–—~]|^\W{0,2}\d{3}\s+[a-z]{3,}}

  # a colour/date line that must stay with the row above, not start a row
  COLOUR_START_RE = %r{\A\W{0,2}(?:\d{1,2}/\d{2}\s*[-–—~]|\d{3}\s+[a-z]{3,})}

  # A drawing letter on a key ("A 66") is kept only when the page's
  # illustration label has that drawing ("1+A1" has A); otherwise it is
  # speckle read as a letter and only the number is kept.
  def check_prefix!(r, ill)
    return r unless r && r["key_prefix"] && ill
    return r if ill.include?("+#{r['key_prefix']}")
    num = r["key"].to_s.sub(/\A[A-D]\s*/, "")
    r["key"] = num.include?("/") ? num : num.to_i
    r["key_prefix"] = nil
    r
  end

  INLINE_RE = /\s*\b((?:up\s+to|from)\s+(?:Chassis|Engine|Gearbox|Transmission)\b.*)\z/i

  def fields(it, colx)
    p = Readings.parse_item(it[:text])
    first, *cont = it[:lines]
    left = first[:words].select { |_t, _c, xc| xc < colx - COL }
    right = first[:words].select { |_t, _c, xc| xc > colx + COL }
    desc = description(words_text(left), p["part_no"])
    inline = nil
    if desc && (m = desc.match(INLINE_RE))
      inline = m[1].strip
      desc = desc.sub(INLINE_RE, "").strip
      desc = nil if desc.empty?
    end
    appl_lines = cont.map { |l| words_text(l[:words].select { |_t, _c, xc| xc < colx - COL }) }.reject(&:empty?)
    tm_lines = [words_text(right), *cont.map { |l| words_text(l[:words].select { |_t, _c, xc| xc > colx + COL }) }].reject(&:empty?)
    appl = inline || (appl_lines.empty? ? nil : appl_lines.join("\n"))
    key, prefix = key_as_printed(it[:text], p["key"])
    {
      "key" => key, "key_prefix" => prefix, "marker" => p["marker"], "part_no" => p["part_no"],
      "description" => desc, "quantity" => Readings.qty_from(it, colx),
      "applicability" => appl, "applicability_inline" => !inline.nil?,
      "type_and_model" => tm_lines.empty? ? nil : tm_lines.join("\n"),
      "text" => it[:text], "continuation" => it[:cont].empty? ? nil : it[:cont],
      "min_conf" => it[:min_conf]&.round
    }
  end

  def qty_s(q)
    q.nil? ? nil : Array(q).join("/")
  end

  # The confidence rule. Returns [label, reasons].
  def confidence(pdf, tess)
    reasons = []
    if pdf.nil? || tess.nil?
      reasons << (pdf ? "only_text_layer" : "only_tesseract")
      one = pdf || tess
      reasons << "bad_shape" unless norm_shape_ok?(Parts.norm_part(one["part_no"]))
      return ["needs checking", reasons]
    end
    a, b = Parts.norm_part(pdf["part_no"]), Parts.norm_part(tess["part_no"])
    reasons << "part_no_differs" if a != b
    reasons << "bad_shape" unless norm_shape_ok?(a) && (a == b || norm_shape_ok?(b))
    reasons << "marker_differs" if pdf["marker"].nil? != tess["marker"].nil?
    reasons << "key_differs" if pdf["key"] && tess["key"] && pdf["key"] != tess["key"]
    qa, qb = qty_s(pdf["quantity"]), qty_s(tess["quantity"])
    reasons << "qty_differs" if qa && qb && qa != qb
    da, db = Readings.digits(pdf["applicability"]), Readings.digits(tess["applicability"])
    reasons << "applicability_differs" if da && db && da != db
    [reasons.empty? ? "readings agree" : "needs checking", reasons]
  end

  # Match the two readings' items in page order; unmatched items of either
  # reading become rows of their own.
  def merge(pdf_items, tess_items)
    idx = Parts.align(pdf_items.map { |i| Parts.squash(i[:text]) }, tess_items.map { |i| Parts.squash(i[:text]) })
    used = {}
    pairs = pdf_items.each_with_index.map do |it, i|
      j = idx[i]
      used[j] = true if j
      [it, j && tess_items[j]]
    end
    tess_items.each_with_index { |it, j| pairs << [nil, it] unless used[j] }
    pairs.sort_by { |a, b| (a || b)[:box][1] }
  end

  def for_page(page, tess_lines, pdf_lines, w, h, slug)
    readers = { "pdf_text" => pdf_lines, "tesseract" => tess_lines }
    colx = readers.transform_values { |ls| Readings.qty_column_x(ls) }
    items = readers.to_h do |name, ls|
      cx = colx[name]
      # continuation lines that look like items: "Type and model" text only
      # (all words right of the description), or applicability text near the start
      not_item = lambda do |l|
        l[:words].all? { |_t, _c, xc| xc > cx - COL } ||
          l[:text].match?(COLOUR_START_RE) ||
          l[:text].match?(/\A\W*(?:\S\W+)?(?:up\s?to|from|Chassis\s+No|Engine\s+No)\b/i)
      end
      [name, Readings.items_for(body_lines(ls, h), h, not_item: not_item)]
    end
    # row ids use the printed page, or "pNNN" (PDF page) when it is unknown or not unique
    printed = page["_id_page"] || page["printed_page"] || "p#{page['pdf_page']}"
    merge(items["pdf_text"], items["tesseract"]).each_with_index.map do |(pi, ti), n|
      rd = { "pdf_text" => pi && fields(pi, colx["pdf_text"]), "tesseract" => ti && fields(ti, colx["tesseract"]) }
      rd.each_value { |x| check_prefix!(x, page["illustration"]) }
      label, reasons = confidence(rd["pdf_text"], rd["tesseract"])
      # layouts the machine does not parse yet: kept verbatim, always checked by a person
      extra = []
      extra << "sp_set_layout" if page["layout"] == "sp_set"
      extra << "colour_date_lines" if rd.values.compact.any? { |x| x["applicability"].to_s.match?(COLOUR_DATE_RE) }
      reasons += extra
      label = "needs checking" if extra.any?
      ok = ->(r) { r && norm_shape_ok?(Parts.norm_part(r["part_no"])) }
      primary, other = if ok.call(rd["pdf_text"]) || !ok.call(rd["tesseract"])
                         [rd["pdf_text"] || rd["tesseract"], rd["pdf_text"] && rd["tesseract"]]
                       else
                         [rd["tesseract"], rd["pdf_text"]]
                       end
      pick = ->(f) { primary[f].nil? && other ? other[f] : primary[f] }
      norm = Parts.norm_part(primary["part_no"])
      src = ti || pi
      bx = src[:box]
      row = {
        "id" => format("%s-%s-%02d", slug, printed, n + 1),
        "edition" => Book::EDITION, "printed_page" => page["printed_page"], "pdf_page" => page["pdf_page"],
        "row_order" => n + 1, "key" => pick.call("key"), "key_prefix" => pick.call("key_prefix"), "marker" => primary["marker"],
        "part_no" => canonical(norm) || primary["part_no"], "part_no_norm" => norm,
        "description" => pick.call("description"), "quantity" => pick.call("quantity"),
        "applicability" => pick.call("applicability"), "applicability_inline" => primary["applicability_inline"],
        "chassis_from" => nil, "chassis_to" => nil, "chassis_ranges" => nil, "option_codes" => [],
        "type_and_model" => pick.call("type_and_model"),
        "position" => nil, "position_status" => "suggested",
        "bbox_px" => [[bx[0] - 30, 0].max, [bx[1] - 25, 0].max, [w - 120, bx[2] + 40].max.clamp(0, w), [bx[3] + 25, h].min].map(&:round),
        "bbox_source" => ti ? "tesseract" : "pdf_text",
        "readings" => rd, "disagreements" => disagreement_fields(reasons),
        "confidence" => label, "confidence_reasons" => reasons,
        "status" => "unverified", "reviewed_by" => nil, "reviewed_at" => nil, "corrections" => []
      }
      row["quantity"] = row["quantity"].map(&:to_s) if row["quantity"].is_a?(Array)
      Parts.derive!(row)
      row
    end
  end

  # Field names the review tool highlights, from the confidence reasons.
  REASON_FIELD = { "part_no_differs" => "part_no", "bad_shape" => "part_no", "marker_differs" => "marker",
                   "key_differs" => "key", "qty_differs" => "quantity", "applicability_differs" => "applicability" }.freeze

  def disagreement_fields(reasons)
    reasons.filter_map { |r| REASON_FIELD[r] }.uniq
  end

  # Suggested positions: each keyed row starts one; rows below without a key join it.
  def positions!(rows, slug)
    out = {}
    current = nil
    rows.each do |r|
      if r["key"]
        current = "#{slug}-k#{r['key'].to_s.gsub(/[^0-9A-Za-z]/, '')}".downcase
        out[current] ||= { "id" => current, "label" => "Key #{r['key']}", "key" => r["key"], "status" => "suggested" }
      end
      r["position"] = current
    end
    out.values
  end
end
