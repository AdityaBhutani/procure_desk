require "test_helper"

class InvoiceTest < ActiveSupport::TestCase
  test "stores the dollar total as pennies on create and on update" do
    invoice = Invoice.create!(invoice_total: 200.50)
    assert_equal 20050, stored_value(invoice, :invoice_total)

    invoice.update!(invoice_total: 300.25)
    assert_equal 30025, stored_value(invoice, :invoice_total)
  end

  test "fully_paid? is false until nothing is owed" do
    invoice = Invoice.create!(invoice_total: 200)
    assert_not invoice.fully_paid?

    invoice.record_payment(150, :cash)
    assert_not invoice.fully_paid?

    invoice.record_payment(50, :check)
    assert invoice.fully_paid?
  end

  test "amount_paid and amount_owed are BigDecimal dollars" do
    invoice = Invoice.create!(invoice_total: 200)

    assert_equal BigDecimal("0"), invoice.amount_paid
    assert_equal BigDecimal("200"), invoice.amount_owed
    assert_instance_of BigDecimal, invoice.amount_paid
    assert_instance_of BigDecimal, invoice.amount_owed

    invoice.record_payment(19.99, :cash)
    invoice.record_payment(0.01, :cash)

    assert_equal BigDecimal("20.00"), invoice.amount_paid
    assert_equal BigDecimal("180.00"), invoice.amount_owed
  end

  test "rejects invalid totals with a validation error" do
    {
      0 => "Invoice total must be greater than 0",
      -5 => "Invoice total must be greater than 0",
      "abc" => "Invoice total is not a number",
      nil => "Invoice total is not a number",
      10.005 => "Invoice total can't include fractions of a cent (use at most 2 decimal places)",
      Float::INFINITY => "Invoice total must be less than or equal to 21474836.47",
      21_474_836.48 => "Invoice total must be less than or equal to 21474836.47"
    }.each do |total, message|
      invoice = Invoice.new(invoice_total: total)

      assert_not invoice.save, "expected #{total.inspect} to be rejected"
      assert_equal [message], invoice.errors.full_messages
    end
  end

  test "accepts the largest total the pennies column can hold" do
    invoice = Invoice.create!(invoice_total: "21474836.47")

    assert_equal 2_147_483_647, stored_value(invoice, :invoice_total)
  end

  test "record_payment on an unsaved invoice raises" do
    assert_raises(ActiveRecord::RecordNotSaved) do
      Invoice.new(invoice_total: 100).record_payment(10, :cash)
    end
  end

  test "a rejected payment isn't left on the invoice to be saved later" do
    invoice = Invoice.create!(invoice_total: 100)
    rejected = invoice.record_payment(150, :cash)

    assert_not rejected.persisted?
    assert_empty invoice.payments
    assert invoice.update(invoice_total: 500)
    assert_equal 0, Payment.where(invoice: invoice).count
    assert invoice.destroy
  end

  test "record_payment checks the saved total and leaves unsaved changes alone" do
    invoice = Invoice.create!(invoice_total: 100)
    invoice.invoice_total = 1_000
    payment = invoice.record_payment(500, :cash)

    assert_not payment.persisted?
    assert_equal ["Amount exceeds the remaining balance of $100.00"], payment.errors.full_messages
    assert_equal BigDecimal("1000"), invoice.invoice_total
  end

  test "the total can't be lowered below what has been paid" do
    invoice = Invoice.create!(invoice_total: 200)
    invoice.record_payment(150, :cash)

    assert_not invoice.update(invoice_total: 100)
    assert_equal ["Invoice total can't be less than the $150.00 already paid"], invoice.errors.full_messages

    assert invoice.update(invoice_total: 150)
    assert invoice.fully_paid?
  end

  test "an overpaid invoice counts as fully paid" do
    invoice = Invoice.create!(invoice_total: 200)
    invoice.record_payment(150, :cash)
    invoice.update_column(:invoice_total, 100) # skips validation, as other writers might

    assert_equal BigDecimal("-50"), invoice.amount_owed
    assert invoice.fully_paid?
    assert_includes Invoice.fully_paid, invoice
    assert_not_includes Invoice.unpaid, invoice
  end

  test "an invoice with payments can't be destroyed" do
    invoice = Invoice.create!(invoice_total: 100)
    payment = invoice.record_payment(10, :cash)

    assert_not invoice.destroy
    assert_equal ["Cannot delete record because dependent payments exist"], invoice.errors.full_messages
    assert Invoice.exists?(invoice.id)
    assert Payment.exists?(payment.id)
  end

  test "an invoice without payments can be destroyed" do
    invoice = Invoice.create!(invoice_total: 100)

    assert invoice.destroy
    assert_not Invoice.exists?(invoice.id)
  end

  test "unpaid and fully_paid filter by balance in the database" do
    untouched = Invoice.create!(invoice_total: 100)
    partly_paid = Invoice.create!(invoice_total: 100)
    partly_paid.record_payment(99.99, :cash)
    paid = Invoice.create!(invoice_total: 100)
    paid.record_payment(60, :cash)
    paid.record_payment(40, :charge)

    assert_equal [untouched, partly_paid].sort_by(&:id), Invoice.unpaid.order(:id).to_a
    assert_equal [paid], Invoice.fully_paid.to_a
    assert_equal 2, Invoice.unpaid.count
  end
end
