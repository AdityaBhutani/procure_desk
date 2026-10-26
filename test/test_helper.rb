ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # The value the database actually holds, bypassing attribute types.
    def stored_value(record, column)
      record.class.connection.select_value(record.class.where(id: record.id).select(column).to_sql)
    end

    # PostgreSQL aborts the whole transaction after a failed statement, so run
    # the statement in a savepoint to keep the rest of the test usable.
    def assert_rejected_by_database(&block)
      assert_raises(ActiveRecord::StatementInvalid) do
        ActiveRecord::Base.transaction(requires_new: true, &block)
      end
    end
  end
end
