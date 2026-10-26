require "test_helper"

class CentsAsDollarsTypeTest < ActiveSupport::TestCase
  setup do
    @type = CentsAsDollarsType.new
  end

  test "stores 19.99 as exactly 1999 pennies" do
    # The original (amount * 100).to_i stored 1998.
    assert_equal 1999, @type.serialize(19.99)
  end

  test "round-trips 200.50 through the database" do
    invoice = Invoice.create!(invoice_total: 200.50)

    assert_equal 20050, stored_value(invoice, :invoice_total)
    assert_equal BigDecimal("200.50"), invoice.reload.invoice_total
    assert_instance_of BigDecimal, invoice.invoice_total
  end

  test "casts Float arithmetic without binary noise" do
    assert_equal BigDecimal("0.3"), @type.cast(0.1 + 0.2)
    assert_equal BigDecimal("0.8"), @type.cast(0.1 + 0.7)
    assert_equal BigDecimal("0.1"), @type.cast(10.0 - 9.9)
    assert_equal BigDecimal("435"), @type.cast(4.35 * 100)
  end

  test "keeps a genuine third decimal place for validation to reject" do
    assert_equal BigDecimal("10.005"), @type.cast(10.005)
  end

  test "doesn't round a tiny positive Float down to zero" do
    assert_equal BigDecimal("0.0000001"), @type.cast(1e-7)
  end

  test "casts strings, integers and BigDecimals" do
    assert_equal BigDecimal("19.99"), @type.cast(" 19.99 ")
    assert_equal BigDecimal("200"), @type.cast(200)
    assert_equal BigDecimal("10.50"), @type.cast(BigDecimal("10.50"))
  end

  test "casts blank and unparseable input to nil" do
    [nil, "", "  ", "abc", "12abc", true].each do |input|
      assert_nil @type.cast(input), "expected #{input.inspect} to cast to nil"
    end
  end

  test "casts non-finite input to nil" do
    [Float::INFINITY, -Float::INFINITY, Float::NAN, BigDecimal("Infinity"), "Infinity", "NaN"].each do |input|
      assert_nil @type.cast(input), "expected #{input.inspect} to cast to nil"
    end
  end

  test "reads pennies back as BigDecimal dollars" do
    assert_equal BigDecimal("19.99"), @type.deserialize(1999)
    assert_nil @type.deserialize(nil)
  end

  test "rounds to whole pennies when saved without validation" do
    invoice = Invoice.new(invoice_total: 10.005)
    invoice.save!(validate: false)

    assert_equal 1001, stored_value(invoice, :invoice_total)
  end

  test "converts query values to pennies" do
    invoice = Invoice.create!(invoice_total: 200)

    assert_equal 20000, stored_value(invoice, :invoice_total)
    assert_equal [invoice], Invoice.where(invoice_total: 200).to_a
    assert_equal [invoice], Invoice.where(invoice_total: "200.00").to_a
  end
end
