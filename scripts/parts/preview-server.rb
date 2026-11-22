#!/usr/bin/env ruby
# Local server for the parts preview: serves the built preview (static files)
# and saves "report a problem" notes from its pages.
#
#   ruby scripts/parts/preview-server.rb --root /workspaces/oacdp-notes/parts-preview/site \
#        [--reports data/parts/vw-tpl-1963-08/qa-reports.jsonl] [--reviewer NAME] [--port 4002]
#
# Listens on 127.0.0.1 only. Reports are appended, one JSON object per line,
# to the reports file (in the repository, so they can be committed). A save
# needs the token the page gets from /api/token; other sites cannot read it.
# Ruby standard library + WEBrick (already installed with Jekyll).

require "webrick"
require "json"
require "optparse"
require "securerandom"
require "time"

opts = { port: 4002, reviewer: "owner", reports: File.expand_path("../../data/parts/vw-tpl-1963-08/qa-reports.jsonl", __dir__) }
OptionParser.new do |o|
  o.on("--root DIR") { |v| opts[:root] = File.expand_path(v) }
  o.on("--reports PATH") { |v| opts[:reports] = File.expand_path(v) }
  o.on("--reviewer NAME") { |v| opts[:reviewer] = v }
  o.on("--port N", Integer) { |v| opts[:port] = v }
end.parse!
abort "missing --root" unless opts[:root] && File.directory?(opts[:root])
abort "--reviewer must be a short name without spaces" unless opts[:reviewer].match?(/\A[\w.\-]{1,40}\z/)

TOKEN = SecureRandom.hex(16)
LOCK = Mutex.new
ROW_PROBLEMS = %w[part_no description quantity applicability key extra_or_split other].freeze
PAGE_PROBLEMS = %w[rows_missing wrong_illustration wrong_page_number scan_problem other].freeze

def short(v, max)
  v.nil? ? nil : v.to_s.strip[0, max]
end

server = WEBrick::HTTPServer.new(BindAddress: "127.0.0.1", Port: opts[:port], DocumentRoot: opts[:root],
                                 AccessLog: [], Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN))
send_json = lambda do |res, obj, status = 200|
  res.status = status
  res["Content-Type"] = "application/json; charset=utf-8"
  res["Cache-Control"] = "no-store"
  res.body = JSON.generate(obj)
end

server.mount_proc("/api/token") { |_req, res| send_json.call(res, { token: TOKEN, reviewer: opts[:reviewer] }) }

# reports for one page (to mark reported rows), newest last
server.mount_proc("/api/reports") do |req, res|
  slug = req.query["illustration"].to_s
  list = File.exist?(opts[:reports]) ? File.readlines(opts[:reports]).filter_map { |l| JSON.parse(l) rescue nil } : []
  send_json.call(res, { reports: list.select { |r| r["illustration"] == slug } })
end

server.mount_proc("/api/report") do |req, res|
  next send_json.call(res, { error: "POST only" }, 405) unless req.request_method == "POST"
  next send_json.call(res, { error: "missing or wrong token" }, 403) unless req["X-Report-Token"] == TOKEN
  next send_json.call(res, { error: "request too large" }, 413) if req.body.to_s.bytesize > 20_000
  begin
    b = JSON.parse(req.body.to_s)
    scope = b["scope"] == "page" ? "page" : "row"
    problem = b["problem"].to_s
    allowed = scope == "page" ? PAGE_PROBLEMS : ROW_PROBLEMS
    raise ArgumentError, "unknown problem #{problem.inspect}" unless allowed.include?(problem)
    raise ArgumentError, "illustration missing" unless b["illustration"].to_s.match?(/\A[\w\-]{1,60}\z/)
    raise ArgumentError, "row missing" if scope == "row" && b["row_id"].to_s.empty?
    report = {
      "id" => "qa-#{Time.now.utc.strftime('%Y%m%d%H%M%S')}-#{SecureRandom.hex(2)}",
      "at" => Time.now.utc.iso8601, "by" => opts[:reviewer], "status" => "open",
      "scope" => scope, "problem" => problem,
      "illustration" => b["illustration"], "illustration_number" => short(b["illustration_number"], 30),
      "row_id" => scope == "row" ? short(b["row_id"], 80) : nil,
      "part_no_shown" => short(b["part_no"], 40), "pdf_page" => b["pdf_page"].to_s.match?(/\A\d{1,3}\z/) ? b["pdf_page"].to_i : nil,
      "printed_page" => short(b["printed_page"], 20), "note" => short(b["note"], 2000)
    }
    LOCK.synchronize do
      File.open(opts[:reports], "a") do |f|
        f.flock(File::LOCK_EX)
        f.puts(JSON.generate(report))
      end
    end
    send_json.call(res, { ok: true, report: report })
  rescue JSON::ParserError, ArgumentError => e
    send_json.call(res, { error: e.message }, 400)
  end
end

trap("INT") { server.shutdown }
trap("TERM") { server.shutdown }
puts "Parts preview on http://127.0.0.1:#{opts[:port]}/parts/  (reports go to #{opts[:reports]}; Ctrl-C to stop)"
server.start
