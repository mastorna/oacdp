#!/usr/bin/env ruby
# Local, dev-only review tool for a parts data file. NEVER part of the
# published site: it lives in dev/, outside Jekyll's source folder (src/).
#
#   bundle exec ruby dev/review/server.rb \
#     --data src/_data/parts/vw-tpl-1963-08/ill32.yml \
#     --images /workspaces/oacdp-notes/data-ill32/work \
#     --reviewer mastorna [--port 4001]
#
# Serves on 127.0.0.1 only. Page images are read from --images (outside the
# repo) and never copied into it. Every save needs the random token the page
# receives when it loads. Saves write the YAML atomically and append a line
# to review-log.txt next to the images folder.

require "webrick"
require "json"
require "optparse"
require "securerandom"
require "time"
require_relative "../../scripts/parts/lib/parts"

opts = { port: 4001 }
OptionParser.new do |o|
  o.on("--data PATH") { |v| opts[:data] = File.expand_path(v) }
  o.on("--images DIR") { |v| opts[:images] = File.expand_path(v) }
  o.on("--reviewer NAME") { |v| opts[:reviewer] = v }
  o.on("--port N", Integer) { |v| opts[:port] = v }
  o.on("--log PATH") { |v| opts[:log] = File.expand_path(v) }
end.parse!
%i[data images reviewer].each { |k| abort "missing --#{k}" unless opts[k] }

REPO = File.expand_path("../..", __dir__)
abort "--images must be outside the repository (page images are never stored in it)" if opts[:images].start_with?(REPO + "/") || opts[:images] == REPO
abort "--data #{opts[:data]} not found" unless File.file?(opts[:data])
abort "--images #{opts[:images]} not found" unless File.directory?(opts[:images])
abort "--reviewer must be a short name without spaces" unless opts[:reviewer].match?(/\A[\w.\-]{1,40}\z/)
opts[:log] ||= File.join(File.dirname(opts[:images]), "review-log.txt")

TOKEN = SecureRandom.hex(16)
LOCK = Mutex.new
HERE = __dir__
EDITABLE = %w[key marker part_no description quantity applicability type_and_model].freeze

def now
  Time.now.utc.iso8601
end

def png_size(path)
  File.binread(path, 24)[16, 8].unpack("NN")
end

# Normalise one edited value from the form into the stored type.
def coerce(field, value)
  v = value.is_a?(String) ? value.gsub("\r\n", "\n").strip : value
  case field
  when "key"
    return nil if v.nil? || v.to_s.strip.empty? || v.to_s.strip == "-"
    Integer(v.to_s.strip, 10)
  when "marker", "type_and_model"
    v.to_s.empty? ? nil : v
  when "quantity"
    parts = v.to_s.split(%r{\s*/\s*|\n}).map(&:strip).reject(&:empty?)
    parts.length > 1 ? parts : parts.first.to_s
  when "applicability"
    v.to_s.empty? ? nil : v
  else
    v.to_s
  end
end

def with_data(opts)
  LOCK.synchronize do
    data = Parts.load(opts[:data])
    result = yield data
    Parts.dump(opts[:data], data)
    result
  end
end

def log_line(opts, text)
  File.open(opts[:log], "a") { |f| f.puts("#{now} #{opts[:reviewer]} #{text}") }
end

def sync_position_status(data)
  data["positions"].each do |p|
    members = data["rows"].select { |r| r["position"] == p["id"] }
    next if members.empty?
    p["status"] = if members.all? { |r| r["position_status"] == "confirmed" } then "confirmed"
                  elsif members.any? { |r| r["position_status"] == "changed" } then "changed"
                  else "suggested"
                  end
  end
end

server = WEBrick::HTTPServer.new(
  BindAddress: "127.0.0.1", Port: opts[:port],
  AccessLog: [], Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN)
)

send_json = lambda do |res, obj, status = 200|
  res.status = status
  res["Content-Type"] = "application/json; charset=utf-8"
  res["Cache-Control"] = "no-store"
  res.body = JSON.generate(obj)
end

# Only accept JSON from our own page with the right token.
guard = lambda do |req, res|
  if req.request_method != "POST"
    send_json.call(res, { error: "POST only" }, 405); next false
  end
  if req["X-Review-Token"] != TOKEN
    send_json.call(res, { error: "missing or wrong review token" }, 403); next false
  end
  if req.body.to_s.bytesize > 100_000
    send_json.call(res, { error: "request too large" }, 413); next false
  end
  true
end

server.mount_proc("/") do |req, res|
  case req.path
  when "/", "/index.html"
    res["Content-Type"] = "text/html; charset=utf-8"
    res["Cache-Control"] = "no-store"
    res.body = File.read(File.join(HERE, "index.html")).sub("__REVIEW_TOKEN__", TOKEN).sub("__REVIEWER__", opts[:reviewer])
  when "/review.js"
    res["Content-Type"] = "text/javascript; charset=utf-8"
    res.body = File.read(File.join(HERE, "review.js"))
  else
    res.status = 404
    res.body = "not found"
  end
end

server.mount_proc("/img") do |req, res|
  name = File.basename(req.path)
  path = File.join(opts[:images], name)
  if name.match?(/\Apage-\d{3}\.png\z/) && File.file?(path)
    res["Content-Type"] = "image/png"
    res["Cache-Control"] = "private, max-age=3600"
    res.body = File.binread(path)
  else
    res.status = 404
    res.body = "not found"
  end
end

server.mount_proc("/api/data") do |_req, res|
  data = LOCK.synchronize { Parts.load(opts[:data]) }
  sizes = data["pages"].to_h { |p| [p["pdf_page"], png_size(File.join(opts[:images], format("page-%03d.png", p["pdf_page"])))] }
  send_json.call(res, data.merge("image_sizes" => sizes, "reviewer" => opts[:reviewer]))
end

# Confirm or correct one row.
# body: { id, action: "confirm"|"correct", fields: {...}, position: "...", note: "..." }
server.mount_proc("/api/row") do |req, res|
  next unless guard.call(req, res)
  body = JSON.parse(req.body)
  begin
    out = with_data(opts) do |data|
      row = data["rows"].find { |r| r["id"] == body["id"] } or raise ArgumentError, "no row #{body['id']}"
      changes = []
      EDITABLE.each do |f|
        next unless body["fields"]&.key?(f)
        new_v = coerce(f, body["fields"][f])
        changes << { "field" => f, "from" => row[f], "to" => new_v } if new_v != row[f]
      end
      if body["action"] == "confirm" && changes.any?
        raise ArgumentError, "fields were edited: use Correct (or undo the edits) — changed: #{changes.map { |c| c['field'] }.join(', ')}"
      end
      if body["action"] == "correct" && changes.empty? && body["position"].to_s == row["position"].to_s
        raise ArgumentError, "nothing changed: use Confirm"
      end
      t = now
      changes.each do |c|
        row[c["field"]] = c["to"]
        row["corrections"] << c.merge("by" => opts[:reviewer], "at" => t, "note" => body["note"].to_s.strip.empty? ? nil : body["note"].to_s.strip)
      end
      Parts.derive!(row) if changes.any?
      # position (addition A): confirming keeps it, editing marks it changed
      new_pos = body["position"].to_s.strip
      new_pos = row["position"].to_s if new_pos.empty?
      raise ArgumentError, "position id must be lower-case words joined by dashes" unless new_pos.match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/)
      if new_pos != row["position"]
        unless data["positions"].any? { |p| p["id"] == new_pos }
          data["positions"] << { "id" => new_pos, "label" => body["position_label"].to_s.strip.empty? ? new_pos.tr("-", " ") : body["position_label"].to_s.strip,
                                 "key" => nil, "status" => "changed" }
        end
        (row["position_history"] ||= []) << { "from" => row["position"], "to" => new_pos, "by" => opts[:reviewer], "at" => t }
        row["position"] = new_pos
        row["position_status"] = "changed"
      elsif row["position_status"] == "suggested"
        row["position_status"] = "confirmed"
      end
      row["status"] = row["corrections"].any? ? "corrected" : "verified"
      row["reviewed_by"] = opts[:reviewer]
      row["reviewed_at"] = t
      sync_position_status(data)
      log_line(opts, "#{body['action']} #{row['id']} #{changes.map { |c| "#{c['field']}: #{c['from'].inspect} -> #{c['to'].inspect}" }.join('; ')} position=#{row['position']}")
      row
    end
    send_json.call(res, { ok: true, row: out })
  rescue ArgumentError, JSON::ParserError => e
    send_json.call(res, { error: e.message }, 422)
  end
end

# Confirm or move one callout. body: { id, action: "confirm"|"correct", page_px: [x, y], note }
server.mount_proc("/api/callout") do |req, res|
  next unless guard.call(req, res)
  body = JSON.parse(req.body)
  begin
    out = with_data(opts) do |data|
      c = data["callouts"].find { |x| x["id"] == body["id"] } or raise ArgumentError, "no callout #{body['id']}"
      t = now
      if body["action"] == "correct"
        px = body["page_px"].map { |v| Integer(v.round) }
        raise ArgumentError, "position unchanged: use Confirm" if px == c["page_px"]
        w, h = png_size(File.join(opts[:images], format("page-%03d.png", data.dig("illustration", "drawing", "pdf_page"))))
        c["corrections"] << { "field" => "page_px", "from" => c["page_px"], "to" => px, "by" => opts[:reviewer], "at" => t, "note" => body["note"] }
        c["page_px"] = px
        c["page_frac"] = [(px[0].to_f / w).round(4), (px[1].to_f / h).round(4)]
      end
      c["status"] = c["corrections"].any? ? "corrected" : "verified"
      c["reviewed_by"] = opts[:reviewer]
      c["reviewed_at"] = t
      log_line(opts, "#{body['action']} callout #{c['id']} #{c['page_px'].inspect}")
      c
    end
    send_json.call(res, { ok: true, callout: out })
  rescue ArgumentError, JSON::ParserError, TypeError, NoMethodError => e
    send_json.call(res, { error: e.message }, 422)
  end
end

# Confirm or correct a page's revision stamp. body: { pdf_page, action, revision_stamp, note }
server.mount_proc("/api/page") do |req, res|
  next unless guard.call(req, res)
  body = JSON.parse(req.body)
  begin
    out = with_data(opts) do |data|
      p = data["pages"].find { |x| x["pdf_page"] == body["pdf_page"].to_i } or raise ArgumentError, "no page #{body['pdf_page']}"
      t = now
      if body["action"] == "correct"
        v = body["revision_stamp"].to_s.strip
        v = nil if v.empty?
        raise ArgumentError, "stamp unchanged: use Confirm" if v == p["revision_stamp"]
        p["corrections"] << { "field" => "revision_stamp", "from" => p["revision_stamp"], "to" => v, "by" => opts[:reviewer], "at" => t, "note" => body["note"] }
        p["revision_stamp"] = v
      end
      p["stamp_status"] = p["corrections"].any? ? "corrected" : "verified"
      p["reviewed_by"] = opts[:reviewer]
      p["reviewed_at"] = t
      log_line(opts, "#{body['action']} stamp PDF #{p['pdf_page']} #{p['revision_stamp'].inspect}")
      p
    end
    send_json.call(res, { ok: true, page: out })
  rescue ArgumentError, JSON::ParserError => e
    send_json.call(res, { error: e.message }, 422)
  end
end

trap("INT") { server.shutdown }
trap("TERM") { server.shutdown }
puts "Review tool for #{opts[:data].sub(REPO + '/', '')}"
puts "Reviewer: #{opts[:reviewer]}. Open http://127.0.0.1:#{opts[:port]}/ (in Codespaces: PORTS tab, port #{opts[:port]})."
puts "Press Ctrl+C to stop. Saves go straight to the data file; check them with: ruby scripts/check-parts.rb #{opts[:data].sub(REPO + '/', '')}"
server.start
