#!/usr/bin/env ruby
# Tests for the parts preview plugin's data shaping (src/_plugins/parts_preview.rb).
#   bundle exec ruby scripts/parts/test_preview.rb
# The page script's fit check (src/_parts_assets/parts.js) uses these fields;
# the browser checks in the notes folder exercise it end to end.

require "jekyll"
require_relative "../../src/_plugins/parts_preview"
require_relative "lib/parts"

$fails = 0
$count = 0
def eq(name, got, want)
  $count += 1
  return if got == want
  $fails += 1
  warn "FAIL #{name}\n  got:  #{got.inspect}\n  want: #{want.inspect}"
end

def row(appl, qty: "1", extra: {})
  r = { "id" => "x-1", "part_no" => "211 601 027 F", "part_no_norm" => "211601027F", "applicability" => appl,
        "quantity" => qty, "confidence" => "readings agree", "confidence_reasons" => [] }.merge(extra)
  Parts.derive!(r)
end

r = PartsPreview.row_for_page(row("up to Chassis No. 20 – 117 901"), :machine)
eq "to-range from a 20- serial", r["ranges"], [{ "f" => nil, "t" => 117_901 }]
eq "not flagged unparsed", r["unparsed"], false
eq "machine row labelled agree", r["conf"], "agree"

r = PartsPreview.row_for_page(row("up to Chassis No. 1 219 510\nfrom Chassis No. 1 219 511", qty: %w[5 5]), :ai)
eq "one range per printed line", r["ranges"].map { |x| [x["f"], x["t"]] }, [[nil, 1_219_510], [1_219_511, nil]]
eq "quantities joined", r["q"], "5 / 5"
eq "AI source labelled", r["conf"], "ai"

r = PartsPreview.row_for_page(row("up to Chassis No. 216 190 000"), :machine)
eq "9-digit chassis is flagged as not compared", r["unparsed"], true

r = PartsPreview.row_for_page(row("up to Engine No. 3 399 999"), :machine)
eq "engine range flagged", [r["engine"], r["unparsed"], r["ranges"]], [true, false, [{ "f" => nil, "t" => nil }]]

r = PartsPreview.row_for_page(row("from Chassis No. 2O 1l7 9O2", extra: { "confidence" => "needs checking", "confidence_reasons" => ["bad_shape"] }), :machine)
eq "garbled chassis range is flagged", r["unparsed"], true
eq "needs checking carries reasons", [r["conf"], r["why"]], ["check", ["bad_shape"]]

r = PartsPreview.row_for_page(row(nil), :machine)
eq "no applicability: unbounded", [r["ranges"], r["unparsed"], r["engine"]], [[{ "f" => nil, "t" => nil }], false, false]

eq "json is safe inside a script tag", PartsPreview.json("a" => "</script>"), '{"a":"<\/script>"}'
eq "illustration labels sort by number", %w[22a 3 1+A1 22 10].sort_by { |x| PartsPreview.num_sort(x) }, %w[1+A1 3 10 22 22a]

puts "#{$count - $fails}/#{$count} passed"
exit($fails.zero? ? 0 : 1)
