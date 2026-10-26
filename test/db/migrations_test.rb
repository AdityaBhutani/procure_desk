require "test_helper"
require Rails.root.join("db/migrate/20261025000000_create_invoices_and_payments")
require Rails.root.join("db/migrate/20261026000000_rename_payment_method_id_on_payments")
require Rails.root.join("db/migrate/20261026000001_add_integrity_constraints_to_invoices_and_payments")

# PostgreSQL runs schema changes inside the test transaction, so everything
# these tests migrate is rolled back afterwards.
class MigrationsTest < ActiveSupport::TestCase
  setup do
    @verbose = ActiveRecord::Migration.verbose
    ActiveRecord::Migration.verbose = false
  end

  teardown do
    ActiveRecord::Migration.verbose = @verbose
  end

  test "the constraints migration lists bad rows instead of failing halfway" do
    constraints = AddIntegrityConstraintsToInvoicesAndPayments.new
    constraints.migrate(:down)
    connection.execute(<<~SQL)
      INSERT INTO invoices (id, invoice_total, created_at, updated_at)
        VALUES (1, 0, now(), now());
      INSERT INTO payments (invoice_id, payment_method, amount, created_at, updated_at)
        VALUES (999, 1, 500, now(), now()),
               (1, 1, 0, now(), now()),
               (1, 9, 500, now(), now());
    SQL

    error = assert_raises(RuntimeError) { constraints.migrate(:up) }

    assert_equal <<~MSG, error.message
      Cannot add integrity constraints; existing data violates them:
        - invoices with a missing or non-positive invoice_total: 1
        - payments with no matching invoice: 1
        - payments with a missing or non-positive amount: 1
        - payments with a missing or unknown payment_method: 1
      Fix or remove these rows, then run the migration again.
    MSG
    assert_empty connection.check_constraints(:payments)
  end

  test "all migrations run down and back up" do
    migrations = [
      CreateInvoicesAndPayments.new,
      RenamePaymentMethodIdOnPayments.new,
      AddIntegrityConstraintsToInvoicesAndPayments.new
    ]

    migrations.reverse_each { |migration| migration.migrate(:down) }
    assert_not connection.table_exists?(:payments)
    assert_not connection.table_exists?(:invoices)

    migrations.each { |migration| migration.migrate(:up) }
    assert connection.column_exists?(:payments, :payment_method, :integer, null: false)
    assert_not connection.column_exists?(:payments, :payment_method_id)
    assert connection.foreign_key_exists?(:payments, :invoices)
    assert_equal %w[payments_amount_positive payments_method_valid],
                 connection.check_constraints(:payments).map(&:name).sort
  end

  private

  def connection
    ActiveRecord::Base.connection
  end
end
