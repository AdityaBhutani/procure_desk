require "test_helper"

# Writes that skip model validations must still be stopped by the database.
class DatabaseConstraintsTest < ActiveSupport::TestCase
  setup do
    @invoice = Invoice.create!(invoice_total: 100)
    @payment = @invoice.record_payment(10, :cash)
  end

  test "rejects a non-positive invoice total" do
    assert_rejected_by_database { Invoice.where(id: @invoice.id).update_all(invoice_total: 0) }
  end

  test "rejects a missing invoice total" do
    assert_rejected_by_database { Invoice.where(id: @invoice.id).update_all(invoice_total: nil) }
  end

  test "rejects a non-positive payment amount" do
    assert_rejected_by_database { Payment.where(id: @payment.id).update_all(amount: 0) }
  end

  test "rejects a missing payment amount" do
    assert_rejected_by_database { Payment.where(id: @payment.id).update_all(amount: nil) }
  end

  test "rejects a missing payment method" do
    assert_rejected_by_database { Payment.where(id: @payment.id).update_all(payment_method: nil) }
  end

  test "rejects an unknown payment method" do
    assert_rejected_by_database do
      Payment.insert_all([{ invoice_id: @invoice.id, amount: 100, payment_method: 4 }])
    end
  end

  test "rejects a payment without an invoice" do
    assert_rejected_by_database do
      Payment.insert_all([{ invoice_id: nil, amount: 100, payment_method: 1 }])
    end
  end

  test "rejects a payment for an invoice that doesn't exist" do
    assert_rejected_by_database do
      Payment.insert_all([{ invoice_id: @invoice.id + 1_000, amount: 100, payment_method: 1 }])
    end
  end

  test "rejects deleting an invoice that has payments" do
    assert_rejected_by_database { Invoice.where(id: @invoice.id).delete_all }
  end
end
