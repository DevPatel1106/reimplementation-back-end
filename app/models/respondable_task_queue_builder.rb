# frozen_string_literal: true

class RespondableTaskQueueBuilder
  def initialize(participant:, review_map: nil, assignment: nil)
    @participant = participant
    @review_map = review_map
    @assignment = assignment || participant.assignment
  end

  def queue
    @queue ||= begin
      task_queue = build_queue
      first_pending_index = task_queue.index { |task| !task[:is_submitted] }

      task_queue.each_with_index.map do |task, index|
        task.merge(
          position: index,
          is_current: !first_pending_index.nil? && index == first_pending_index
        )
      end
    end
  end

  def next_pending
    queue.find { |task| !task[:is_submitted] }
  end

  # Stable shape for StudentTasksController follow-up integration.
  def as_controller_payload
    {
      assignment_id: assignment.id,
      participant_id: participant.id,
      tasks: queue,
      next_pending: next_pending
    }
  end

  private

  attr_reader :assignment, :participant, :review_map

  def build_queue
    blueprint.each_with_index.map do |task, index|
      response = find_or_create_response(task[:response_map_id], index: index)
      task.merge(
        response_id: response.id,
        is_submitted: response.is_submitted
      )
    end
  end

  def blueprint
    participant.respondable_task_blueprint_for(review_map: review_map)
  end

  # The first response for a map is the sequence "slot" we gate on.
  # Repeated calls remain idempotent through find_or_create_by!.
  def find_or_create_response(response_map_id, index:)
    Response.find_or_create_by!(map_id: response_map_id) do |response|
      response.round = 1
      response.version_num = index
      response.is_submitted = false
    end
  end
end
