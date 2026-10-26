require "test_helper"

class PaymentTest < ActiveSupport::TestCase
  setup do
    @invoice = Invoice.create!(invoice_total: 200)
  end

  test "records a payment in dollars against the invoice" do
    payment = @invoice.record_payment(100.00, :charge)

    assert payment.persisted?
    assert_equal BigDecimal("100"), payment.amount
    assert_equal 10000, stored_value(payment, :amount)
    assert_equal "charge", payment.payment_method
    assert payment.paid_by_charge?
    assert_equal BigDecimal("100"), @invoice.amount_owed
  end

  test "stores 19.99 as exactly 1999 pennies" do
    payment = @invoice.record_payment(19.99, :cash)

    assert_equal 1999, stored_value(payment, :amount)
  end

  test "accepts payment methods as strings" do
    payment = @invoice.record_payment(10, "check")

    assert payment.persisted?
    assert payment.paid_by_check?
  end

  test "rejects unknown, missing and multiple payment methods with a validation error" do
    [:bitcoin, "bitcoin", nil, "", ["cash"], %w[cash check], [], ["bitcoin"]].each do |method|
      payment = @invoice.record_payment(10, method)

      assert_not payment.persisted?, "expected #{method.inspect} to be rejected"
      assert_equal ["Payment method must be one of: cash, check, charge"], payment.errors.full_messages
    end
  end

  test "rejects invalid amounts with a validation error" do
    {
      0 => "Amount must be greater than 0",
      -5 => "Amount must be greater than 0",
      "abc" => "Amount is not a number",
      nil => "Amount is not a number",
      10.005 => "Amount can't include fractions of a cent (use at most 2 decimal places)",
      Float::INFINITY => "Amount is not a number",
      BigDecimal("Infinity") => "Amount is not a number",
      Rational(1, 3) => "Amount is not a number",
      Float::NAN => "Amount must be greater than 0"
    }.each do |amount, message|
      payment = @invoice.record_payment(amount, :cash)

      assert_not payment.persisted?, "expected #{amount.inspect} to be rejected"
      assert_equal [message], payment.errors.full_messages
    end
  end

  test "rejects a payment larger than the balance" do
    @invoice.record_payment(100, :cash)
    payment = @invoice.record_payment(150, :cash)

    assert_not payment.persisted?
    assert_equal ["Amount exceeds the remaining balance of $100.00"], payment.errors.full_messages
  end

  test "a payment of exactly the balance pays the invoice in full" do
    @invoice.record_payment(120.01, :cash)
    payment = @invoice.record_payment(79.99, :charge)

    assert payment.persisted?
    assert @invoice.fully_paid?
    assert_equal BigDecimal("0"), @invoice.amount_owed
  end

  test "an amount that is sub-cent and over the balance gets one error" do
    payment = @invoice.record_payment(300.005, :cash)

    assert_equal ["Amount can't include fractions of a cent (use at most 2 decimal places)"],
                 payment.errors.full_messages
  end

  test "payments created without record_payment are checked against the saved total" do
    @invoice.invoice_total = 1_000

    [
      @invoice.payments.create(amount: 500, payment_method: :cash),
      Payment.create(invoice: @invoice, amount: 500, payment_method: :cash)
    ].each do |payment|
      assert_not payment.persisted?
      assert_equal ["Amount exceeds the remaining balance of $200.00"], payment.errors.full_messages
    end
  end

  test "a payment for an unsaved invoice is a validation error" do
    payment = Payment.new(invoice: Invoice.new(invoice_total: 100), amount: 50, payment_method: :cash)

    assert_not payment.save
    assert_equal ["Invoice must be saved before payments can be recorded"], payment.errors.full_messages
  end

  test "rejects any payment on a fully paid invoice" do
    @invoice.record_payment(200, :cash)
    payment = @invoice.record_payment(0.01, :cash)

    assert_not payment.persisted?
    assert_equal ["Amount exceeds the remaining balance of $0.00"], payment.errors.full_messages
  end

  test "a payment needs an invoice" do
    payment = Payment.new(amount: 10, payment_method: :cash)

    assert_not payment.save
    assert_equal ["Invoice must exist"], payment.errors.full_messages
  end

  test "a saved payment can't be changed or deleted" do
    payment = @invoice.record_payment(50, :cash)

    assert_raises(ActiveRecord::ReadOnlyRecord) { payment.update(amount: 1) }
    assert_raises(ActiveRecord::ReadOnlyRecord) { payment.save }
    assert_raises(ActiveRecord::ReadOnlyRecord) { payment.update_column(:amount, 1) }
    assert_raises(ActiveRecord::ReadOnlyRecord) { payment.increment!(:amount, 500) }
    assert_raises(ActiveRecord::ReadOnlyRecord) { payment.decrement!(:amount, 10) }
    assert_raises(ActiveRecord::ReadOnlyRecord) { payment.destroy }
    assert_raises(ActiveRecord::ReadOnlyRecord) { payment.delete }
    assert_equal 5000, stored_value(payment, :amount)
  end

  test "readonly! still works on an unsaved payment" do
    payment = @invoice.payments.build(amount: 10, payment_method: :cash)
    payment.readonly!

    assert_raises(ActiveRecord::ReadOnlyRecord) { payment.save }
  end

  test "the enum generates scopes and a value list" do
    cash = @invoice.record_payment(10, :cash)
    charge = @invoice.record_payment(20, :charge)

    assert_equal [cash], Payment.paid_by_cash.to_a
    assert_equal [charge], Payment.paid_by_charge.to_a
    assert_equal({ "cash" => 1, "check" => 2, "charge" => 3 }, Payment.payment_methods)
  end
end
