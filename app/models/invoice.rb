# frozen_string_literal: true

# A request for payment. Invoices may be paid in full or in several partial
# payments. All currency values are dollars in Ruby and pennies in the database
# (see CentsAsDollarsType).
#
#   invoice = Invoice.create(invoice_total: 200.00)
#   payment = invoice.record_payment(100.00, :charge)
#   payment.persisted?    # => true
#   invoice.amount_owed   # => 0.1e3 (BigDecimal dollars)
#   invoice.fully_paid?   # => false
class Invoice < ApplicationRecord
  # Pennies paid against each invoice, for comparing balances in SQL.
  PAID_CENTS_SQL = <<~SQL.squish
    SELECT COALESCE(SUM(payments.amount), 0) FROM payments
    WHERE payments.invoice_id = invoices.id
  SQL

  attribute :invoice_total, CentsAsDollarsType.new

  has_many :payments, dependent: :restrict_with_error

  # Filter by balance in the database; calling fully_paid? on each invoice
  # would run one query per invoice.
  scope :unpaid, -> { where("invoices.invoice_total > (#{PAID_CENTS_SQL})") }
  scope :fully_paid, -> { where("invoices.invoice_total <= (#{PAID_CENTS_SQL})") }

  # Payments are checked against the saved total, so bounding the total also
  # keeps every payment amount within the pennies column.
  validates :invoice_total,
            numericality: { greater_than: 0, less_than_or_equal_to: CentsAsDollarsType::MAX_AMOUNT },
            whole_cents: true
  validate :invoice_total_covers_amount_paid, on: :update, if: :will_save_change_to_invoice_total?

  # Total received so far, in dollars. One SUM query; the amount attribute's
  # type converts the pennies total back to dollars.
  def amount_paid
    payments.sum(:amount)
  end

  # Remaining balance, in dollars.
  def amount_owed
    invoice_total.to_d - amount_paid
  end

  def fully_paid?
    amount_owed <= 0
  end

  # Records a payment (in dollars) against this invoice.
  #
  # Returns the Payment. Check `payment.persisted?` / `payment.errors` to see
  # whether it was accepted (e.g. invalid method, or more than the balance).
  # Raises ActiveRecord::RecordNotSaved if the invoice itself isn't saved.
  def record_payment(amount, payment_method)
    payments.create(amount: amount, payment_method: payment_method).tap do |payment|
      # Rails keeps a rejected record in the association, where the next
      # save of this invoice would try to save it again.
      payments.reset unless payment.persisted?
    end
  end

  private

  def invoice_total_covers_amount_paid
    return if invoice_total.nil? || errors.include?(:invoice_total)

    # Take the row lock Payment's balance check takes (held until this update
    # commits), so a payment can't be recorded between this check and the save.
    self.class.lock.find(id)
    paid = amount_paid
    return if invoice_total >= paid

    errors.add(
      :invoice_total,
      "can't be less than the #{ActiveSupport::NumberHelper.number_to_currency(paid)} already paid"
    )
  end
end
