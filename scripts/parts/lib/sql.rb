# Minimal SQL text helpers for build-db.rb (values quoted for SQLite).

require "json"

module SQL
  module_function

  def q(v)
    case v
    when nil then "NULL"
    when true then "1"
    when false then "0"
    when Integer, Float then v.to_s
    when Array, Hash then q(JSON.generate(v))
    else "'#{v.to_s.gsub("'", "''")}'"
    end
  end

  def insert(table, h)
    "INSERT INTO #{table} (#{h.keys.join(', ')}) VALUES (#{h.values.map { |v| q(v) }.join(', ')});"
  end
end
