require "test_helper"

class WholeCentsValidatorTest < ActiveSupport::TestCase
  class Price
    include ActiveModel::Model
    include ActiveModel::Attributes

    attribute :amount, CentsAsDollarsType.new
    validates :amount, whole_cents: true
  end

  class PriceWithMessage < Price
    clear_validators!
    validates :amount, whole_cents: { message: "must be a whole number of cents" }
  end

  test "accepts amounts with at most two decimal places" do
    [10.50, 10, BigDecimal("10.5"), "10.99", 0.1 + 0.2, 0.1 + 0.7, 10.0 - 9.9].each do |amount|
      assert Price.new(amount: amount).valid?, "expected #{amount.inspect} to be valid"
    end
  end

  test "rejects fractions of a cent" do
    price = Price.new(amount: 10.005)

    assert_not price.valid?
    assert price.errors.of_kind?(:amount, :sub_cent)
    assert_equal ["Amount can't include fractions of a cent (use at most 2 decimal places)"],
                 price.errors.full_messages
  end

  test "uses a custom message" do
    price = PriceWithMessage.new(amount: 10.005)

    assert_not price.valid?
    assert_equal ["Amount must be a whole number of cents"], price.errors.full_messages
  end

  test "leaves missing values to other validators" do
    assert Price.new(amount: nil).valid?
  end

  test "doesn't add a second error to a value another validator rejected" do
    invoice = Invoice.new(invoice_total: -10.005)

    assert_not invoice.valid?
    assert_equal ["Invoice total must be greater than 0"], invoice.errors.full_messages
  end
end
