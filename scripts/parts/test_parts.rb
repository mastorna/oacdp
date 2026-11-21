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
eq "printed page pattern", "1-10".match(Book::PRINTED_RE)&.captures, ["1", "10", nil]
eq "printed page section", "ST-9".match(Book::PRINTED_RE)&.captures, ["ST", "9", nil]
eq "printed page rejects part no", "211-216".match?(Book::PRINTED_RE), false
eq "stamp", Book.stamp([{ text: "a Typ2 31/68 x" }]), "Typ 2 31/68"
eq "illustration OCR variant", Book.ill_number([{ text: "Nlustration 1+A1" }]), "1+A1"
eq "illustration split word", Book.ill_number([{ text: "tation 2" }]), "2"
eq "illustration t for 1", Book.ill_number([{ text: "Illustration t+ A 1" }]), "1+A1"
eq "slug", Book.slug("1+A1"), "ill1a1"
eq "sql quote", SQL.q("O'Brien"), "'O''Brien'"
eq "sql null/bool/int", [SQL.q(nil), SQL.q(true), SQL.q(7)], %w[NULL 1 7]
eq "sql array as json", SQL.q(["M 215"]), %q('["M 215"]')

# ---- fix round: suffix pages, labels, keys, colour lines, contents --------------------
pr = ->(t) { Book.printed([{ text: t, x1: 100 }], 2500) }
eq "printed page with suffix", pr.call("Illustration 61 S ~22a"), ["S", 22, "a"]
eq "printed page with spaced suffix", pr.call("1-124 a"), ["1", 124, "a"]
eq "printed page plain", pr.call("Typ 2 31/68 Illustration 3 1-51"), ["1", 51, ""]
eq "printed page string", Book.pstr(["1", 50, "b"]), "1-50b"
eq "full label with letter", Book.ill_number([{ text: "Illustration 39 a 8-50" }]), "39a"
eq "spaced letter without page number is noise", Book.ill_number([{ text: "iustration 32 a . ; ." }]), "32"
eq "full label with parts", Book.ill_number([{ text: "Illustration 38 + A 38 + B 38 + C 38" }]), "38+A38+B38+C38"
eq "letter inside the word is not a number", Book.ill_number([{ text: "Illustration ]2 6-12" }]), nil
eq "longest rising run drops stray keys", Book.longest_rising([20, 21, 3, 22, 24, 12, 25]), [20, 21, 22, 24, 25]
eq "contents line", "17   Differential .......   31".match(Book::CONTENTS_LINE_RE)&.captures, ["17", "Differential", "31"]
eq "contents line with label", "11 Brake cylinders and lines   33+A33".match(Book::CONTENTS_LINE_RE)&.captures&.last, "33+A33"
eq "key with drawing letter", Rows.key_as_printed("A 66 311 101 301 D Cylinder", "66"), ["A 66", "A"]
eq "key with slash", Rows.key_as_printed("A 18/36 . 211 611 741 B Brake", nil), ["A 18/36", "A"]
eq "plain key stays a number", Rows.key_as_printed("35 311 107 101 M Piston", "35"), [35, nil]
eq "date in key column is not a key", Rows.key_as_printed("8/64 211 881 031 Seat", nil), [nil, nil]
eq "prefix kept when the drawing exists", Rows.check_prefix!({ "key" => "A 66", "key_prefix" => "A" }, "1+A1")["key"], "A 66"
eq "prefix dropped when no such drawing", Rows.check_prefix!({ "key" => "B 65", "key_prefix" => "B" }, "44")["key"], 65
eq "colour/date line stays a continuation", "8/63 – 7/64 395 ice blue – 81".match?(Rows::COLOUR_START_RE), true
eq "item line is not a colour line", "12 111 905 223 Safety screen".match?(Rows::COLOUR_START_RE), false

# ---- footer round: the cleaned-footer reading and the vote --------------------------------
fr = Book.footer_reading("N Typ 2 31/68 ui Ilustration 3 1 49 oo")
eq "footer: page number after the label, dash lost", fr[:printed], ["1", 49, ""]
eq "footer: illustration", fr[:ill], "3"
eq "footer: suffix page after a split word", Book.footer_reading("Hiustrat on 61 S 22a")[:printed], ["S", 22, "a"]
eq "footer: dash required away from the label", Book.footer_reading("junk 3-7 more")[:printed], ["3", 7, ""]
eq "footer: empty", Book.footer_reading(""), {}
show = ->(v) { v.to_s }
eq "vote: two agree", Book.vote({ "a" => 1, "b" => 2, "c" => 1 }, show)[0, 3], [1, "a and c agree (b 2)", true]
eq "vote: lone reading", Book.vote({ "a" => nil, "b" => 2, "c" => nil }, show)[0, 3], [2, "b reading", false]
eq "vote: all differ, no keep", Book.vote({ "a" => 1, "b" => 2 }, show)[0], nil
eq "vote: all differ, keep first", Book.vote({ "a" => 1, "b" => 2 }, show, keep_first: true)[0], 1

puts "#{$count - $fails}/#{$count} passed"
exit($fails.zero? ? 0 : 1)
