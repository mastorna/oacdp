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

# ---- whole-book catalog helpers -------------------------------------------------------
require_relative "lib/rows"
require_relative "lib/book"
require_relative "lib/sql"
eq "canonical 9 digits + letter", Rows.canonical("311107101M"), "311 107 101 M"
eq "canonical N-number", Rows.canonical("N136341"), "N 13 634 1"
eq "canonical unknown shape", Rows.canonical("L680"), nil
eq "norm shape ok", Rows.norm_shape_ok?("211609237C"), true
eq "norm shape too short", Rows.norm_shape_ok?("21160923"), false
eq "description after part no", Rows.description("4 211 601 139 Bolt - Wheel disc ........ 20", "211 601 139"), "Bolt - Wheel disc"
eq "description garbled leaders", Rows.description("111 601 161 Ferrule - Hub cap ...•...••..... '. ..•", "111 601 161"), "Ferrule - Hub cap"
r1 = { "part_no" => "211 601 139", "marker" => nil, "key" => 4, "quantity" => "20", "applicability" => nil }
eq "confidence: both agree", Rows.confidence(r1, r1.merge("part_no" => "211601139")), ["readings agree", []]
eq "confidence: one reading", Rows.confidence(r1, nil), ["needs checking", ["only_text_layer"]]
eq "confidence: part differs", Rows.confidence(r1, r1.merge("part_no" => "211 601 189")).last, ["part_no_differs"]
eq "confidence: missing qty is no opinion", Rows.confidence(r1, r1.merge("quantity" => nil)).first, "readings agree"
eq "confidence: qty differs", Rows.confidence(r1, r1.merge("quantity" => "2")).last, ["qty_differs"]
eq "confidence: bad shape", Rows.confidence(r1.merge("part_no" => "261264"), r1.merge("part_no" => "261264")).last, ["bad_shape"]
eq "disagreement fields", Rows.disagreement_fields(%w[bad_shape part_no_differs qty_differs only_tesseract]), %w[part_no quantity]
a = [{ text: "211 601 139 Bolt", box: [0, 100, 0, 0] }, { text: "111 601 151 Hub cap", box: [0, 200, 0, 0] }]
b = [{ text: "211601139 Bolt", box: [0, 101, 0, 0] }, { text: "N 13 407 1 Rivet", box: [0, 150, 0, 0] }]
m = Rows.merge(a, b)
eq "merge: pairs + leftovers in page order", m.map { |x, y| [x && x[:text], y && y[:text]] },
   [["211 601 139 Bolt", "211601139 Bolt"], [nil, "N 13 407 1 Rivet"], ["111 601 151 Hub cap", nil]]
eq "printed page pattern", "1-10".match(Book::PRINTED_RE)&.captures, %w[1 10]
eq "printed page section", "ST-9".match(Book::PRINTED_RE)&.captures, %w[ST 9]
eq "printed page rejects part no", "211-216".match?(Book::PRINTED_RE), false
eq "stamp", Book.stamp([{ text: "a Typ2 31/68 x" }]), "Typ 2 31/68"
eq "illustration OCR variant", Book.ill_number([{ text: "Nlustration 1+A1" }]), "1+A1"
eq "illustration split word", Book.ill_number([{ text: "tation 2" }]), "2"
eq "illustration t for 1", Book.ill_number([{ text: "Illustration t+ A 1" }]), "1+A1"
eq "slug", Book.slug("1+A1"), "ill1a1"
eq "sql quote", SQL.q("O'Brien"), "'O''Brien'"
eq "sql null/bool/int", [SQL.q(nil), SQL.q(true), SQL.q(7)], %w[NULL 1 7]
eq "sql array as json", SQL.q(["M 215"]), %q('["M 215"]')

puts "#{$count - $fails}/#{$count} passed"
exit($fails.zero? ? 0 : 1)
