# frozen_string_literal: true

RSpec.describe RespondableTaskQueueBuilder, type: :model do
  let!(:instructor_role) { Role.find_or_create_by!(name: 'Instructor') }
  let!(:student_role) { Role.find_or_create_by!(name: 'Student') }
  let!(:instructor) do
    User.create!(
      name: "instructor_#{SecureRandom.hex(4)}",
      full_name: 'Instructor User',
      email: "instructor_#{SecureRandom.hex(4)}@example.com",
      password: 'password',
      role: instructor_role
    )
  end
  let!(:student) do
    User.create!(
      name: "student_#{SecureRandom.hex(4)}",
      full_name: 'Student User',
      email: "student_#{SecureRandom.hex(4)}@example.com",
      password: 'password',
      role: student_role
    )
  end
  let!(:assignment) { Assignment.create!(name: 'Quiz Review Assignment', instructor: instructor, require_quiz: true) }
  let!(:participant) do
    AssignmentParticipant.create!(
      user_id: student.id,
      parent_id: assignment.id,
      handle: student.name
    )
  end

  let!(:team) do
    AssignmentTeam.create!(
      name: "Team_#{SecureRandom.hex(3)}",
      parent_id: assignment.id,
      type: 'AssignmentTeam'
    )
  end
  let!(:team_link) { TeamsParticipant.create!(participant_id: participant.id, team_id: team.id, user_id: student.id) }

  let!(:quiz_questionnaire) do
    Questionnaire.create!(
      name: "Quiz Rubric #{SecureRandom.hex(3)}",
      private: false,
      min_question_score: 0,
      max_question_score: 5,
      questionnaire_type: 'QuizQuestionnaire',
      instructor_id: instructor.id
    )
  end

  let!(:review_questionnaire) do
    Questionnaire.create!(
      name: "Review Rubric #{SecureRandom.hex(3)}",
      private: false,
      min_question_score: 0,
      max_question_score: 5,
      questionnaire_type: 'ReviewQuestionnaire',
      instructor_id: instructor.id
    )
  end

  let!(:quiz_join) { AssignmentQuestionnaire.create!(assignment_id: assignment.id, questionnaire_id: quiz_questionnaire.id) }
  let!(:review_join) { AssignmentQuestionnaire.create!(assignment_id: assignment.id, questionnaire_id: review_questionnaire.id) }

  let!(:review_map) do
    ReviewResponseMap.create!(
      reviewed_object_id: assignment.id,
      reviewer_id: participant.id,
      reviewee_id: team.id,
      type: 'ReviewResponseMap'
    )
  end

  describe '#queue' do
    it 'yields quiz then review for quiz+review flow and creates missing responses' do
      queue = described_class.new(participant: participant, review_map: review_map, assignment: assignment).queue

      expect(queue.map { |item| item[:task_type] }).to eq(%i[quiz review])
      expect(queue.map { |item| item[:response_id] }.compact.size).to eq(2)
      expect(Response.where(map_id: queue.map { |item| item[:response_map_id] }).count).to eq(2)
    end

    it 'is idempotent across repeated calls' do
      builder = described_class.new(participant: participant, review_map: review_map, assignment: assignment)
      first_queue = builder.queue
      first_map_ids = first_queue.map { |item| item[:response_map_id] }
      first_response_ids = first_queue.map { |item| item[:response_id] }

      second_queue = described_class.new(participant: participant, review_map: review_map, assignment: assignment).queue
      second_map_ids = second_queue.map { |item| item[:response_map_id] }
      second_response_ids = second_queue.map { |item| item[:response_id] }

      expect(second_map_ids).to eq(first_map_ids)
      expect(second_response_ids).to eq(first_response_ids)
      expect(Response.where(map_id: first_map_ids).count).to eq(2)
    end

    it 'supports quiz-only flow with one queued task' do
      queue = described_class.new(participant: participant, review_map: nil, assignment: assignment).queue
      expect(queue.size).to eq(1)
      expect(queue.first[:task_type]).to eq(:quiz)
    end

    it 'supports review-only flow with one queued task' do
      assignment.update!(require_quiz: false)
      queue = described_class.new(participant: participant, review_map: review_map, assignment: assignment).queue
      expect(queue.size).to eq(1)
      expect(queue.first[:task_type]).to eq(:review)
    end
  end

  describe '#next_pending' do
    it 'returns quiz first, then review after quiz submission' do
      builder = described_class.new(participant: participant, review_map: review_map, assignment: assignment)
      first_pending = builder.next_pending
      expect(first_pending[:task_type]).to eq(:quiz)

      quiz_response = Response.find(first_pending[:response_id])
      quiz_response.update!(is_submitted: true)

      second_pending = described_class.new(participant: participant, review_map: review_map, assignment: assignment).next_pending
      expect(second_pending[:task_type]).to eq(:review)
    end
  end

  describe '#as_controller_payload' do
    it 'returns a controller-friendly queue shape without role/quiz conditionals' do
      payload = described_class.new(participant: participant, review_map: review_map, assignment: assignment).as_controller_payload

      expect(payload[:assignment_id]).to eq(assignment.id)
      expect(payload[:participant_id]).to eq(participant.id)
      expect(payload[:tasks].map { |item| item[:task_type] }).to eq(%i[quiz review])
      expect(payload[:next_pending][:task_type]).to eq(:quiz)
    end
  end
end
