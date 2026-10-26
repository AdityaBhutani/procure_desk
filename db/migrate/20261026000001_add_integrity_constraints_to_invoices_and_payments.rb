# frozen_string_literal: true

# Enforces the per-row Invoice and Payment rules in the database (required
# columns, positive amounts, known payment methods, and no orphaned payments or
# deleted invoices with payments), so data written by update_column,
# insert_all, raw SQL, or other services can't break them. The rules that span
# rows or history (no overpayment, payments can't change) are enforced only by
# the models.
#
# Must run after RenamePaymentMethodIdOnPayments (uses the `payment_method`
# column name).
class AddIntegrityConstraintsToInvoicesAndPayments < ActiveRecord::Migration[7.1]
  def up
    abort_if_existing_data_violates_constraints!

    # Invoices
    change_column_null :invoices, :invoice_total, false
    add_check_constraint :invoices, "invoice_total > 0",
                         name: "invoices_total_positive", if_not_exists: true

    # Payments
    change_column_null :payments, :invoice_id, false
    change_column_null :payments, :amount, false
    change_column_null :payments, :payment_method, false

    add_index :payments, :invoice_id, if_not_exists: true
    # :restrict mirrors `has_many :payments, dependent: :restrict_with_error`:
    # an invoice with payments can't be deleted, even with raw SQL.
    add_foreign_key :payments, :invoices, on_delete: :restrict, if_not_exists: true

    add_check_constraint :payments, "amount > 0",
                         name: "payments_amount_positive", if_not_exists: true
    # Hardcoded on purpose: migrations shouldn't depend on model code that may
    # change later. Adding a payment method means a new migration that
    # replaces this constraint.
    add_check_constraint :payments, "payment_method IN (1, 2, 3)",
                         name: "payments_method_valid", if_not_exists: true
  end

  def down
    remove_check_constraint :payments, name: "payments_method_valid", if_exists: true
    remove_check_constraint :payments, name: "payments_amount_positive", if_exists: true
    remove_foreign_key :payments, :invoices, if_exists: true
    # The invoice_id index is left in place even if this migration created it:
    # add_index with if_not_exists can't record whether it did, the index may
    # predate this migration on an existing database, and keeping it is
    # harmless.

    change_column_null :payments, :payment_method, true
    change_column_null :payments, :amount, true
    change_column_null :payments, :invoice_id, true

    remove_check_constraint :invoices, name: "invoices_total_positive", if_exists: true
    change_column_null :invoices, :invoice_total, true
  end

  private

  # Fails with a readable report instead of a cryptic database error halfway
  # through, so bad rows can be fixed before re-running.
  def abort_if_existing_data_violates_constraints!
    checks = {
      "invoices with a missing or non-positive invoice_total" => <<~SQL,
        SELECT COUNT(*) FROM invoices
        WHERE invoice_total IS NULL OR invoice_total <= 0
      SQL
      "payments with no matching invoice" => <<~SQL,
        SELECT COUNT(*) FROM payments
        LEFT JOIN invoices ON invoices.id = payments.invoice_id
        WHERE invoices.id IS NULL
      SQL
      "payments with a missing or non-positive amount" => <<~SQL,
        SELECT COUNT(*) FROM payments
        WHERE amount IS NULL OR amount <= 0
      SQL
      "payments with a missing or unknown payment_method" => <<~SQL
        SELECT COUNT(*) FROM payments
        WHERE payment_method IS NULL OR payment_method NOT IN (1, 2, 3)
      SQL
    }

    problems = checks.filter_map do |description, sql|
      count = select_value(sql).to_i
      "#{description}: #{count}" if count.positive?
    end
    return if problems.empty?

    raise <<~MSG
      Cannot add integrity constraints; existing data violates them:
        - #{problems.join("\n  - ")}
      Fix or remove these rows, then run the migration again.
    MSG
  end
end
