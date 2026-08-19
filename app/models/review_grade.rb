# frozen_string_literal: true

# Stores an instructor-assigned grade and comment for a reviewer's overall
# contribution on an assignment. One record per reviewer (participant), not per
# individual review map, matching the old Expertiza review_grades schema.
class ReviewGrade < ApplicationRecord
  belongs_to :participant

  validates :grade_for_reviewer, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100, allow_nil: true }
end
