# frozen_string_literal: true

# A single payment against an invoice. Amounts are dollars in Ruby and pennies
# in the database (see CentsAsDollarsType).
#
# Requires Rails 7.1+ for `enum ... validate:`.
class Payment < ApplicationRecord
  # Explicit integer mapping: these values are persisted, so never rely on
  # array order, and never renumber an existing method.
  PAYMENT_METHODS = { cash: 1, check: 2, charge: 3 }.freeze
  PAYMENT_METHOD_ERROR = "must be one of: #{PAYMENT_METHODS.keys.join(', ')}".freeze

  attribute :amount, CentsAsDollarsType.new

  belongs_to :invoice

  # Generates paid_by_cash?, paid_by_check?, paid_by_charge?, matching
  # scopes (Payment.paid_by_check), and Payment.payment_methods.
  # Accepts symbols or strings; the reader returns a string ("charge").
  # `validate:` turns unknown or missing values into a validation error
  # instead of raising ArgumentError on assignment.
  enum :payment_method, PAYMENT_METHODS, prefix: :paid_by, validate: { message: PAYMENT_METHOD_ERROR }

  validate :payment_method_is_a_single_value
  validates :amount, numericality: { greater_than: 0 }, whole_cents: true
  validate :amount_does_not_exceed_balance, on: :create

  # Payments are financial records: once saved they can't be edited or
  # deleted. save, update, update_column(s), destroy, delete, increment! and
  # decrement! on a persisted payment raise ActiveRecord::ReadOnlyRecord.
  # Mistakes should be corrected with a new, offsetting record (e.g. a
  # refund), not by rewriting history. Class-level bulk writes (update_all,
  # delete_all, upsert_all, update_counters) and raw SQL still get through;
  # only a database trigger could stop those.
  #
  # `|| super` keeps readonly! working on unsaved payments.
  def readonly?
    persisted? || super
  end

  # Rails' delete and increment! (which decrement! calls) write to the
  # database without checking readonly?, so check it here.
  def delete
    raise_if_readonly
    super
  end

  def increment!(...)
    raise_if_readonly
    super
  end

  private

  def raise_if_readonly
    raise ActiveRecord::ReadOnlyRecord, "#{self.class} is marked as readonly" if readonly?
  end

  # The enum's inclusion check accepts an Array whose items are all valid
  # (["cash"]), which the enum then can't store.
  def payment_method_is_a_single_value
    return if !payment_method.is_a?(Array) || errors.include?(:payment_method)

    errors.add(:payment_method, PAYMENT_METHOD_ERROR)
  end

  # Checks against a locked copy of the invoice row rather than the caller's
  # invoice object, for two reasons. It sees the saved total, not unsaved
  # changes. And validation runs inside save's transaction, so the lock is held
  # until this payment is committed: a second payment for the same invoice
  # waits here, then sees the new balance (at PostgreSQL's default READ
  # COMMITTED isolation). That holds for every way of creating a payment, not
  # just Invoice#record_payment.
  def amount_does_not_exceed_balance
    return if invoice.nil? || amount.nil? || errors.include?(:amount)

    saved_invoice = Invoice.lock.find_by(id: invoice_id)
    if saved_invoice.nil?
      errors.add(:invoice, "must be saved before payments can be recorded")
      return
    end

    balance = saved_invoice.amount_owed
    return if amount <= balance

    errors.add(
      :amount,
      "exceeds the remaining balance of #{ActiveSupport::NumberHelper.number_to_currency(balance)}"
    )
  end
end
