# frozen_string_literal: true

class StudentTask
  attr_accessor :assignment, :course, :current_stage, :participant, :stage_deadline, :topic, :permission_granted, :due_dates, :revise, :not_started, :active_round

  # Initializes a new instance of the StudentTask class
  def initialize(args)
    @assignment = args[:assignment]
    @course = args[:course]
    @current_stage = args[:current_stage]
    @participant = args[:participant]
    @stage_deadline = args[:stage_deadline]
    @topic = args[:topic]
    @permission_granted = args[:permission_granted]
    @due_dates = args[:due_dates]
    @active_round = args[:active_round]
  end

  # create a new StudentTask instance from a Participant object.
  def self.create_from_participant(participant)
    assignment = participant.assignment
    next_due   = DueDate.next_due_date(assignment)
    # Fetch the real topic name from SignedUpTeam -> ProjectTopic
    team       = participant.team
    topic_name = SignedUpTeam.find_by(team_id: team&.id)&.project_topic&.topic_name
    current_stage = DueDate.current_stage_for(assignment)

    # Determine the active round from the current due date so that revise? and
    # not_started? can scope their checks to the round the student is actually in,
    # rather than checking across all rounds (which causes round-1 work to make a
    # round-2 task appear started even when the student hasn't touched round 2 yet).
    active_round = next_due&.round

    task = new(
      assignment:         assignment.name,
      course:             assignment.course&.name || 'Unknown Course',
      topic:              topic_name,
      current_stage:      current_stage,
      stage_deadline:     parse_stage_deadline(next_due ? next_due.due_at.in_time_zone(participant.user.try(:timezonepref) || 'UTC') : 'Finished'),
      permission_granted: participant.permission_granted,
      participant:        participant,
      active_round:       active_round
    )
    task.revise = task.revise?
    task.not_started = task.not_started?
    task
  end


  # create an array of StudentTask instances for all participants linked to a user, sorted by deadline.
  # Three chained sort_by calls are not stable — each overwrites the previous ordering.
  # A single composite key [course, assignment, stage_deadline] gives deterministic,
  # consistent ordering in one pass.
  def self.from_user(user)
    # Preload the associations that create_from_participant dereferences for every
    # participant so that the list endpoint does not fire one query per participant
    # for each of these:
    #   participant.assignment         →  included via :assignment
    #   assignment.course              →  included via assignment: :course
    #   participant.user               →  included via :user  (for timezonepref)
    #
    # Remaining per-row queries that cannot be batched without schema changes:
    #   participant.team               →  resolved through TeamsParticipant (custom method,
    #                                     not a first-class has_one that AR can :include)
    #   SignedUpTeam / ProjectTopic    →  depends on team, same constraint
    #   DueDate.next_due_date          →  class method; hits AR cache after assignment preload
    #   reviews_given_in_current_stage →  scoped EXISTS query, one per participant
    AssignmentParticipant.where(user_id: user.id)
                         .includes(assignment: :course)
                         .includes(:user)
                         .map { |participant| StudentTask.create_from_participant(participant) }
                         .sort_by { |task| [task.course, task.assignment, task.stage_deadline] }
  end

  # create a StudentTask instance from a participant of the provided id
  # Constrained to AssignmentParticipant to avoid type-mismatch 500s when other
  # Participant subclasses exist for the same user/id in the polymorphic table.
  def self.from_participant_id(id)
    create_from_participant(AssignmentParticipant.find_by(id: id))
  end

  # Builds a unified timeline by merging due dates and actual activity,
  # sorted chronologically — mirrors the old get_timeline_data logic.
  def self.get_timeline_data(assignment, participant)
    timeline = []

    # 1. Due dates — labeled as "X deadline" mirroring old get_due_date_data behavior
    DueDate.fetch_due_dates(assignment).each do |due_date|
      timeline << {
        'id'    => nil,
        'name'  => due_date.round && due_date.round > 1 ? "#{due_date.deadline_name} deadline (round #{due_date.round})" : "#{due_date.deadline_name} deadline",
        'date'  => due_date.due_at.iso8601,
        'type'  => due_date.deadline_type_id,
        'round' => due_date.round
      }
    end

    # 2. Peer reviews given by this participant — one timeline entry per submitted Response.
    # The original code called Response.where(map_id: map.id).last, which returned only the
    # most recent Response for each ReviewResponseMap. For a 2-round assignment, one map has
    # two Response rows (round 1 and round 2). Using .last silently dropped the round 1 entry,
    # so the timeline showed "Round 2 peer review" with no corresponding "Round 1 peer review".
    # Iterating with find_each ensures all rounds are added as separate timeline events.
    ReviewResponseMap.where(reviewer_id: participant.id).find_each do |map|
      # Only submitted responses — draft/unsubmitted records must not appear in the timeline.
      # Order by updated_at desc so find_each still benefits from batching but each record
      # is a real submitted response. find_each is used (not .last) so both round 1 and
      # round 2 responses for the same map are captured as separate timeline events.
      Response.where(map_id: map.id, is_submitted: true).order(updated_at: :desc).each do |response|
        timeline << {
          'id'    => response.id,
          'name'  => "Round #{response.round} peer review",
          'date'  => response.updated_at.iso8601,
          'type'  => ExpertizaConstants::DeadlineTypes::REVIEW,
          'round' => response.round
        }
      end
    end

    # 3. Author feedback given by this participant — submitted only, most recent per map
    FeedbackResponseMap.where(reviewer_id: participant.id).find_each do |map|
      response = Response.where(map_id: map.id, is_submitted: true).order(updated_at: :desc).first
      next if response.nil?

      timeline << {
        'id'    => response.id,
        'name'  => 'Author feedback',
        'date'  => response.updated_at.iso8601,
        'type'  => nil,
        'round' => response.round
      }
    end

    timeline.sort_by { |item| item['date'] }
  end

  # Returns a hash of { course_name => [teammate_fullnames] } for all
  # assignment teams the user has been part of, mirroring the old teamed_students logic.
  def self.teamed_students(user)
    result = {}
    user.teams.each do |team|
      next unless team.is_a?(AssignmentTeam)
      assignment = Assignment.find_by(id: team.parent_id)
      next if assignment.nil? || assignment.is_calibrated

      course_name = assignment.course&.name || 'Unknown Course'
      teammates = team.users.where.not(id: user.id).map(&:full_name)
      next if teammates.empty?

      result[course_name] ||= []
      result[course_name] |= teammates
    end
    result.transform_values(&:sort).sort.to_h
  end

  # Returns true if the student has started work in the current stage.
  def revise?
    content_submitted_in_current_stage? ||
      reviews_given_in_current_stage?
  end

  # Returns true if the assignment is in an active stage but the student hasn't started yet.
  def not_started?
    in_work_stage? && !revise?
  end

  private

  def in_work_stage?
    [ExpertizaConstants::DeadlineTypes::NAMES[ExpertizaConstants::DeadlineTypes::SUBMISSION],
     ExpertizaConstants::DeadlineTypes::NAMES[ExpertizaConstants::DeadlineTypes::REVIEW]].include?(current_stage)
  end

  def content_submitted_in_current_stage?
    return false unless current_stage == 'submission'
    team = participant.team
    return false unless team
    # Submission stage has no round granularity — a hyperlink or file counts regardless.
    team.hyperlinks.present? || team.has_submissions?
  end

  def reviews_given_in_current_stage?
    return false unless current_stage == 'review'
    # Scope to the active round so that completing round-1 reviews does not make a
    # round-2 review task appear started when the student has not yet touched round 2.
    # When active_round is nil (single-round or indeterminate), fall back to checking
    # any submitted review so the predicate still works for non-multi-round assignments.
    scope = ReviewResponseMap.where(reviewer_id: participant.id)
                             .joins(:responses)
                             .where(responses: { is_submitted: true })
    if active_round.present?
      scope = scope.where(responses: { round: active_round })
    end
    scope.exists?
  end

  # Parses a date string or Time object into a Time instance.
  def self.parse_stage_deadline(date_string)
    return date_string if date_string.is_a?(Time)
    Time.parse(date_string.to_s)
  rescue StandardError => e
    Rails.logger.error("Failed to parse stage deadline '#{date_string}': #{e.message}")
    Time.now + 1.year
  end

end
