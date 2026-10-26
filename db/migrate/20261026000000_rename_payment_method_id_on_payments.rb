# frozen_string_literal: true

# payment_method_id is not a foreign key (there is no payment_methods table),
# and Rails enums expect the column to share the attribute's name.
# The stored integers (1 = cash, 2 = check, 3 = charge) are unchanged,
# so existing rows need no data migration.
class RenamePaymentMethodIdOnPayments < ActiveRecord::Migration[7.1]
  def change
    rename_column :payments, :payment_method_id, :payment_method
  end
end
