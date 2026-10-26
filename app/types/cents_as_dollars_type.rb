# frozen_string_literal: true

# Stores currency as integer pennies in the database while exposing it as
# BigDecimal dollars everywhere in Ruby. Reads, writes, and hash conditions in
# queries all go through this type, so the conversion is transparent and
# symmetrical:
#
#   invoice = Invoice.create(invoice_total: 200.00)
#   invoice.invoice_total   # => 0.2e3 (BigDecimal dollars)
#   # database column holds 20000
#
# BigDecimal is used instead of Float to avoid rounding bugs such as
# (19.99 * 100).to_i #=> 1998.
#
# Casting keeps the value exactly as given, so 10.005 stays 10.005 and the
# WholeCentsValidator can reject it. Rounding to whole pennies happens only in
# #serialize: a safety net for records saved without validation, and the reason
# where(invoice_total: 10.005) looks for $10.01.
class CentsAsDollarsType < ActiveModel::Type::Value
  # The largest amount a 4-byte integer pennies column can hold. Validate
  # against it: saving or querying a larger amount raises
  # ActiveRecord::RangeError.
  MAX_AMOUNT = BigDecimal(2**31 - 1) / 100 # $21,474,836.47

  def type
    :cents_as_dollars
  end

  # User input (forms, console, API params) -> BigDecimal dollars.
  # Unparseable or non-finite input becomes nil so model validations can
  # report it.
  def cast(value)
    return nil if value.blank?

    dollars = to_big_decimal(value)
    dollars if dollars.finite?
  rescue ArgumentError
    nil
  end

  # Ruby dollars -> database pennies.
  def serialize(value)
    dollars = cast(value)
    dollars && (dollars * 100).round
  end

  # Database pennies -> Ruby dollars.
  def deserialize(value)
    return nil if value.nil?

    BigDecimal(value.to_s) / 100
  end

  private

  def to_big_decimal(value)
    case value
    when BigDecimal then value
    when Float then float_to_big_decimal(value)
    when Integer then BigDecimal(value)
    else BigDecimal(value.to_s)
    end
  end

  # Rounds to a millionth of a dollar, far below a cent. That drops the binary
  # noise Float arithmetic leaves (0.1 + 0.7 => 0.8, 10.0 - 9.9 => 0.1) but
  # keeps a genuine third decimal place like 10.005 for validation to reject.
  # A tiny amount is left unrounded so it can't become 0, which numericality
  # (it checks the raw Float) would accept.
  def float_to_big_decimal(value)
    rounded = value.round(6)
    (rounded.zero? ? value : rounded).to_d
  end
end
