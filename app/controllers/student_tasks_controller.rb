class StudentTasksController < ApplicationController

  # List retrieves all student tasks associated with the current logged-in user.
  def action_allowed?
    current_user_has_student_privileges?
  end
  def list
    @student_tasks = StudentTask.from_user(current_user)
    render json: @student_tasks, status: :ok
  end

  # GET /student_tasks/teammates
  def team
    render json: StudentTask.teamed_students(current_user), status: :ok
  end

  # The view function retrieves a student task based on a participant's ID.
  # It is meant to provide an endpoint where tasks can be queried based on participant ID.
  def show
    # Constrain to AssignmentParticipant — other Participant subclasses for the same user
    # can be found via the polymorphic participants table and cause type-mismatch 500s later.
    participant = AssignmentParticipant.find_by(id: params[:id])

    if participant.nil?
      render json: { error: "Participant not found" }, status: :not_found
      return
    end

    if participant.user_id != current_user.id
      render json: { error: "Unauthorized access to participant's task" }, status: :forbidden
      return
    end

    @student_task = StudentTask.create_from_participant(participant)
    @student_task.due_dates = StudentTask.get_timeline_data(participant.assignment, participant)
    render json: @student_task, status: :ok
  end

end
