# frozen_string_literal: true

class EvolutionContactsSyncJob < ApplicationJob
  queue_as :low

  # force: bypass Rails.cache throttle (manual sync from Contacts UI)
  def perform(inbox_id, force = false)
    inbox = Inbox.find_by(id: inbox_id)
    return if inbox.blank?

    channel = inbox.channel
    return unless channel.is_a?(Channel::Whatsapp) && channel.provider == 'evolution'

    Whatsapp::EvolutionContactsPullService.new(channel: channel).perform(force: force)
  end
end
