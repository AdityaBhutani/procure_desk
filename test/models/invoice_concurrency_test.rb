require "test_helper"

# Runs outside a test transaction so each thread has its own database
# connection and the invoice row lock is real.
class InvoiceConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @invoice = Invoice.create!(invoice_total: 100)
  end

  teardown do
    Payment.delete_all # delete_all skips Payment#readonly?
    Invoice.delete_all
  end

  test "two simultaneous payments of the full balance can't both succeed" do
    first, second = run_second_while_first_holds_lock(
      -> { Invoice.find(@invoice.id).record_payment(100, :cash) },
      -> { Invoice.find(@invoice.id).record_payment(100, :check) }
    )

    assert first.persisted?
    assert_not second.persisted?
    assert_equal ["Amount exceeds the remaining balance of $0.00"], second.errors.full_messages
    assert_equal BigDecimal("100"), @invoice.amount_paid
  end

  test "payments created through the association are serialized too" do
    first, second = run_second_while_first_holds_lock(
      -> { Invoice.find(@invoice.id).payments.create(amount: 100, payment_method: :cash) },
      -> { Payment.create(invoice_id: @invoice.id, amount: 100, payment_method: :check) }
    )

    assert first.persisted?
    assert_not second.persisted?
    assert_equal BigDecimal("100"), @invoice.amount_paid
  end

  test "a payment and a lower total can't combine to overpay" do
    payment, lowered = run_second_while_first_holds_lock(
      -> { Invoice.find(@invoice.id).record_payment(80, :cash) },
      -> { Invoice.find(@invoice.id).update(invoice_total: 50) }
    )

    assert payment.persisted?
    assert_not lowered
    assert_equal BigDecimal("100"), @invoice.reload.invoice_total
  end

  private

  # Runs `first` in a thread and pauses it just after it locks the invoice row
  # (its first SELECT ... FOR UPDATE), then runs `second` in another thread
  # while the lock is held. Without the lock, `second` would finish during the
  # pause and see the balance from before `first`.
  def run_second_while_first_holds_lock(first, second)
    lock_taken = Queue.new
    pause_after_lock = lambda do |event|
      next unless Thread.current[:pause_after_lock] && event.payload[:sql].include?("FOR UPDATE")

      Thread.current[:pause_after_lock] = false
      lock_taken << true
      sleep 0.5
    end

    ActiveSupport::Notifications.subscribed(pause_after_lock, "sql.active_record") do
      first_thread = Thread.new do
        Thread.current[:pause_after_lock] = true
        ActiveRecord::Base.connection_pool.with_connection { first.call }
      end
      assert lock_taken.pop(timeout: 5), "the first operation never locked the invoice"

      second_thread = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection { second.call }
      end

      [first_thread, second_thread].map do |thread|
        assert thread.join(10), "a thread didn't finish in time"
        thread.value
      end
    end
  end
end
