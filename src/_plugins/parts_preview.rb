# Parts preview (local only). Does NOTHING unless the site config has
# `parts_preview: true`, which only _config.preview.yml sets, so the normal
# site build is unchanged.
#
# In preview mode it builds, from data outside the repository:
#   parts/index.html          table of contents (main groups -> illustrations)
#   parts/<slug>.html         one page per illustration (e.g. parts/ill32.html)
#   parts/unmatched-<g>.html  list pages not yet matched to an illustration
#   parts/search.html         part-number search (loads parts/search-index.json)
#   parts/assets/*            CSS/JS from src/_parts_assets/
#   parts/scans/page-NNN.png  the scan images used (copied into the output only)
#
# Build:  scripts/parts/preview.sh   (see _config.preview.yml)
# Every value shown is an unverified machine (or AI) reading.

require "json"
require "yaml"
require "date"

module PartsPreview
  # A file copied from anywhere into the output at a chosen path.
  class CopiedFile < Jekyll::StaticFile
    def initialize(site, src_path, dest_rel)
      @src_path = src_path
      @dest_rel = dest_rel
      super(site, site.source, File.dirname(dest_rel), File.basename(dest_rel))
    end

    def path
      @src_path
    end

    def destination(dest)
      File.join(dest, @dest_rel)
    end
  end

  module_function

  def load_yaml(path)
    YAML.safe_load_file(path, permitted_classes: [Date, Time], aliases: false)
  end

  # Safe to put inside <script type="application/json">.
  def json(obj)
    JSON.generate(obj).gsub("</", "<\\/")
  end

  def num_sort(label)
    m = label.to_s.match(/\A(\d+)(.*)\z/)
    m ? [m[1].to_i, m[2]] : [9999, label.to_s]
  end

  def seq_of(v)
    v.is_a?(Hash) ? v["seq"] : nil
  end

  # The compact row the page script uses (and Liquid renders without JS).
  def row_for_page(r, source)
    ranges = if r["chassis_ranges"]
               r["chassis_ranges"].map { |cr| { "f" => seq_of(cr["chassis_from"]), "t" => seq_of(cr["chassis_to"]), "q" => cr["quantity"], "txt" => cr["text"] } }
             else
               [{ "f" => seq_of(r["chassis_from"]), "t" => seq_of(r["chassis_to"]) }]
             end
    appl = r["applicability"].to_s
    {
      "id" => r["id"], "key" => r["key"], "kp" => r["key_prefix"], "mk" => r["marker"],
      "pn" => r["part_no"], "pnn" => r["part_no_norm"], "d" => r["description"],
      "q" => r["quantity"].is_a?(Array) ? r["quantity"].join(" / ") : r["quantity"].to_s,
      "a" => r["applicability"], "tm" => r["type_and_model"], "oc" => r["option_codes"] || [],
      "pos" => r["position"], "pdf" => r["pdf_page"], "pp" => r["printed_page"],
      "ranges" => ranges,
      # printed ranges the machine could not turn into numbers (9-digit, garbled)
      "unparsed" => (appl.match?(/Chassis/i) && ranges.all? { |x| x["f"].nil? && x["t"].nil? }) ||
                    [r["chassis_from"], r["chassis_to"]].compact.any? { |v| v["seq"].nil? },
      "engine" => appl.match?(/Engine\s*No/i),
      "conf" => source == :ai ? "ai" : (r["confidence"] == "readings agree" ? "agree" : "check"),
      "why" => r["confidence_reasons"] || []
    }
  end

  class Generator < Jekyll::Generator
    safe true
    priority :high

    def generate(site)
      return unless site.config["parts_preview"]
      cfg = site.config["parts_preview_paths"] || {}
      repo = File.expand_path("..", site.source)
      path = ->(k) { File.expand_path(cfg.fetch(k), repo) }
      pm = PartsPreview.load_yaml(path.call("page_map"))
      yaml_dir = path.call("yaml_dir")
      work = path.call("work_dir")
      ill32 = PartsPreview.load_yaml(path.call("ill32"))
      pages = pm["pages"].to_h { |p| [p["pdf_page"], p] }
      groups = pm["main_groups"]
      edition = "VW Transporter Parts List 1960–1967 (August 1963)"

      used_scans = {}
      scan_url = lambda do |n|
        used_scans[n] = true
        format("scans/page-%03d.png", n)
      end
      page_info = lambda do |n|
        p = pages[n]
        { "pdf" => n, "label" => p["printed_page"] || "PDF #{n}", "type" => p["page_type"],
          "fold_out" => p["fold_out"], "w" => p["image_px"][0], "h" => p["image_px"][1],
          "img" => scan_url.call(n) }
      end

      ills = pm["illustrations"].sort_by { |i| [groups.index { |g| g["id"] == i["main_group"] } || 99, PartsPreview.num_sort(i["number"])] }
      summaries = []
      ills.each do |i|
        slug = i["slug"]
        ai = i["number"] == "32"
        file = File.join(yaml_dir, "#{slug}.yml")
        data = ai ? ill32 : (File.exist?(file) ? PartsPreview.load_yaml(file) : { "rows" => [], "positions" => [] })
        rows = data["rows"].map { |r| PartsPreview.row_for_page(r, ai ? :ai : :machine) }
        positions = (data["positions"] || []).to_h { |p| [p["id"], p["label"]] }
        # Illustration 32 (ai): the drawing with callouts is PDF 341
        drawing = ai ? [ill32.dig("illustration", "drawing", "pdf_page")] | i["drawing_pdf_pages"] : i["drawing_pdf_pages"]
        stage_pages = (drawing + i["list_pdf_pages"]).uniq.select { |n| pages[n] }.map { |n| page_info.call(n) }
        markers = ai ? (ill32["callouts"] || []).map { |c| { "key" => c["key"], "x" => c["page_frac"][0], "y" => c["page_frac"][1], "pdf" => ill32.dig("illustration", "drawing", "pdf_page") } } : []
        group = groups.find { |g| g["id"] == i["main_group"] }
        agree = rows.count { |r| r["conf"] == "agree" }
        summary = {
          "slug" => slug, "number" => i["number"], "title" => i["title"], "group" => i["main_group"],
          "group_title" => group && group["title"], "rows" => rows.length, "agree" => agree,
          "drawings" => drawing.length, "lists" => i["list_pdf_pages"].length,
          "fold_out" => i["fold_out_drawing"], "source" => ai ? "ai" : "machine"
        }
        summaries << summary
        footer_pages = (i["footer_says_this_illustration"] || []).map do |n|
          p = pages[n]
          { "pdf" => n, "label" => p["printed_page"] || "PDF #{n}", "filed_under" => p["illustration"], "filed_slug" => p["illustration"] && "ill#{p['illustration'].downcase.gsub(/[^0-9a-z]/, '')}" }
        end
        pg = Jekyll::PageWithoutAFile.new(site, site.source, "parts", "#{slug}.html")
        pg.data.merge!(
          "layout" => "parts", "parts_kind" => "illustration", "title" => "Illustration #{i['number']}: #{i['title'] || 'untitled'}",
          "ill" => summary, "rows" => rows, "stage_pages" => stage_pages, "markers" => markers,
          "notes" => i["notes"] || [], "footer_pages" => footer_pages,
          "positions" => positions, "groups" => groups, "edition" => edition,
          "parts_json" => PartsPreview.json("rows" => rows, "pages" => stage_pages, "markers" => markers, "positions" => positions,
                                            "source" => summary["source"])
        )
        site.pages << pg
      end

      # list pages not yet matched to an illustration, per main group
      unmatched = []
      Dir[File.join(yaml_dir, "ill-unknown-*.yml")].sort.each do |f|
        data = PartsPreview.load_yaml(f)
        g = File.basename(f, ".yml").sub("ill-unknown-", "").upcase
        g = nil if g == "X"
        rows = data["rows"].map { |r| PartsPreview.row_for_page(r, :machine) }
        next if rows.empty?
        slug = "unmatched-#{(g || 'x').downcase}"
        stage_pages = rows.map { |r| r["pdf"] }.uniq.map { |n| page_info.call(n) }
        group = groups.find { |gg| gg["id"] == g }
        summary = { "slug" => slug, "number" => nil, "title" => "Pages not yet matched to an illustration", "group" => g,
                    "group_title" => group && group["title"], "rows" => rows.length, "agree" => rows.count { |r| r["conf"] == "agree" },
                    "drawings" => 0, "lists" => stage_pages.length, "source" => "machine" }
        unmatched << summary
        pg = Jekyll::PageWithoutAFile.new(site, site.source, "parts", "#{slug}.html")
        pg.data.merge!(
          "layout" => "parts", "parts_kind" => "illustration", "title" => "#{group ? "Main group #{g}" : 'Unknown group'}: pages not yet matched",
          "ill" => summary, "rows" => rows, "stage_pages" => stage_pages, "markers" => [], "notes" => [], "footer_pages" => [],
          "positions" => {}, "groups" => groups, "edition" => edition,
          "parts_json" => PartsPreview.json("rows" => rows, "pages" => stage_pages, "markers" => [], "positions" => {}, "source" => "machine")
        )
        site.pages << pg
      end

      home = Jekyll::PageWithoutAFile.new(site, site.source, "parts", "index.html")
      home.data.merge!(
        "layout" => "parts", "parts_kind" => "home", "title" => "Parts", "groups" => groups, "edition" => edition,
        "toc" => groups.map { |g| { "id" => g["id"], "title" => g["title"], "ills" => summaries.select { |s| s["group"] == g["id"] }, "unmatched" => unmatched.select { |u| u["group"] == g["id"] } } },
        "totals" => { "ills" => summaries.length, "rows" => (summaries + unmatched).sum { |s| s["rows"] }, "agree" => (summaries + unmatched).sum { |s| s["agree"] } },
        "unmatched_nogroup" => unmatched.select { |u| u["group"].nil? }
      )
      site.pages << home

      search = Jekyll::PageWithoutAFile.new(site, site.source, "parts", "search.html")
      search.data.merge!("layout" => "parts", "parts_kind" => "search", "title" => "Search parts", "groups" => groups, "edition" => edition,
                         "slug_of" => PartsPreview.json(summaries.to_h { |s| [s["number"], { "slug" => s["slug"], "title" => s["title"] }] }))
      site.pages << search

      # front-end files, the search index and the scans used: output only
      Dir[File.join(site.source, "_parts_assets", "*")].each do |f|
        site.static_files << CopiedFile.new(site, f, File.join("parts", "assets", File.basename(f)))
      end
      site.static_files << CopiedFile.new(site, path.call("search_index"), "parts/search-index.json")
      used_scans.keys.sort.each do |n|
        src = File.join(work, format("page-%03d.png", n))
        site.static_files << CopiedFile.new(site, src, File.join("parts", format("scans/page-%03d.png", n))) if File.exist?(src)
      end
      Jekyll.logger.info "Parts preview:", "#{summaries.length} illustrations, #{unmatched.length} unmatched groups, #{used_scans.length} scans"
    end
  end
end
