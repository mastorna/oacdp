#!/usr/bin/env ruby
# A third machine reading, of the footer only. The footer (revision stamp,
# "Illustration N", printed page number) is printed large and bold but sits
# in dark, speckled margins that full-page OCR skips. For each page this
#   1. renders the bottom strip of the page at 300 dpi, 1-bit (pdftoppm),
#   2. keeps only letter-sized ink: connected blobs 14-160 px tall, at most
#      260 px wide, with enough pixels (speckle dots and the large dark
#      smears along the edges are dropped),
#   3. reads the cleaned strip with tesseract (psm 6).
# Output: WORK/footer/footer-NNN.txt (text) and footer-NNN.pbm (cleaned strip).
# Pages already done are skipped. The PDF is only read.
#
#   ruby scripts/parts/footer-readings.rb --pdf ORIGINAL.pdf --work WORK [--pages 25,65] [--jobs 2]
#
# Ruby standard library only (calls the installed pdftoppm and tesseract).

require "optparse"
require "open3"
require "fileutils"

opts = { jobs: 2 }
OptionParser.new do |o|
  o.on("--pdf PATH") { |v| opts[:pdf] = v }
  o.on("--work DIR") { |v| opts[:work] = v }
  o.on("--pages LIST") { |v| opts[:pages] = v.split(",").map(&:to_i) }
  o.on("--jobs N", Integer) { |v| opts[:jobs] = v }
  o.on("--force") { opts[:force] = true }
end.parse!
%i[pdf work].each { |k| abort "missing --#{k}" unless opts[k] }
REPO = File.expand_path("../..", __dir__)
abort "--work must be outside the repository" if File.expand_path(opts[:work]).start_with?(REPO + "/")

DPI = 300
STRIP = 0.13 # bottom share of the page height

module Footer
  module_function

  def page_size_pt(pdf, page)
    out, = Open3.capture2("pdftotext", "-tsv", "-f", page.to_s, "-l", page.to_s, pdf, "-")
    out.each_line do |l|
      c = l.split("\t")
      return [c[8].to_f, c[9].to_f] if c[0] == "1"
    end
    nil
  end

  def read_pbm(path)
    data = File.binread(path)
    m = data.match(/\AP4\s+(?:#[^\n]*\n\s*)*(\d+)\s+(\d+)\s/) or raise "#{path}: not a binary PBM"
    w, h = m[1].to_i, m[2].to_i
    [w, h, data.byteslice(m[0].bytesize, ((w + 7) / 8) * h)]
  end

  # Black runs per row: [[x0, x1], ...]; in PBM a set bit is black.
  def runs(w, h, bits)
    stride = (w + 7) / 8
    Array.new(h) do |y|
      row = bits.byteslice(y * stride, stride).unpack1("B*")[0, w]
      rs = []
      row.scan(/1+/) { rs << [Regexp.last_match.begin(0), Regexp.last_match.end(0) - 1] }
      rs
    end
  end

  # Connected components over runs (union-find), then keep letter-sized ones.
  def clean(w, h, bits)
    rows = runs(w, h, bits)
    ids = []
    parent = []
    find = ->(a) { a = parent[a] while parent[a] != a; a }
    prev = []
    rows.each_with_index do |rs, y|
      cur = rs.map do |x0, x1|
        id = parent.length
        parent << id
        prev.each do |px0, px1, pid|
          next if px1 < x0 - 1 || px0 > x1 + 1
          a, b = find.call(id), find.call(pid)
          parent[a] = b if a != b
        end
        ids << [y, x0, x1, id]
        [x0, x1, id]
      end
      prev = cur
    end
    box = Hash.new { |hh, k| hh[k] = [Float::INFINITY, Float::INFINITY, -1, -1, 0] }
    ids.each do |y, x0, x1, id|
      b = box[find.call(id)]
      b[0] = x0 if x0 < b[0]
      b[1] = y if y < b[1]
      b[2] = x1 if x1 > b[2]
      b[3] = y if y > b[3]
      b[4] += x1 - x0 + 1
    end
    keep = {}
    box.each do |root, (x0, y0, x1, y1, n)|
      bw, bh = x1 - x0 + 1, y1 - y0 + 1
      fill = n.to_f / (bw * bh)
      keep[root] = true if bh.between?(14, 160) && bw <= 260 && n >= 60 && fill.between?(0.12, 0.92)
    end
    stride = (w + 7) / 8
    out = Array.new(h) { "\0".b * stride }
    ids.each do |y, x0, x1, id|
      next unless keep[find.call(id)]
      row = out[y]
      (x0..x1).each { |x| row.setbyte(x >> 3, row.getbyte(x >> 3) | (0x80 >> (x & 7))) }
    end
    # one blank row on top: some PNM readers (leptonica, used by tesseract)
    # skip a first raster byte that looks like whitespace (PDF 668)
    "P4\n#{w} #{h + 1}\n" + ("\0".b * stride) + out.join
  end

  def one(pdf, work, page, force)
    dir = File.join(work, "footer")
    n = format("%03d", page)
    txt = File.join(dir, "footer-#{n}.txt")
    return if File.exist?(txt) && !force
    pw, ph = page_size_pt(pdf, page)
    return File.write(txt, "") unless pw
    wpx, hpx = (pw * DPI / 72).round, (ph * DPI / 72).round
    y = (hpx * (1 - STRIP)).round
    base = File.join(dir, "raw-#{n}")
    _o, e, s = Open3.capture3("pdftoppm", "-r", DPI.to_s, "-mono", "-f", page.to_s, "-l", page.to_s,
                              "-x", "0", "-y", y.to_s, "-W", wpx.to_s, "-H", (hpx - y).to_s, "-singlefile", pdf, base)
    raise "pdftoppm failed on #{page}: #{e}" unless s.success?
    w, h, bits = read_pbm("#{base}.pbm")
    clean_pbm = File.join(dir, "footer-#{n}.pbm")
    File.binwrite(clean_pbm, clean(w, h, bits))
    File.delete("#{base}.pbm")
    out, e, s = Open3.capture3({ "OMP_THREAD_LIMIT" => "1" }, "tesseract", clean_pbm, "-", "--dpi", DPI.to_s, "--psm", "6")
    raise "tesseract failed on #{page}: #{e}" unless s.success?
    File.write(txt, out)
  end
end

FileUtils.mkdir_p(File.join(opts[:work], "footer"))
pages = opts[:pages] || Dir[File.join(opts[:work], "page-*.png")].map { |f| f[/page-(\d+)\.png/, 1].to_i }.sort
queue = Queue.new
pages.each { |p| queue << p }
t0 = Time.now
workers = Array.new(opts[:jobs]) do
  Thread.new do
    # each worker runs its pages in a child process, so the two jobs use both cores
    while (p = (queue.pop(true) rescue nil))
      pid = fork { Footer.one(opts[:pdf], opts[:work], p, opts[:force]); exit!(0) }
      Process.wait(pid)
      warn "page #{p}: footer reading failed" unless $?.success?
    end
  end
end
workers.each(&:join)
puts "footer readings for #{pages.length} pages in #{(Time.now - t0).round} s"
