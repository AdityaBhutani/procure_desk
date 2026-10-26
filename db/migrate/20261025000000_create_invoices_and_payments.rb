# frozen_string_literal: true

# The invoices and payments tables as the original data model describes them,
# with Rails' default bigint keys and timestamps, and no other constraints. The
# two migrations after this one bring the schema in line with the refactored
# models.
class CreateInvoicesAndPayments < ActiveRecord::Migration[7.1]
  def change
    create_table :invoices do |t|
      t.integer :invoice_total # pennies
      t.timestamps
    end

    create_table :payments do |t|
      t.bigint :invoice_id
      t.integer :payment_method_id # 1 = cash, 2 = check, 3 = charge
      t.integer :amount # pennies
      t.timestamps
    end
  end
end
