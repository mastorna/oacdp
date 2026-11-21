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

  PRINTED_RE = /\A[\W_]*(ST|SP|S|L|[0-9])\s*[-–—~=]\s*(\d{1,3})([ab])?[\W_]*\z/
  # the same, found anywhere in a footer line ("S ~22a", "1-124 a", "8-50")
  PRINTED_IN_LINE_RE = /(?<![\w])(ST|SP|S|L|[0-9])\s?[-–—~=]\s?(\d{1,3})(?:\s?([ab]))?(?![\w])/
  STAMP_RE = /T[yvj]p\.?\s*2\s*(\d{1,2})\s*[\/l1|]\s*(\d{2})\b/i
  # "Illustration 32" as OCR reads it: "Nlustration", "iljustration", "IUus.tr~tion", "tation 2" ...
  # The full label is kept: "32", "22a", "33+A33", "38+A38+B38+C38".
  ILL_RE = /(?:ust|us\.t|stra|tion)[a-z~.]*\.?\s{0,3}((?:\d{1,3}|(?<=\s)[tlI](?![a-z]))(?:[ab](?![a-z])|\s[ab](?=\s+(?:ST|SP|S|L|\d)\s?[-–—~=]\s?\d))?(?:\s*[+4]\s*[A-D]\s*[0-9lIi]{1,3}(?:[ab](?![a-z])|\s[ab](?=\s+(?:ST|SP|S|L|\d)\s?[-–—~=]\s?\d))?)*)(?![0-9])/
  # A line of a main-group contents page: "17   Differential ......   31"
  CONTENTS_LINE_RE = /\A\W{0,3}(\d{2})\s+([A-Z][^\d]*?[a-z][^\d]*?)[\s.·•,_~-]*\s(\d{1,3}[a-z]?(?:\s*\+\s*[A-D]\s*\d{1,3}[a-z]?)*)\s*\z/
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
      v = m[1].gsub(/\s+/, "")
      v = v.sub(/\A[tlI]/, "1").gsub(/(?<=[A-D])[lIi]/, "1")
      v = v.gsub(/(?<=\d)4(?=[A-D])/, "+")   # "14A1" is "1+A1" with "+" read as "4"
      return v
    end
    nil
  end

  # [group, number, suffix] of the rightmost page number in the footer lines;
  # suffix is "" or the letter of an inserted page ("1-50a").
  def printed(lines, w)
    cands = []
    lines.each do |l|
      l[:text].scan(PRINTED_IN_LINE_RE) { cands << [$1, $2.to_i, $3.to_s, Regexp.last_match.begin(0), l[:x1]] }
    end
    best = cands.max_by { |_g, _k, _s, pos, x1| [x1, pos] }  # printed at the outer (right) edge
    best && best[0, 3]
  end

  def pstr(v)
    v && "#{v[0]}-#{v[1]}#{v[2]}"
  end

  # First and last key on a page: the longest rising run of keys in each
  # reading (stray misread keys drop out), from the reading with the longer
  # run. nil when that run has fewer than 3 keys.
  def key_range(pg)
    run = [pg[:tess], pg[:pdf]].map do |ls|
      longest_rising(ls.select { |l| Readings.item_line?(l) }.filter_map { |l| Readings.parse_item(l[:text])["key"]&.to_i })
    end.max_by(&:length)
    run.length >= 3 ? [run.first, run.last] : nil
  end

  def longest_rising(a)
    best = []
    tails = [] # tails[i] = [value, sequence] of the best rising run of length i+1
    a.each do |x|
      i = tails.index { |v, _| v >= x } || tails.length
      seq = (i.zero? ? [] : tails[i - 1][1]) + [x]
      tails[i] = [x, seq]
      best = seq if seq.length > best.length
    end
    best
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
      contents_lines: [pg[:tess], pg[:pdf]].map { |ls| ls.count { |l| l[:text].match?(CONTENTS_LINE_RE) } }.max,
      keys: key_range(pg),
      sp_set: upper_text.match?(/\bSP\s*SETS?\b/i) && !head_text.match?(/\bKey\b/)
    }
  end

  def page_type(pg, f)
    parts = [f[:parts_t], f[:parts_p]].max
    items = [f[:items_t], f[:items_p]].max
    return "other" if pg[:pdf_page] <= 15
    return "index" if parts >= 3 && f[:head].match?(/\bPage\b/) && !f[:head].match?(/Quan|tity/i)
    return "contents" if f[:contents_lines] >= 3 && parts < 3
    if pg[:w] > pg[:h]
      # fold-out: the text layer is rotated against the image and reads a
      # sideways drawing's callout numbers as list text, so only tesseract counts
      return "parts_list" if f[:parts_t] >= 3 || f[:items_t] >= 4
      return "drawing" if f[:digit_labels] >= 4 || pg[:ink] > 0.05
      return "other"
    end
    return "parts_list" if parts >= 3 || items >= 4
    return "contents" if f[:upper].match?(/ustration/i) && f[:contents_lines] >= 2 && f[:digit_labels] < 6
    return "drawing" if f[:digit_labels] >= 4 || (pg[:ink] > 0.05 && f[:words] < 60)
    "other"
  end

  # ---- page map with sequence repair ------------------------------------------------
  # Printed page values are [group, number, suffix]; suffix "" or "a"/"b" for
  # an inserted page ("1-50a"). Counting from page to page uses only pages that
  # are not inserted; inserted blocks are found from key numbers that rewind.
  def page_map(pages)
    feats = pages.map { |pg| features(pg) }
    entries = pages.zip(feats).map do |pg, f|
      t, p = f[:printed_t], f[:printed_p]
      cand, ev = if t && p && t == p then [t, "both readings"]
                 elsif t && p then [nil, "readings differ (tesseract #{pstr(t)}, text layer #{pstr(p)})"]
                 elsif t then [t, "tesseract reading"]
                 elsif p then [p, "text-layer reading"]
                 else [nil, nil]
                 end
      { pg: pg, f: f, cand: cand, ev: ev, alt: [t, p].compact.uniq, type: page_type(pg, f) }
    end
    n = entries.length
    pdf = ->(i) { entries[i][:pg][:pdf_page] }

    # -- inserted blocks and key boundaries (fixes 1 and 2) --
    # A boundary between i-1 and i: the keys rewind (a new illustration or an
    # inserted page). An inserted block: pages s..j-1 whose keys don't fit,
    # where page j continues the keys of page s-1 (PDF 64 -> 65-66 -> 67).
    keys = ->(i) { entries[i][:type] == "parts_list" ? entries[i][:f][:keys] : nil }
    boundary = {}
    (1...n).each do |j|
      a, b = keys.call(j - 1), keys.call(j)
      boundary[j] = true if a && b && b[0] < a[1] - 2
    end
    boundary.keys.each do |j|
      kj = keys.call(j)
      (1..6).each do |len|
        s0 = j - len
        break if s0 < 1
        before = keys.call(s0 - 1)
        block = (s0...j).map { |i| keys.call(i) }
        next unless before && before[1] <= kj[0] + 1 && block.compact.any? && block.compact.all? { |k| k[0] > kj[0] }
        (s0...j).each { |i| entries[i][:inserted] = "keys #{block.compact.map { |k| k.join('-') }.join(', ')} between PDF #{pdf.call(s0 - 1)} (keys to #{before[1]}) and PDF #{pdf.call(j)} (keys from #{kj[0]})" }
        boundary[s0] = true
        break
      end
    end
    entries.each { |e| e[:inserted] ||= "printed page has a letter" if e[:cand] && e[:cand][2] != "" }

    # -- accept a reading's page number only when a neighbour confirms it --
    plain = ->(v) { v && v[2] == "" }
    confirmed = lambda do |i, val|
      [-3, -2, -1, 1, 2, 3].any? do |d|
        j = i + d
        next false if j.negative? || j >= n
        o = entries[j][:cand]
        next false unless o && o[0] == val[0]
        if plain.call(val) && plain.call(o)
          o[1] - val[1] == pdf.call(j) - pdf.call(i)
        elsif d.abs == 1
          # suffix pages: "1-50" -> "1-50a" -> "1-50b" -> "1-51"
          lo, hi = d.negative? ? [o, val] : [val, o]
          (hi[2] != "" && hi[1] == lo[1] && hi[2] > lo[2]) || (hi[2] == "" && hi[1] == lo[1] + 1)
        else
          false
        end
      end
    end
    entries.each_with_index { |e, i| e[:ok] = e[:cand] && (e[:ev] == "both readings" || confirmed.call(i, e[:cand])) }
    entries.each_with_index do |e, i|
      next if e[:ok]
      if (good = e[:alt].find { |v| confirmed.call(i, v) })
        e[:cand], e[:ok], e[:ev] = good, true, "#{e[:ev] || 'one reading'}; confirmed by neighbouring pages"
        next
      end
      e[:ev] = e[:alt].any? ? "unconfirmed reading #{e[:alt].map { |v| pstr(v) }.join(' / ')}" : "none found"
    end

    # -- fill and count from accepted readings, never through inserted pages --
    # fold-outs count as one numbered page each (PDF 19, 21, 42: counting through them gives PDF 33 = 1-19, as printed)
    countable = ->(i) { %w[drawing parts_list contents].include?(entries[i][:type]) && !entries[i][:inserted] }
    # inserted pages take no number in the count but can be passed over
    passable = ->(i) { entries[i][:inserted] && %w[drawing parts_list].include?(entries[i][:type]) }
    anchors = entries.map { |x| x[:ok] ? x[:cand] : nil }
    said = ->(e) { e[:alt].any? ? " (readings said #{e[:alt].map { |v| pstr(v) }.join(' / ')})" : "" }
    entries.each_with_index do |e, i|
      next if anchors[i] || !countable.call(i)
      guesses = []
      [-1, 1].each do |dir|
        j = i + dir
        steps = 1 # numbered pages from i to j, inserted pages not counted
        while j >= 0 && j < n
          if (v = anchors[j]) && !entries[j][:inserted]
            d = dir.negative? ? steps : -steps   # i - j in numbered pages
            k = if v[2] == "" then v[1] + d
                elsif dir.negative? then v[1] + d          # after "1-50a": 1-51, 1-52 ...
                else v[1] + d + 1                          # before "1-50a": 1-50, 1-49 ...
                end
            guesses << [[v[0], k, ""], pdf.call(j)] if k.positive?
            break
          end
          if passable.call(j)
            j += dir
            next
          end
          break unless countable.call(j)
          steps += 1
          j += dir
        end
      end
      vals = guesses.map(&:first).uniq
      if vals.length == 1
        e[:fill] = vals.first
        e[:ev] = (guesses.length == 2 ? "filled between PDF #{guesses.map(&:last).join(' and ')}" : "counted from PDF #{guesses.first.last}") + said.call(e)
      elsif vals.length > 1
        e[:ev] = "conflict: counting gives #{vals.map { |v| pstr(v) }.join(' or ')}"
      end
    end
    entries.each { |e| e[:val] = e[:ok] ? e[:cand] : e[:fill] }

    # -- clashes: a number on two PDF pages; drop the filled/counted ones --
    entries.group_by { |e| pstr(e[:val]) }.each do |v, es|
      next if v.nil? || es.length < 2
      read = es.select { |e| e[:ok] }
      guessed = es.reject { |e| e[:ok] }
      (read.any? ? guessed : es).each do |e|
        others = (es - [e]).map { |x| pdf.call(entries.index(x)) }
        e[:ev] = "dropped #{v}: also given to PDF #{others.join(', ')} (#{e[:ev]})"
        e[:val] = nil
      end
    end

    entries.each do |e|
      e[:printed] = pstr(e[:val])
      e[:group] = e[:val] && e[:val][0]
      tl, pl = e[:f][:ill_t], e[:f][:ill_p]
      e[:ill] = pl || tl
      e[:ill_ev] = if tl && pl && tl != pl then "readings differ (tesseract #{tl}, text layer #{pl}); text layer kept"
                   elsif tl && pl then "both readings"
                   elsif e[:ill] then pl ? "text-layer reading" : "tesseract reading"
                   end
    end
    # illustration clean-up, before filling:
    #  - a shortened label ("1", "38+A38") is completed from a page within 4
    #    that reads the longer label ("1+A1", "38+A38+B38+C38")
    #  - a number whose pages are mostly in another main group is dropped
    entries.each_with_index do |e, i|
      next unless e[:ill]
      near = entries[[i - 4, 0].max..[i + 4, n - 1].min].map { |x| x[:ill] }.compact
      full = near.select { |v| v.start_with?("#{e[:ill]}+") }.max_by(&:length)
      e[:ill], e[:ill_ev] = full, "#{e[:ill_ev]}; read \"#{e[:ill]}\", completed from a neighbouring page" if full
    end
    # main group for pages without a printed page: same as both neighbours
    entries.each_with_index do |e, i|
      next if e[:group]
      prev = entries[0...i].reverse.find { |x| x[:group] }
      nxt = entries[(i + 1)..].find { |x| x[:group] }
      e[:group] = prev[:group] if prev && nxt && prev[:group] == nxt[:group]
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
    # illustration for drawing/list pages without one: from neighbours in the
    # same group, never across a key boundary, an inserted page or an SP-set page
    ill_page = ->(x) { %w[drawing parts_list].include?(x[:type]) && !x[:f][:sp_set] }
    path_clear = lambda do |a, b| # pages a < b
      (a + 1..b).none? { |k| boundary[k] } && (a..b).all? { |k| !!entries[k][:inserted] == !!entries[a][:inserted] && !entries[k][:f][:sp_set] }
    end
    entries.each_with_index do |e, i|
      next if e[:ill] || !ill_page.call(e)
      dropped = e[:ill_ev]
      pi = (0...i).to_a.reverse.find { |j| entries[j][:ill] && !entries[j][:ill_filled] }
      ni = ((i + 1)...n).find { |j| entries[j][:ill] }
      ok_prev = pi && entries[pi][:group] == e[:group] && path_clear.call(pi, i)
      ok_next = ni && entries[ni][:group] == e[:group] && path_clear.call(i, ni)
      if ok_prev && ok_next && entries[pi][:ill] == entries[ni][:ill]
        e[:ill], e[:ill_ev] = entries[pi][:ill], "filled: same as the pages before and after"
      elsif e[:type] == "drawing" && ok_next
        e[:ill], e[:ill_ev] = entries[ni][:ill], "filled: drawing takes the next page's illustration"
      elsif e[:type] == "parts_list" && ok_prev
        e[:ill], e[:ill_ev] = entries[pi][:ill], "filled: list page continues the previous page's illustration"
      elsif e[:type] == "parts_list" && ok_next
        e[:ill], e[:ill_ev] = entries[ni][:ill], "filled: keys continue into the next page's illustration"
      else
        e[:ill_ev] = "not filled: #{e[:inserted] ? "inserted page (#{e[:inserted]})" : 'a key boundary or inserted page separates it from its neighbours'}"
      end
      e[:ill_filled] = true if e[:ill]
      e[:ill_ev] = "#{dropped}; #{e[:ill_ev]}" if dropped
    end
    titles = contents_titles(entries)
    entries.map do |e|
      f = e[:f]
      t = e[:ill] && titles[e[:ill]]
      {
        "pdf_page" => e[:pg][:pdf_page],
        "printed_page" => e[:printed],
        "main_group" => e[:group],
        "main_group_title" => e[:group] && MAIN_GROUPS[e[:group]],
        "illustration" => e[:ill],
        "illustration_title" => t && t[:title],
        "page_type" => e[:type],
        "layout" => f[:sp_set] ? "sp_set" : nil,
        "inserted" => e[:inserted] ? true : false,
        "fold_out" => e[:pg][:w] > e[:pg][:h],
        "image_px" => [e[:pg][:w], e[:pg][:h]],
        "keys_first_last" => f[:keys],
        "revision_stamp" => f[:stamp_t] || f[:stamp_p],
        "stamp_readings" => { "pdf_text" => f[:stamp_p], "tesseract" => f[:stamp_t] },
        "evidence" => { "printed_page" => e[:ev], "illustration" => e[:ill_ev], "inserted" => e[:inserted],
                        "illustration_title" => t && "contents page PDF #{t[:pdf]}",
                        "stamp" => if f[:stamp_t] && f[:stamp_p] && f[:stamp_t] != f[:stamp_p] then "readings differ; tesseract kept"
                                   elsif f[:stamp_t] && f[:stamp_p] then "both readings"
                                   elsif f[:stamp_t] || f[:stamp_p] then "one reading"
                                   end },
        "status" => "unverified"
      }
    end
  end

  # Illustration titles from the book's own contents pages (fix 5). Lines read
  # "17   Differential   31"; a continuation line ("from Chassis No. ...") is
  # added to the line above; several sub-groups with the same illustration are
  # joined with "; ". The text layer is tried first, then tesseract.
  def contents_titles(entries)
    titles = {}
    entries.select { |e| e[:type] == "contents" }.each do |e|
      found = {}
      [e[:pg][:pdf], e[:pg][:tess]].each do |ls|
        last = nil
        ls.sort_by { |l| l[:y0] }.each do |l|
          t = l[:text].strip
          if (m = t.match(CONTENTS_LINE_RE))
            num = m[3].gsub(/\s+/, "")
            title = m[2].strip.sub(/[\s.·•,_~-]+\z/, "")
            last = (found[num] ||= [])
            last << title unless last.include?(title)
          elsif last && t.match?(/\A(from|up to)\b/i) && last.any?
            last[-1] = "#{last[-1]} #{t}" unless last[-1].include?(t)
          else
            last = nil
          end
        end
        break if found.any?
      end
      found.each { |num, ts| titles[num] ||= { title: ts.join("; "), pdf: e[:pg][:pdf_page] } }
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
        "title_source" => ps.first.dig("evidence", "illustration_title"),
        "inserted_pages" => ps.select { |p| p["inserted"] }.map { |p| p["pdf_page"] }
      }
    end
  end

  def slug(num)
    "ill" + num.to_s.downcase.gsub(/[^0-9a-z]/, "")
  end
end
