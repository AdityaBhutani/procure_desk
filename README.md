# ProcureDesk: Invoice and Payment refactor

A refactor of two broken Rails models, `Invoice` and `Payment`. An invoice can take several partial payments by cash, check or charge. Callers work in dollars, and every amount is stored as integer pennies.

```ruby
invoice = Invoice.create(invoice_total: 200.00)

payment = invoice.record_payment(100.00, :charge)
payment.persisted?           # => true
invoice.amount_owed          # => 0.1e3 (BigDecimal dollars; the column holds pennies)

payment = invoice.record_payment(150.00, :cash)
payment.persisted?           # => false
payment.errors.full_messages # => ["Amount exceeds the remaining balance of $100.00"]

Invoice.unpaid               # balances compared in SQL, not one query per invoice
```

## Setup and tests

Needs Ruby 3.2.2, PostgreSQL, and Rails 7.1 or later (the code uses `enum ... validate:`).

```bash
bin/rails db:prepare
```

```bash
bin/rails test
```

The first migration creates the tables as the original brief describes them. The next two are the refactor's schema changes: a column rename, then database constraints. Minitest is pinned to 5.x because Rails 7.1's test runner doesn't work with Minitest 6.

| File | What it does |
| --- | --- |
| `app/models/invoice.rb` | Total, balance, `record_payment`, `unpaid` / `fully_paid` scopes |
| `app/models/payment.rb` | Amount and method, validations, overpayment check with row lock, immutability |
| `app/types/cents_as_dollars_type.rb` | Dollars in Ruby, pennies in the database |
| `app/validators/whole_cents_validator.rb` | Rejects fractions of a cent |
| `db/migrate/` | Baseline tables, `payment_method_id` → `payment_method`, integrity constraints |

## Why I made these changes

**The original code could not run.** Neither class inherited from `ApplicationRecord`, so `has_many`, `validates` and the callbacks didn't exist. `attr_accessible` was removed in Rails 4. The inclusion validation put `message:` outside its options, which makes Rails look for a validator called `MessageValidator`. `has_one :invoice` pointed the wrong way, since the foreign key lives on `payments`. The payment method lookups couldn't work: `METHODS[payment_method_id]` looked up an integer in a hash keyed by symbols, and `Hash#value` doesn't exist. Worst of all, `payment_method_id` was set in `before_create`, which runs after validation. Its presence check therefore failed every time, and no payment could ever be saved.

**The logic was wrong in several places.** `fully_paid?` was inverted. `amount_owed` summed a column that doesn't exist, and claimed to return dollars when it would have returned pennies. The dollars-to-pennies callback computed `invoice_total * 100` and threw the result away. It would also only have run on create, so any update would have stored dollars in a pennies column. `(amount * 100).to_i` loses pennies to floating point: 19.99 is stored as 1998.

**Money now has one owner.** A custom attribute type, `CentsAsDollarsType`, converts on every read, write and query. It replaces a one-way callback, keeps the schema the brief describes, and adds no gem. Ruby code always sees `BigDecimal` dollars, so arithmetic is exact. An amount with a third decimal place is rejected rather than rounded, because it almost always signals a mistake, and guessing would under- or over-charge someone. Floats are first rounded to a millionth of a dollar. That removes binary noise such as `0.1 + 0.7`, but `10.005` still gets caught. Input that can't be a sensible amount gets a validation error instead of a crash. That covers `"abc"`, Infinity, NaN, and totals too large for the 4-byte column.

**Payment methods use a Rails `enum`.** The integers are mapped explicitly, so reordering the list can never change what stored rows mean. `prefix: :paid_by` gives readable predicates and scopes (`paid_by_charge?`, `Payment.paid_by_cash`). `validate:` turns an unknown method into a validation error instead of an `ArgumentError`. The allowed methods are now listed once instead of three times. The column became `payment_method`, because the enum expects the column to share the attribute's name, and the `_id` suffix falsely suggested a foreign key.

**Errors follow one rule:** bad input produces an unsaved record with errors, and misuse of the API raises. So `record_payment` returns the `Payment` either way, and the caller checks `persisted?` and `errors`, the standard Rails pattern. An overpayment is rejected, and the message states the remaining balance.

**Money rules hold under concurrency and across write paths.** The overpayment check locks the invoice row inside the payment's own save transaction, and reads the saved total rather than whatever the caller's object holds. Two payments arriving at once are therefore handled one after the other, whether they come through `record_payment`, `invoice.payments.create` or `Payment.create`. Lowering an invoice total below what has been paid is rejected under the same lock. Saved payments are read-only, because a financial record should be corrected by a new, offsetting entry, not rewritten. An invoice with payments can't be deleted. Database constraints repeat the per-row rules (NOT NULL columns, positive amounts, known methods, foreign key) for writers that skip validations. The constraints migration first checks existing data and lists any bad rows, instead of failing partway through.

**It is more Ruby-like.** The rewrite drops redundant `self.` and hash braces, dead code, and the duplicated method list. Balances are filtered with SQL scopes instead of loading every invoice. Comments explain why rather than what.

**How it was checked:** 58 tests run against PostgreSQL, including real two-connection race tests and the migrations up, down and over bad data. Removing a key fix on purpose makes the suite fail; this was tried for the row locks, the Infinity check, the rejected-payment cleanup, the Float rounding and others. An independent review then tried to break the code from five angles: Rails internals, hostile inputs, concurrency, migrations and readability. Each confirmed problem was either fixed with a test or listed below as out of scope.

## Known limitations

- Bulk writes (`update_all`, `delete_all`, `upsert_all`) and raw SQL skip the model, so they can still change payments or overpay an invoice. A PostgreSQL trigger would close this. It was left out because it would also block maintenance scripts and test cleanup.
- There are no refunds or voids. Correcting a payment needs a new record type, which also changes the balance rules.
- Querying by an amount above $21,474,836.47 raises `ActiveRecord::RangeError`, because the pennies column is a 4-byte integer.
- Listing balances for many invoices runs one `SUM` per invoice. Filtering by balance doesn't, because it uses the scopes.
- The row lock assumes PostgreSQL's default READ COMMITTED isolation. Under REPEATABLE READ, two payments could still overpay.
- Deleting an invoice at the same moment a payment is recorded: whichever locks the invoice row first wins. Either `destroy` raises `ActiveRecord::InvalidForeignKey` instead of returning false, or the payment is rejected because its invoice is gone. The foreign key keeps the data consistent either way.
- Only form, JSON and plain Ruby numbers are handled cleanly. An integer-like Symbol (`:"10"`) or a Complex amount built in code raises `NoMethodError`, and an `ActiveSupport::Duration` is read as its number of seconds.
- There is one currency, USD.
- Deploy the column-rename migration together with the model code: each fails without the other.
