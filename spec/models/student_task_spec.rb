# frozen_string_literal: true

require 'rails_helper'


RSpec.describe StudentTask, type: :model do
  before(:each) do
    @course     = double(name: "CSC 517")
    @assignment = double(name: "Final Project", course: @course, id: 1)
    @team       = double(id: 1, hyperlinks: [], has_submissions?: false)
    @user       = double(id: 1, try: nil)
    @participant = double(
      assignment: @assignment,
      topic:             "E2442",
      current_stage:     "submission",
      stage_deadline:    "2024-04-23",
      permission_granted: true,
      team:              @team,
      user:              @user,
      id:                1
    )
    allow(DueDate).to receive(:current_stage_for).with(@assignment).and_return("submission")
    allow(DueDate).to receive(:next_due_date).with(@assignment).and_return(nil)
    allow(SignedUpTeam).to receive(:find_by).and_return(nil)
    allow(ReviewResponseMap).to receive(:where).and_return([])
    allow(FeedbackResponseMap).to receive(:where).and_return([])
  end

  describe ".initialize" do
    it "correctly assigns all attributes" do
      args = {
        assignment:         @assignment,
        course:             "CSC 517",
        current_stage:      "submission",
        participant:        @participant,
        stage_deadline:     "2024-04-23",
        topic:              "E2442",
        permission_granted: false
      }

      student_task = StudentTask.new(args)

      expect(student_task.assignment.name).to eq("Final Project")
      expect(student_task.course).to eq("CSC 517")
      expect(student_task.current_stage).to eq("submission")
      expect(student_task.participant).to eq(@participant)
      expect(student_task.stage_deadline).to eq("2024-04-23")
      expect(student_task.topic).to eq("E2442")
      expect(student_task.permission_granted).to be false
    end
  end

  describe ".from_participant" do
    it "creates an instance from a participant instance" do
      student_task = StudentTask.create_from_participant(@participant)

      expect(student_task.assignment).to eq(@assignment.name)
      expect(student_task.course).to eq(@course.name)
      expect(student_task.topic).to be_nil # SignedUpTeam stubbed to return nil
      expect(student_task.current_stage).to eq("submission")
      expect(student_task.permission_granted).to be @participant.permission_granted
      expect(student_task.participant).to be @participant
    end
  end

  describe ".parse_stage_deadline" do
    context "valid date string" do
      it "parses the date string into a Time object" do
        valid_date = "2024-04-25"
        expect(StudentTask.send(:parse_stage_deadline, valid_date)).to eq(Time.parse("2024-04-25"))
      end
    end

    context "invalid date string" do
      it "returns current time plus one year" do
        invalid_date = "invalid input"
        # Set the now to be 2024-05-01 for testing purpose
        allow(Time).to receive(:now).and_return(Time.new(2024, 5, 1))
        expected_time = Time.new(2025, 5, 1)
        expect(StudentTask.send(:parse_stage_deadline, invalid_date)).to eq(expected_time)
      end
    end
  end

  describe ".from_participant_id" do
    # Shared helper: builds a relation double that responds to the
    # .where(id:).includes(assignment: :course).includes(:user).first chain
    # used by from_participant_id, and returns the given participant from .first.
    def stub_participant_chain(participant)
      relation = double('relation')
      allow(AssignmentParticipant).to receive(:where).with(id: 1).and_return(relation)
      allow(relation).to receive(:includes).with(assignment: :course).and_return(relation)
      allow(relation).to receive(:includes).with(:user).and_return(relation)
      allow(relation).to receive(:first).and_return(participant)
      relation
    end

    it "uses AssignmentParticipant (not Participant) to look up by id" do
      # from_participant_id must scope to AssignmentParticipant so that other Participant
      # subclasses (e.g. CourseParticipant) for the same id cannot slip through and
      # cause type-mismatch 500s later in create_from_participant.
      relation = stub_participant_chain(@participant)
      expect(AssignmentParticipant).to receive(:where).with(id: 1).and_return(relation)
      expect(StudentTask).to receive(:create_from_participant).with(@participant)

      StudentTask.from_participant_id(1)
    end

    it "does not call the base Participant class for the lookup" do
      stub_participant_chain(@participant)
      allow(StudentTask).to receive(:create_from_participant)

      expect(Participant).not_to receive(:find_by)

      StudentTask.from_participant_id(1)
    end
  end

  describe ".from_user" do
    it "sorts by a single composite key [course, assignment, stage_deadline]" do
      # Three chained sort_by calls were non-deterministic (each overwrote the previous).
      # The fix uses one sort_by { [course, assignment, stage_deadline] }.
      course_a = double(name: "AAA Course")
      course_b = double(name: "BBB Course")

      assignment_a1 = double(name: "Alpha", course: course_a, id: 10)
      assignment_a2 = double(name: "Beta",  course: course_a, id: 11)
      assignment_b1 = double(name: "Alpha", course: course_b, id: 12)

      deadline_near = Time.parse("2025-01-01")
      deadline_far  = Time.parse("2025-06-01")

      # Participants stub — course_a/Beta should sort before course_a/Alpha because of
      # alphabetical assignment name comparison within the same course
      p1 = double(assignment: assignment_a2, team: @team, user: @user, permission_granted: true, id: 1)
      p2 = double(assignment: assignment_a1, team: @team, user: @user, permission_granted: true, id: 2)
      p3 = double(assignment: assignment_b1, team: @team, user: @user, permission_granted: true, id: 3)

      user = double(id: 42)
      allow(DueDate).to receive(:current_stage_for).and_return("submission")
      allow(DueDate).to receive(:next_due_date).and_return(nil)
      allow(SignedUpTeam).to receive(:find_by).and_return(nil)
      # from_user chains .includes(...) on the where result, so we need a relation
      # double that responds to both includes calls and delegates map to the array.
      relation = double('relation')
      allow(AssignmentParticipant).to receive(:where).with(user_id: user.id).and_return(relation)
      allow(relation).to receive(:includes).with(assignment: :course).and_return(relation)
      allow(relation).to receive(:includes).with(:user).and_return(relation)
      allow(relation).to receive(:map) { |&blk| [p3, p1, p2].map(&blk) }

      tasks = StudentTask.from_user(user)

      courses   = tasks.map(&:course)
      expect(courses).to eq(courses.sort), "tasks should be sorted by course first"

      same_course_tasks = tasks.select { |t| t.course == "AAA Course" }
      assignments = same_course_tasks.map(&:assignment)
      expect(assignments).to eq(assignments.sort), "tasks within same course should be sorted by assignment name"
    end
  end

  describe "#revise?" do
    let(:participant) { double('participant', id: 1) }
    let(:task) { StudentTask.new(participant: participant, current_stage: 'submission') }

    context "when current stage is submission and team has hyperlinks" do
      it "returns true" do
        team = double('team', hyperlinks: ['http://example.com'], has_submissions?: false)
        allow(participant).to receive(:team).and_return(team)
        expect(task.send(:revise?)).to be true
      end
    end

    context "when current stage is submission and team has no submissions" do
      it "returns false" do
        team = double('team', hyperlinks: [], has_submissions?: false)
        allow(participant).to receive(:team).and_return(team)
        expect(task.send(:revise?)).to be false
      end
    end

    context "when current stage is review and submitted review exists" do
      it "returns true" do
        task_review = StudentTask.new(participant: participant, current_stage: 'review')
        allow(ReviewResponseMap).to receive(:where).and_return(
          double(joins: double(where: double(exists?: true)))
        )
        expect(task_review.send(:revise?)).to be true
      end
    end

    context "when current stage is review and no submitted review exists" do
      it "returns false" do
        task_review = StudentTask.new(participant: participant, current_stage: 'review')
        allow(ReviewResponseMap).to receive(:where).and_return(
          double(joins: double(where: double(exists?: false)))
        )
        expect(task_review.send(:revise?)).to be false
      end
    end
  end

  describe "#not_started?" do
    let(:participant) { double('participant', id: 1) }

    context "when in work stage and no work done" do
      it "returns true for submission stage with no submissions" do
        task = StudentTask.new(participant: participant, current_stage: 'submission')
        team = double('team', hyperlinks: [], has_submissions?: false)
        allow(participant).to receive(:team).and_return(team)
        expect(task.not_started?).to be true
      end

      it "returns true for review stage with no reviews given" do
        task = StudentTask.new(participant: participant, current_stage: 'review')
        allow(ReviewResponseMap).to receive(:where).and_return(
          double(joins: double(where: double(exists?: false)))
        )
        expect(task.not_started?).to be true
      end
    end

    context "when in work stage and work has been done" do
      it "returns false when submission has been made" do
        task = StudentTask.new(participant: participant, current_stage: 'submission')
        team = double('team', hyperlinks: ['http://example.com'], has_submissions?: false)
        allow(participant).to receive(:team).and_return(team)
        expect(task.not_started?).to be false
      end
    end

    context "when not in a work stage" do
      it "returns false for Finished stage" do
        task = StudentTask.new(participant: participant, current_stage: 'Finished')
        expect(task.not_started?).to be false
      end

      it "returns false for signup stage" do
        task = StudentTask.new(participant: participant, current_stage: 'signup')
        expect(task.not_started?).to be false
      end
    end
  end

  describe ".teamed_students" do
    let!(:institution)     { Institution.create!(name: 'NCSU') }
    let!(:instructor_role) { Role.find_by(name: 'Instructor') || Role.create!(name: 'Instructor') }
    let!(:student_role)    { Role.find_by(name: 'Student')    || Role.create!(name: 'Student') }
    let!(:instructor)      { User.create!(name: 'ts_instructor', email: 'ts_inst@test.com', full_name: 'TS Inst', password: 'password', role_id: instructor_role.id, institution: institution) }
    let!(:course)          { Course.create!(name: 'CSC 517', directory_path: 'csc517', instructor: instructor, institution: institution) }
    let!(:assignment)      { Assignment.create!(name: 'TS Assignment', instructor: instructor, course: course, is_calibrated: false) }
    let!(:user)            { User.create!(name: 'ts_student1', email: 'ts_s1@test.com', full_name: 'TS Student One', password: 'password', role_id: student_role.id, institution: institution) }
    let!(:teammate)        { User.create!(name: 'ts_student2', email: 'ts_s2@test.com', full_name: 'TS Student Two', password: 'password', role_id: student_role.id, institution: institution) }

    # Helper to add a user to a team via both TeamsUser and TeamsParticipant
    def add_to_team(team, user, assignment)
      TeamsUser.create!(team_id: team.id, user_id: user.id)
      participant = AssignmentParticipant.find_or_create_by!(user_id: user.id, parent_id: assignment.id) do |p|
        p.handle = user.name
      end
      TeamsParticipant.find_or_create_by!(team_id: team.id, user_id: user.id, participant_id: participant.id)
    end

    it "returns teammates grouped by course name" do
      team = AssignmentTeam.create!(name: 'Team 1', parent_id: assignment.id)
      add_to_team(team, user, assignment)
      add_to_team(team, teammate, assignment)

      result = StudentTask.teamed_students(user)
      expect(result).to have_key('CSC 517')
      expect(result['CSC 517']).to include('TS Student Two')
    end

    it "excludes calibrated assignments" do
      calibrated = Assignment.create!(name: 'Calibrated', instructor: instructor, course: course)
      team = AssignmentTeam.create!(name: 'Team Cal', parent_id: calibrated.id)
      add_to_team(team, user, calibrated)
      add_to_team(team, teammate, calibrated)
      # is_calibrated is a virtual attr_accessor — stub it on the found record
      allow(Assignment).to receive(:find_by).with(id: calibrated.id).and_return(
        instance_double(Assignment, is_calibrated: true, nil?: false)
      )

      result = StudentTask.teamed_students(user)
      expect(result.values.flatten).not_to include('TS Student Two')
    end

    it "excludes the user themselves from teammates" do
      team = AssignmentTeam.create!(name: 'Team Solo', parent_id: assignment.id)
      add_to_team(team, user, assignment)

      result = StudentTask.teamed_students(user)
      expect(result).to be_empty
    end

    it "returns teammates sorted alphabetically" do
      student3 = User.create!(name: 'ts_student3', email: 'ts_s3@test.com', full_name: 'Aaron Smith', password: 'password', role_id: student_role.id, institution: institution)
      team = AssignmentTeam.create!(name: 'Team Sort', parent_id: assignment.id)
      add_to_team(team, user, assignment)
      add_to_team(team, teammate, assignment)
      add_to_team(team, student3, assignment)

      result = StudentTask.teamed_students(user)
      expect(result['CSC 517']).to eq(result['CSC 517'].sort)
    end
  end

  describe ".get_timeline_data" do
    let!(:institution)  { Institution.find_by(name: 'NCSU') || Institution.create!(name: 'NCSU') }
    let!(:inst_role)    { Role.find_by(name: 'Instructor') || Role.create!(name: 'Instructor') }
    let!(:tl_instructor) { User.create!(name: 'tl_inst', email: 'tl_inst@test.com', full_name: 'TL Inst', password: 'password', role_id: inst_role.id, institution: institution) }
    let!(:assignment)   { Assignment.create!(name: 'Timeline Assignment', instructor: tl_instructor) }
    let(:participant)   { double('participant', id: 1) }

    it "includes due dates with id: nil" do
      DueDate.create!(parent: assignment, due_at: 7.days.from_now, deadline_name: 'Submission',
                      deadline_type_id: 1, submission_allowed_id: 3, review_allowed_id: 3)
      review_relation = double('relation')
      allow(review_relation).to receive(:find_each)
      allow(ReviewResponseMap).to receive(:where).with(reviewer_id: 1).and_return(review_relation)
      feedback_relation = double('feedback_relation')
      allow(feedback_relation).to receive(:find_each)
      allow(FeedbackResponseMap).to receive(:where).with(reviewer_id: 1).and_return(feedback_relation)

      timeline = StudentTask.get_timeline_data(assignment, participant)
      submission_entry = timeline.find { |t| t['name'].include?('Submission') }
      expect(submission_entry).not_to be_nil
      expect(submission_entry['id']).to be_nil
    end

    it "includes submitted peer review responses with a real id" do
      map = double('map', id: 1)
      submitted_response = double('response', id: 99, round: 1, updated_at: 2.days.ago)
      review_relation = double('relation')
      allow(review_relation).to receive(:find_each).and_yield(map)
      allow(ReviewResponseMap).to receive(:where).with(reviewer_id: 1).and_return(review_relation)

      # The fix: queries for is_submitted: true with explicit ordering
      submitted_scope = double('submitted_scope')
      allow(submitted_scope).to receive(:each).and_yield(submitted_response)
      ordered_scope = double('ordered_scope')
      allow(ordered_scope).to receive(:each).and_yield(submitted_response)
      allow(Response).to receive(:where).with(map_id: 1, is_submitted: true).and_return(ordered_scope)
      allow(ordered_scope).to receive(:order).with(updated_at: :desc).and_return(ordered_scope)

      feedback_relation = double('feedback_relation')
      allow(feedback_relation).to receive(:find_each)
      allow(FeedbackResponseMap).to receive(:where).with(reviewer_id: 1).and_return(feedback_relation)

      timeline = StudentTask.get_timeline_data(assignment, participant)
      review_entry = timeline.find { |t| t['name'].include?('peer review') }
      expect(review_entry).not_to be_nil
      expect(review_entry['id']).to eq(99)
    end

    it "excludes unsubmitted/draft peer review responses from the timeline" do
      map = double('map', id: 1)
      draft_response = double('draft_response', id: 55, round: 1, is_submitted: false, updated_at: 1.day.ago)

      review_relation = double('relation')
      allow(review_relation).to receive(:find_each).and_yield(map)
      allow(ReviewResponseMap).to receive(:where).with(reviewer_id: 1).and_return(review_relation)

      # The submitted scope returns nothing — draft response is excluded
      empty_ordered = double('empty_ordered')
      allow(empty_ordered).to receive(:each)
      allow(empty_ordered).to receive(:order).with(updated_at: :desc).and_return(empty_ordered)
      allow(Response).to receive(:where).with(map_id: 1, is_submitted: true).and_return(empty_ordered)

      feedback_relation = double('feedback_relation')
      allow(feedback_relation).to receive(:find_each)
      allow(FeedbackResponseMap).to receive(:where).with(reviewer_id: 1).and_return(feedback_relation)

      timeline = StudentTask.get_timeline_data(assignment, participant)
      expect(timeline.any? { |t| t['name'].include?('peer review') }).to be false
    end

    it "captures both round 1 and round 2 responses for the same map" do
      # The original code used Response.where(map_id:).last which silently dropped round 1
      # when a map had two submitted responses. The fix iterates all submitted responses.
      map = double('map', id: 1)
      r1 = double('r1', id: 10, round: 1, updated_at: 10.days.ago)
      r2 = double('r2', id: 11, round: 2, updated_at: 3.days.ago)

      review_relation = double('relation')
      allow(review_relation).to receive(:find_each).and_yield(map)
      allow(ReviewResponseMap).to receive(:where).with(reviewer_id: 1).and_return(review_relation)

      ordered_scope = double('ordered_scope')
      allow(ordered_scope).to receive(:each).and_yield(r1).and_yield(r2)
      allow(ordered_scope).to receive(:order).with(updated_at: :desc).and_return(ordered_scope)
      allow(Response).to receive(:where).with(map_id: 1, is_submitted: true).and_return(ordered_scope)

      feedback_relation = double('feedback_relation')
      allow(feedback_relation).to receive(:find_each)
      allow(FeedbackResponseMap).to receive(:where).with(reviewer_id: 1).and_return(feedback_relation)

      timeline = StudentTask.get_timeline_data(assignment, participant)
      review_entries = timeline.select { |t| t['name'].include?('peer review') }
      expect(review_entries.map { |e| e['round'] }).to contain_exactly(1, 2)
    end

    it "excludes unsubmitted author feedback responses" do
      map = double('map', id: 2)
      review_relation = double('relation')
      allow(review_relation).to receive(:find_each)
      allow(ReviewResponseMap).to receive(:where).with(reviewer_id: 1).and_return(review_relation)

      feedback_relation = double('feedback_relation')
      allow(feedback_relation).to receive(:find_each).and_yield(map)
      allow(FeedbackResponseMap).to receive(:where).with(reviewer_id: 1).and_return(feedback_relation)

      # The fix: is_submitted: true + order(:desc).first returns nil → feedback skipped
      ordered = double('ordered')
      allow(ordered).to receive(:first).and_return(nil)
      allow(Response).to receive(:where).with(map_id: 2, is_submitted: true).and_return(double(order: ordered))

      timeline = StudentTask.get_timeline_data(assignment, participant)
      expect(timeline.any? { |t| t['name'] == 'Author feedback' }).to be false
    end

    it "returns entries sorted by date" do
      DueDate.create!(parent: assignment, due_at: 7.days.from_now, deadline_name: 'Submission',
                      deadline_type_id: 1, submission_allowed_id: 3, review_allowed_id: 3)
      DueDate.create!(parent: assignment, due_at: 14.days.from_now, deadline_name: 'Review',
                      deadline_type_id: 2, submission_allowed_id: 3, review_allowed_id: 3)
      review_relation = double('relation')
      allow(review_relation).to receive(:find_each)
      allow(ReviewResponseMap).to receive(:where).with(reviewer_id: 1).and_return(review_relation)
      feedback_relation = double('feedback_relation')
      allow(feedback_relation).to receive(:find_each)
      allow(FeedbackResponseMap).to receive(:where).with(reviewer_id: 1).and_return(feedback_relation)

      timeline = StudentTask.get_timeline_data(assignment, participant)
      dates = timeline.map { |t| t['date'] }
      expect(dates).to eq(dates.sort)
    end
  end

end