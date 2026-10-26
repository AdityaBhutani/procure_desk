# frozen_string_literal: true

# Rejects currency amounts with fractions of a cent (more than two decimal
# places) instead of silently rounding them.
#
#   validates :amount, numericality: { greater_than: 0 }, whole_cents: true
#   validates :amount, whole_cents: { message: "must be a whole number of cents" }
#
# Declare it after `numericality`: it doesn't add a second error to a value
# another validator already rejected.
class WholeCentsValidator < ActiveModel::EachValidator
  DEFAULT_MESSAGE = "can't include fractions of a cent (use at most 2 decimal places)"

  def validate_each(record, attribute, value)
    return if record.errors.include?(attribute)

    if value.nil?
      reject_uncastable_input(record, attribute)
    elsif value.round(2) != value
      record.errors.add(attribute, :sub_cent, message: options[:message] || DEFAULT_MESSAGE)
    end
  end

  private

  # CentsAsDollarsType casts input it can't turn into a finite amount
  # (Float::INFINITY, BigDecimal("Infinity"), Rational) to nil. Rails'
  # numericality validator checks the raw input instead and lets those
  # through, so without this check the save fails on the NOT NULL constraint
  # rather than as a validation error.
  def reject_uncastable_input(record, attribute)
    before_type_cast = :"#{attribute}_before_type_cast"
    return unless record.respond_to?(before_type_cast)
    return if record.public_send(before_type_cast).blank?

    record.errors.add(attribute, :not_a_number)
  end
end
