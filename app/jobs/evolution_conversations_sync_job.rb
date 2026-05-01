# frozen_string_literal: true

class EvolutionConversationsSyncJob < ApplicationJob
  queue_as :low

  def perform(inbox_id, force = false)
    inbox = Inbox.find_by(id: inbox_id)
    return if inbox.blank?

    channel = inbox.channel
    return unless channel.is_a?(Channel::Whatsapp) && channel.provider == 'evolution'

    Whatsapp::EvolutionChatsPullService.new(channel: channel).perform(force: force)
  end
end
