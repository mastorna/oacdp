#!/usr/bin/env ruby
# Plain-Ruby tests for scripts/parts/lib/parts.rb (standard library only).
#   ruby scripts/parts/test_parts.rb

require "tmpdir"
require_relative "lib/parts"

$fails = 0
$count = 0
def eq(name, got, want)
  $count += 1
  return if got == want
  $fails += 1
  warn "FAIL #{name}\n  got:  #{got.inspect}\n  want: #{want.inspect}"
end

# part-number shapes
eq "shape 9 digits", Parts.shape_ok?("211 609 237"), true
eq "shape with letter", Parts.shape_ok?("211 609 237 C"), true
eq "shape N-number", Parts.shape_ok?("N 13 634 1"), true
eq "shape glued digits rejected", Parts.shape_ok?("211609237"), false
eq "shape with marker rejected (marker is separate)", Parts.shape_ok?("*211 609 601 A"), false

# leading markers (addition C)
eq "split marker", Parts.split_marker("*211 609 601 A"), ["*", "211 609 601 A"]
eq "no marker", Parts.split_marker("211 609 601 A"), [nil, "211 609 601 A"]
eq "norm excludes marker", Parts.norm_part("*211 609 601 A"), "211609601A"
eq "norm N-number", Parts.norm_part("N 13 634 1"), "N136341"

# chassis parsing
f, t = Parts.parse_chassis("from Chassis No. 20 – 117 902 up to 1 144 281")
eq "from 20-NNN NNN", f, { "printed" => "20 – 117 902", "seq" => 117_902, "format" => "20-NNN NNN" }
eq "to 7-digit", t["seq"], 1_144_281
f, t = Parts.parse_chassis("M 216 and from Chassis No. 1 144 282")
eq "merged M-code + from", [f["seq"], t], [1_144_282, nil]
f, t = Parts.parse_chassis("up to Chassis No. 20–117 901")
eq "no-space dash", [f, t["seq"]], [nil, 117_901]
f, t = Parts.parse_chassis("from Chassis No. 20 – 069 409 up to 20 – 117 901")
eq "up to without 'Chassis No.'", [f["seq"], t["seq"]], [69_409, 117_901]
f, t = Parts.parse_chassis("from Chassis No. 20 – 117 902 up to 501 706")
eq "6-digit continues the sequence", [f["seq"], t["seq"]], [117_902, 501_706]
f, = Parts.parse_chassis("from Chassis No. 215 098 337")
eq "9-digit kept as printed, not sequenced", [f["printed"], f["seq"]], ["215 098 337", nil]
f, t = Parts.parse_chassis("up to Chassis No. 1 219 510\nfrom Chassis No. 1 219 511")
eq "line-broken text still parses (row level)", [f["seq"], t["seq"]], [1_219_511, 1_219_510]
eq "no chassis text", Parts.parse_chassis(nil), [nil, nil]

# derive!: one range per printed line when one quantity per line
row = { "part_no" => "211 601 027 F", "quantity" => %w[5 5],
        "applicability" => "up to Chassis No. 1 219 510\nfrom Chassis No. 1 219 511", "type_and_model" => "M 215" }
Parts.derive!(row)
eq "per-line ranges", row["chassis_ranges"].map { |r| [r.dig("chassis_from", "seq"), r.dig("chassis_to", "seq"), r["quantity"]] },
   [[nil, 1_219_510, "5"], [1_219_511, nil, "5"]]
eq "row-level range cleared", [row["chassis_from"], row["chassis_to"]], [nil, nil]
eq "option code from type-and-model column", row["option_codes"], ["M 215"]
row = { "part_no" => "211 609 237 C", "quantity" => "4", "applicability" => "M 216 and from Chassis No. 1 144 282" }
Parts.derive!(row)
eq "option code from applicability", row["option_codes"], ["M 216"]
eq "part_no_norm", row["part_no_norm"], "211609237C"

# alignment keeps order and leaves gaps as nil
eq "align with a missing line", Parts.align(%w[aaa bbb ccc], %w[aaa ccc]), [0, nil, 1]
eq "align skips extra lines", Parts.align(%w[aaa ccc], %w[aaa xxxxx ccc]), [0, 2]

# dump never writes YAML aliases, and round-trips
Dir.mktmpdir do |d|
  shared = %w[7 9]
  path = File.join(d, "t.yml")
  Parts.dump(path, { "a" => shared, "b" => shared })
  eq "no aliases written", File.read(path).match?(/[&*]\d/), false
  eq "round trip", Parts.load(path), { "a" => %w[7 9], "b" => %w[7 9] }
end

puts "#{$count - $fails}/#{$count} passed"
exit($fails.zero? ? 0 : 1)
