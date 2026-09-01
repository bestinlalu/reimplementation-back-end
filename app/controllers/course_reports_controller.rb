# frozen_string_literal: true

# Instructor-facing course-level report endpoints.
# grade_summary: peer score + instructor grade per student per assignment.
# all_reviews:   average teammate review score received per student per assignment.
class CourseReportsController < ApplicationController
  include PenaltyHelper

  before_action :set_course
  before_action :authorize

  def action_allowed?
    current_user_has_instructor_privileges?
  end

  # GET /courses/:id/course_report/grade_summary
  def grade_summary
    assignments    = active_assignments
    assignment_ids = assignments.map(&:id)
    users          = unique_users(assignment_ids)
    user_ids       = users.map(&:id)

    participant_map = AssignmentParticipant
      .where(parent_id: assignment_ids)
      .group_by { |p| [p.parent_id, p.user_id] }
      .transform_values(&:first)

    # Maps [assignment_id, user_id] → team_id so that, for each cell in the
    # grade table, we can look up the team a student was on for that assignment
    # without issuing a query per student. A student appears in at most one team
    # per assignment, so the last record per key is taken (transform_values below).
    team_lookup = TeamsParticipant
      .joins("INNER JOIN teams ON teams_participants.team_id = teams.id")
      .where("teams.parent_id IN (?) AND teams_participants.user_id IN (?)", assignment_ids, user_ids)
      .select("teams_participants.user_id, teams_participants.team_id, teams.parent_id AS assignment_id")
      .each_with_object({}) { |r, h| h[[r.assignment_id.to_i, r.user_id]] = r.team_id }

    team_ids = team_lookup.values.uniq
    teams_by_id = AssignmentTeam.where(id: team_ids).includes(:project_topics).index_by(&:id)

    peer_scores = precompute_peer_scores(assignment_ids, team_ids)

    # Each student_row represents one student's grades across all assignments.
    student_rows = users.map do |user|
      cells = assignments.map do |assignment|
        ap = participant_map[[assignment.id, user.id]]
        next nil unless ap

        team_id = team_lookup[[assignment.id, user.id]]
        team    = team_id ? teams_by_id[team_id] : nil

        raw_grade = team&.grade_for_submission
        instructor_grade = penalized_submission_grade(raw_grade, ap.id)

        {
          assignment_id:    assignment.id,
          assignment_name:  assignment.name,
          topic:            team&.project_topics&.first&.topic_name,
          peer_score:       peer_scores[[assignment.id, team_id]],
          instructor_grade: instructor_grade
        }
      end.compact

      graded_cells = cells.select { |c| c[:instructor_grade] }

      {
        user_id:     user.id,
        user_name:   user.name,
        assignments: cells,
        final_grade: graded_cells.empty? ? nil : graded_cells.sum { |c| c[:instructor_grade] }.round(2)
      }
    end

    render json: {
      course_id:   @course.id,
      course_name: @course.name,
      assignments: assignments.map { |a| { id: a.id, name: a.name, has_topics: a.project_topics.any? } },
      rows:        student_rows
    }
  end

  # GET /courses/:id/course_report/all_reviews
  # Returns the average teammate review score received by each student per assignment,
  # plus an aggregate across all assignments and a count of how many unique teammates
  # reviewed that student. Only non-calibrated assignments with at least one
  # participant are included.
  def all_reviews
    assignments    = active_assignments
    assignment_ids = assignments.map(&:id)
    users          = unique_users(assignment_ids)
    user_ids       = users.map(&:id)

    all_participants = AssignmentParticipant.where(parent_id: assignment_ids).to_a
    participant_map  = all_participants.group_by { |p| [p.parent_id, p.user_id] }
                                       .transform_values(&:first)

    # Scores received by each participant (reviews OF that student by their teammates)
    scores_received_from_teammates = precompute_teammate_scores(all_participants.map(&:id))
    # Number of unique teammates who reviewed each student (reviews DONE BY teammates)
    reviewer_teammate_counts = precompute_teammate_counts(assignment_ids, user_ids)

    # Each student_row represents one student's teammate review scores across all assignments.
    student_rows = users.map do |user|
      cells = assignments.map do |assignment|
        ap = participant_map[[assignment.id, user.id]]
        next nil unless ap

        {
          assignment_id:   assignment.id,
          assignment_name: assignment.name,
          teammate_review: scores_received_from_teammates[ap.id]
        }
      end.compact

      pcts = cells.map { |c| c[:teammate_review]&.to_i }.compact

      {
        user_id:        user.id,
        user_name:      user.name,
        teammate_count: reviewer_teammate_counts[user.id] || 0,
        assignments:    cells,
        aggregate:      pcts.empty? ? nil : "#{(pcts.sum.to_f / pcts.size).round}%"
      }
    end

    render json: {
      course_id:   @course.id,
      course_name: @course.name,
      assignments: assignments.map { |a| { id: a.id, name: a.name } },
      rows:        student_rows
    }
  end

  private

  def set_course
    @course = Course.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Course not found' }, status: :not_found
  end

  def active_assignments
    @course.assignments
           .where(is_calibrated: [false, nil])
           .joins("INNER JOIN participants ON participants.parent_id = assignments.id AND participants.type = 'AssignmentParticipant'")
           .distinct
           .to_a
  end

  # Returns all students who participated in at least one of the given assignments,
  # ordered by name. Used to build the rows of the course report table.
  def unique_users(assignment_ids)
    User
      .joins("INNER JOIN participants ON participants.user_id = users.id")
      .where("participants.type = 'AssignmentParticipant' AND participants.parent_id IN (?)", assignment_ids)
      .distinct
      .order(:name)
  end

  # Bulk-load peer scores for all (assignment, team) pairs at once.
  # Scores are weighted by each reviewer's instructor-assigned grade so that
  # reviewers with higher grades contribute more to the team's peer score.
  # Returns { [assignment_id, team_id] => weighted_avg_pct }
  def precompute_peer_scores(assignment_ids, team_ids)
    return {} if team_ids.empty?

    maps = ReviewResponseMap
      .where(reviewed_object_id: assignment_ids, reviewee_id: team_ids)
      .includes(responses: :scores)

    reviewer_grades = ReviewGrade
      .where(participant_id: maps.map(&:reviewer_id).uniq)
      .index_by(&:participant_id)

    weighted_peer_score_averages(maps, reviewer_grades)
  end

  # Accumulates a weighted running sum and total weight for each
  # [assignment_id, team_id] key, then divides to get the weighted average.
  # The weight for each reviewer comes from ReviewGrade.reviewer_weight so the
  # formula can be changed (e.g. non-linear curves) without touching this method.
  def weighted_peer_score_averages(maps, reviewer_grades)
    # { [assignment_id, team_id] => { sum: Float, weight: Float } }
    accumulator = Hash.new { |h, k| h[k] = { sum: 0.0, weight: 0.0 } }

    maps.each do |map|
      grade_record = reviewer_grades[map.reviewer_id]
      w = ReviewGrade.reviewer_weight(grade_record&.grade_for_reviewer)
      map.responses.select(&:is_submitted).each do |resp|
        pct = response_score_percentage(resp)
        next if pct.nil?

        accumulator[[map.reviewed_object_id, map.reviewee_id]][:sum]    += pct * w
        accumulator[[map.reviewed_object_id, map.reviewee_id]][:weight] += w
      end
    end

    accumulator.average_weighted_sums { |v| (v[:sum] / v[:weight]).round(2) }
  end

  # Bulk-load teammate review scores for all participants at once.
  # Returns { participant_id => avg_pct_string }
  def precompute_teammate_scores(participant_ids)
    return {} if participant_ids.empty?

    maps = TeammateReviewResponseMap
      .where(reviewee_id: participant_ids)
      .includes(responses: :scores)

    scores_by_reviewee = Hash.new { |h, k| h[k] = [] }
    maps.each do |map|
      map.responses.select(&:is_submitted).each do |resp|
        pct = response_score_percentage(resp)
        scores_by_reviewee[map.reviewee_id] << pct.round if pct
      end
    end

    scores_by_reviewee.transform_values { |s| "#{(s.sum.to_f / s.size).round}%" }
  end

  # Returns a response's score as a percentage of its max, or nil if max is zero.
  # Shared by peer and teammate scoring loops to avoid duplication.
  def response_score_percentage(resp)
    max = resp.maximum_score
    return nil if max.zero?

    resp.aggregate_questionnaire_score.to_f / max * 100
  end

  # Bulk-compute unique teammate counts for all users at once.
  # Returns { user_id => count }
  def precompute_teammate_counts(assignment_ids, user_ids)
    return {} if user_ids.empty?

    rows = TeamsParticipant
      .joins("INNER JOIN teams ON teams_participants.team_id = teams.id")
      .where("teams.parent_id IN (?) AND teams_participants.user_id IN (?)", assignment_ids, user_ids)
      .select("teams_participants.user_id, teams_participants.team_id")
      .to_a

    team_to_members = rows.group_by(&:team_id).transform_values { |rs| rs.map(&:user_id) }

    user_ids.index_with do |user_id|
      my_team_ids = rows.select { |r| r.user_id == user_id }.map(&:team_id)
      team_to_members.values_at(*my_team_ids).flatten.uniq.count { |id| id != user_id }
    end
  end
end
