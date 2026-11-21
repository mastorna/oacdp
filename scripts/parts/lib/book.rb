# Whole-book helpers for the August 1963 parts list: reading every page's
# two machine readings, the page map (printed page, main group,
# illustration, page type, stamp) and its sequence repair.
# Ruby standard library only.

require "csv"
require_relative "readings"

module Book
  EDITION = "vw-tpl-1963-08"

  # The book's own list of main groups and addendum sections (PDF 12).
  MAIN_GROUPS = {
    "1" => "Engine", "2" => "Fuel tank, Exhaust, Heating system", "3" => "Transmission",
    "4" => "Front axle, Steering", "5" => "Rear axle", "6" => "Wheels, Brakes",
    "7" => "Frame, Hand lever system, Pedal cluster", "8" => "Body", "9" => "Electrical equipment",
    "0" => "Accessories", "ST" => "Standard parts", "SP" => "SP Sets",
    "L" => "Lacquers, Servicing Materials and Sealing Compounds", "S" => "Special models"
  }.freeze

  PRINTED_RE = /\A[\W_]*(ST|SP|S|L|[0-9])\s*[-–—~=]\s*(\d{1,3})[\W_]*\z/
  STAMP_RE = /T[yvj]p\.?\s*2\s*(\d{1,2})\s*[\/l1|]\s*(\d{2})\b/i
  # "Illustration 32" as OCR reads it: "Nlustration", "iljustration", "IUus.tr~tion", "tation 2" ...
  ILL_RE = /(?:ust|us\.t|stra|tion)[a-z~.]*\.?\s{0,3}((?:\d{1,3}|[tlI])(?:\s*\+\s*A\s*[0-9lIi]{1,2})?)(?![0-9])/i
  PART_TOKEN_RE = /(?<![\d])(\d{3})\s?(\d{3})\s?(\d{3})(?![\d])/

  module_function

  # Text-layer lines in image pixels. Scale from the page size (points) in the
  # TSV's own page row; a fold-out whose image is landscape on a portrait page
  # is rotated relative to the text layer, so its geometry is not usable.
  def pdf_lines(tsv, w, h)
    pw = ph = nil
    File.foreach(tsv) do |l|
      c = l.split("\t")
      if c[0] == "1"
        pw, ph = c[8].to_f, c[9].to_f
        break
      end
    end
    return [[], false] unless pw && pw.positive?
    rotated = (w > h) != (pw > ph)
    sx, sy = rotated ? [w / ph, h / pw] : [w / pw, h / ph]
    lines = Readings.tsv_lines(tsv, scale: 1.0)
    lines.each do |l|
      l[:x0] *= sx; l[:x1] *= sx; l[:y0] *= sy; l[:y1] *= sy
      l[:words] = l[:words].map { |t, c, xc| [t, c, xc * sx] }
    end
    [lines, !rotated]
  end

  def read_pages(work)
    Dir[File.join(work, "page-*.png")].sort.map do |png|
      n = png[/page-(\d{3})\.png\z/, 1]
      w, h = Readings.png_size(png)
      tess = File.join(work, "raw", "tess-#{n}.tsv")
      pdft = File.join(work, "raw", "pdftext-#{n}.tsv")
      next nil unless File.size?(tess) && File.size?(pdft)
      pl, geo = pdf_lines(pdft, w, h)
      { pdf_page: n.to_i, w: w, h: h, ink: File.size(png) * 8.0 / (w * h),
        tess: Readings.tsv_lines(tess), pdf: pl, pdf_geometry: geo }
    end.compact
  end

  def footer(lines, h, geo = true)
    geo ? lines.select { |l| l[:y0] > h * 0.88 } : lines
  end

  def stamp(lines)
    lines.each { |l| (m = l[:text].match(STAMP_RE)) && (return "Typ 2 #{m[1]}/#{m[2]}") }
    nil
  end

  def ill_number(lines)
    lines.each do |l|
      next unless (m = l[:text].match(ILL_RE))
      return m[1].gsub(/\s+/, "").tr("tlIi", "1111").sub("+a", "+A")
    end
    nil
  end

  def printed(lines, w)
    cands = lines.flat_map { |l| l[:words].map { |t, _c, xc| [t, xc] } }
                 .filter_map { |t, xc| (m = t.match(PRINTED_RE)) && [m[1], m[2].to_i, xc] }
    best = cands.max_by { |_g, _k, xc| xc }  # the page number is printed at the outer (right) edge
    best && best[0, 2]
  end

  def part_tokens(lines)
    lines.sum { |l| l[:text].scan(PART_TOKEN_RE).length + l[:text].scan(/\bN\s?\d{2}\s?\d{3}\s?\d\b/).length }
  end

  # Per-page features from both readings.
  def features(pg)
    w, h = pg[:w], pg[:h]
    tf = footer(pg[:tess], h)
    pf = footer(pg[:pdf], h, pg[:pdf_geometry])
    all_words = (pg[:tess] + pg[:pdf]).flat_map { |l| l[:words].map(&:first) }
    head_text = (pg[:tess] + pg[:pdf]).select { |l| !pg[:pdf_geometry] || l[:y0] < h * 0.15 }.map { |l| l[:text] }.join(" ")
    upper_text = (pg[:tess] + pg[:pdf]).select { |l| l[:y0] < h * 0.4 }.map { |l| l[:text] }.join(" ")
    {
      stamp_t: stamp(tf), stamp_p: stamp(pf),
      ill_t: ill_number(tf), ill_p: ill_number(pf),
      printed_t: printed(tf, w), printed_p: printed(pf, w),
      parts_t: part_tokens(pg[:tess]), parts_p: part_tokens(pg[:pdf]),
      items_t: pg[:tess].count { |l| Readings.item_line?(l) },
      items_p: pg[:pdf].count { |l| Readings.item_line?(l) },
      words: [pg[:tess], pg[:pdf]].map { |ls| ls.sum { |l| l[:words].length } }.max,
      digit_labels: all_words.count { |t| t.match?(/\A\d{1,2}\z/) } / 2.0,
      head: head_text, upper: upper_text,
      contents_lines: pg[:tess].count { |l| l[:text].match?(/[a-z]{3}.*\s(\d{1,3}(\+A\s?\d)?|\d+\+Ai?)\s*\z/) }
    }
  end

  def page_type(pg, f)
    parts = [f[:parts_t], f[:parts_p]].max
    items = [f[:items_t], f[:items_p]].max
    return "other" if pg[:pdf_page] <= 15
    return "index" if parts >= 3 && f[:head].match?(/\bPage\b/) && !f[:head].match?(/Quan|tity/i)
    return "parts_list" if parts >= 3 || items >= 4
    return "contents" if f[:upper].match?(/ustration/i) && f[:contents_lines] >= 2 && f[:digit_labels] < 6
    return "drawing" if f[:digit_labels] >= 4 || (pg[:ink] > 0.05 && f[:words] < 60)
    "other"
  end

  # ---- page map with sequence repair ------------------------------------------------
  def page_map(pages)
    feats = pages.map { |pg| features(pg) }
    entries = pages.zip(feats).map do |pg, f|
      t, p = f[:printed_t], f[:printed_p]
      cand, ev = if t && p && t == p then [t, "both readings"]
                 elsif t && p then [nil, "readings differ (tesseract #{t.join('-')}, text layer #{p.join('-')})"]
                 elsif t then [t, "tesseract reading"]
                 elsif p then [p, "text-layer reading"]
                 else [nil, nil]
                 end
      { pg: pg, f: f, cand: cand, ev: ev, alt: [t, p].compact.uniq }
    end
    # a single-reading value is accepted only when a neighbour confirms it
    # (same group, number difference = PDF page difference)
    confirmed = lambda do |i, val|
      [-3, -2, -1, 1, 2, 3].any? do |d|
        j = i + d
        next false if j.negative? || j >= entries.length
        o = entries[j][:cand]
        o && o[0] == val[0] && o[1] - val[1] == entries[j][:pg][:pdf_page] - entries[i][:pg][:pdf_page]
      end
    end
    entries.each_with_index do |e, i|
      next unless e[:cand]
      e[:ok] = e[:ev] == "both readings" || confirmed.call(i, e[:cand])
    end
    entries.each_with_index do |e, i|
      next if e[:ok]
      # readings that differ: keep the one a neighbour confirms
      if (good = e[:alt].find { |v| confirmed.call(i, v) })
        e[:cand], e[:ok], e[:ev] = good, true, "#{e[:ev] || 'one reading'}; confirmed by neighbouring pages"
        next
      end
      prev = entries[0...i].reverse.find { |x| x[:ok] }
      nxt = entries[(i + 1)..].find { |x| x[:ok] }
      if prev && nxt && prev[:cand][0] == nxt[:cand][0] &&
         nxt[:cand][1] - prev[:cand][1] == nxt[:pg][:pdf_page] - prev[:pg][:pdf_page]
        said = e[:alt].any? ? " (readings said #{e[:alt].map { |v| v.join('-') }.join(' / ')})" : ""
        e[:fill] = [prev[:cand][0], prev[:cand][1] + e[:pg][:pdf_page] - prev[:pg][:pdf_page]]
        e[:ev] = "filled from neighbours#{said}"
      else
        e[:ev] = e[:alt].any? ? "unconfirmed reading #{e[:alt].map { |v| v.join('-') }.join(' / ')}" : "none found"
      end
    end
    # count on from the nearest known page through a run of drawing / list
    # pages (no blank, advert or contents page in between)
    entries.each { |e| e[:type] = page_type(e[:pg], e[:f]) }
    anchors = entries.map { |x| x[:ok] ? x[:cand] : x[:fill] }   # snapshot: count only from these
    known = ->(x) { anchors[entries.index(x)] }
    countable = ->(x) { %w[drawing parts_list].include?(x[:type]) }
    entries.each_with_index do |e, i|
      next if known.call(e) || !countable.call(e)
      guesses = []
      [-1, 1].each do |dir|
        j = i + dir
        while j >= 0 && j < entries.length && countable.call(entries[j])
          if (v = known.call(entries[j]))
            k = v[1] + (i - j)
            guesses << [[v[0], k], entries[j][:pg][:pdf_page]] if k.positive?
            break
          end
          j += dir
        end
      end
      vals = guesses.map(&:first).uniq
      if vals.length == 1
        e[:fill] = vals.first
        e[:ev] = "counted from PDF #{guesses.map(&:last).join(' and ')}" + (e[:alt].any? ? " (readings said #{e[:alt].map { |v| v.join('-') }.join(' / ')})" : "")
      elsif vals.length > 1
        e[:ev] = "conflict: counting gives #{vals.map { |v| v.join('-') }.join(' or ')}"
      end
    end
    entries.each do |e|
      val = e[:ok] ? e[:cand] : e[:fill]
      e[:printed] = val && "#{val[0]}-#{val[1]}"
      e[:group] = val && val[0]
      e[:ill] = e[:f][:ill_p] || e[:f][:ill_t]
      e[:ill_ev] = if e[:f][:ill_t] && e[:f][:ill_p] && e[:f][:ill_t] != e[:f][:ill_p]
                     "readings differ (tesseract #{e[:f][:ill_t]}, text layer #{e[:f][:ill_p]}); text layer kept"
                   elsif e[:f][:ill_t] && e[:f][:ill_p] then "both readings"
                   elsif e[:ill] then e[:f][:ill_p] ? "text-layer reading" : "tesseract reading"
                   end
    end
    # illustration clean-up, before filling:
    #  - a truncated number ("1") is completed from a page within 4 that reads "1+A1"
    #  - a number whose pages are mostly in another main group is dropped
    entries.each_with_index do |e, i|
      next unless e[:ill] && !e[:ill].include?("+")
      near = entries[[i - 4, 0].max..[i + 4, entries.length - 1].min].map { |x| x[:ill] }.compact
      full = near.find { |v| v.start_with?("#{e[:ill]}+") }
      e[:ill], e[:ill_ev] = full, "#{e[:ill_ev]}; read \"#{e[:ill]}\", completed from a neighbouring page" if full
    end
    groups_of = Hash.new { |hh, k| hh[k] = Hash.new(0) }
    entries.each { |e| groups_of[e[:ill]][e[:group]] += 1 if e[:ill] && e[:group] }
    entries.each do |e|
      next unless e[:ill] && e[:group]
      dom = groups_of[e[:ill]].max_by(&:last)&.first
      next if dom.nil? || dom == e[:group]
      e[:ill_ev] = "dropped reading \"#{e[:ill]}\" (that number's pages are mostly in main group #{dom})"
      e[:ill] = nil
    end
    # main group for pages without a printed page: same as both neighbours
    entries.each_with_index do |e, i|
      next if e[:group]
      prev = entries[0...i].reverse.find { |x| x[:group] }
      nxt = entries[(i + 1)..].find { |x| x[:group] }
      e[:group] = prev[:group] if prev && nxt && prev[:group] == nxt[:group]
    end
    # illustration for drawing/list pages without one: neighbours in the same group
    ill_pages = ->(x) { %w[drawing parts_list].include?(x[:type]) }
    entries.each_with_index do |e, i|
      next if e[:ill] || !ill_pages.call(e)
      dropped = e[:ill_ev]
      prev = entries[0...i].reverse.find { |x| x[:ill] && !x[:ill_filled] }
      nxt = entries[(i + 1)..].find { |x| x[:ill] }
      same = ->(x) { x && x[:group] == e[:group] }
      if same.call(prev) && same.call(nxt) && prev[:ill] == nxt[:ill]
        e[:ill], e[:ill_ev] = prev[:ill], "filled: same as the pages before and after"
      elsif e[:type] == "drawing" && same.call(nxt)
        e[:ill], e[:ill_ev] = nxt[:ill], "filled: drawing takes the next page's illustration"
      elsif e[:type] == "parts_list" && same.call(prev)
        e[:ill], e[:ill_ev] = prev[:ill], "filled: list page continues the previous page's illustration"
      end
      e[:ill_filled] = true if e[:ill]
      e[:ill_ev] = "#{dropped}; #{e[:ill_ev]}" if dropped && e[:ill]
    end
    titles = contents_titles(entries)
    entries.map do |e|
      f = e[:f]
      {
        "pdf_page" => e[:pg][:pdf_page],
        "printed_page" => e[:printed],
        "main_group" => e[:group],
        "main_group_title" => e[:group] && MAIN_GROUPS[e[:group]],
        "illustration" => e[:ill],
        "illustration_title" => e[:ill] && titles[e[:ill]],
        "page_type" => e[:type],
        "fold_out" => e[:pg][:w] > e[:pg][:h],
        "image_px" => [e[:pg][:w], e[:pg][:h]],
        "revision_stamp" => f[:stamp_t] || f[:stamp_p],
        "stamp_readings" => { "pdf_text" => f[:stamp_p], "tesseract" => f[:stamp_t] },
        "evidence" => { "printed_page" => e[:ev], "illustration" => e[:ill_ev],
                        "stamp" => if f[:stamp_t] && f[:stamp_p] && f[:stamp_t] != f[:stamp_p] then "readings differ; tesseract kept"
                                   elsif f[:stamp_t] && f[:stamp_p] then "both readings"
                                   elsif f[:stamp_t] || f[:stamp_p] then "one reading"
                                   end },
        "status" => "unverified"
      }
    end
  end

  # Illustration titles from the book's own contents pages: lines that end in
  # an illustration number ("Crankcase, Cylinders, Cylinder heads 1+A1").
  def contents_titles(entries)
    titles = {}
    entries.select { |e| e[:type] == "contents" }.each do |e|
      e[:pg][:tess].each do |l|
        m = l[:text].match(/\A\W*(?:\d{2}\s+)?([A-Z][A-Za-z ,.\-()&]+?)[\s.\-_~»]*\b(\d{1,3}(?:\s*\+\s*A\s*[0-9iIl]{1,2})?)\s*\z/)
        next unless m
        num = m[2].gsub(/\s+/, "").tr("iIl", "111")
        titles[num] ||= m[1].strip.sub(/\s+(ae|a|oe|ee)\z/, "")
      end
    end
    titles
  end

  def illustrations(map)
    map.select { |p| p["illustration"] }.group_by { |p| p["illustration"] }.map do |num, ps|
      {
        "number" => num,
        "slug" => slug(num),
        "main_group" => ps.map { |p| p["main_group"] }.compact.tally.max_by(&:last)&.first,
        "title" => ps.first["illustration_title"],
        "drawing_pdf_pages" => ps.select { |p| p["page_type"] == "drawing" }.map { |p| p["pdf_page"] },
        "list_pdf_pages" => ps.select { |p| p["page_type"] == "parts_list" }.map { |p| p["pdf_page"] },
        "fold_out_drawing" => ps.any? { |p| p["page_type"] == "drawing" && p["fold_out"] },
        "title_source" => ps.first["illustration_title"] ? "book's contents page (tesseract)" : nil
      }
    end
  end

  def slug(num)
    "ill" + num.to_s.downcase.gsub(/[^0-9a-z]/, "")
  end
end
