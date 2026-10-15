# frozen_string_literal: true

module FglPdf
  # Boca ticket counter (<TC#> sets it, <PC> prints it, each printed ticket increments it).
  # In-memory; Spool supplies a file-backed counter with the same interface.
  class Counter
    def initialize(value = 1)
      @value = value
      @lock = Mutex.new
    end

    def value
      @lock.synchronize { @value }
    end

    def value=(new_value)
      @lock.synchronize { @value = Integer(new_value) }
    end

    def increment!
      @lock.synchronize { @value += 1 }
    end

    # The 7-digit form printed by <PC>.
    def to_s
      format('%07d', value % 10_000_000)
    end
  end
end
