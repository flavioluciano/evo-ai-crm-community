# frozen_string_literal: true

# Ensures a CRM Conversation exists for one Evolution /chat/findChats row (1:1 chat).
class Whatsapp::EvolutionChatRowSyncService
  pattr_initialize [:channel!, :chat_payload!]

  def perform
    data = normalize_payload(chat_payload)
    remote_jid = data[:remote_jid].to_s
    return if remote_jid.blank?

    domain = remote_jid.split('@').last.to_s.downcase
    return if remote_jid.end_with?('@g.us')
    return unless %w[s.whatsapp.net c.us].include?(domain)

    phone_part = remote_jid.split('@').first.to_s.split(':').first.split('_').first
    return if phone_part.blank?

    formatted_phone = phone_part.start_with?('+') ? phone_part : "+#{phone_part}"
    display_name = data[:push_name].presence || formatted_phone

    contact_inbox = ::ContactInboxWithContactBuilder.new(
      source_id: phone_part.delete('+'),
      inbox: channel.inbox,
      contact_attributes: {
        name: display_name,
        phone_number: formatted_phone,
        additional_attributes: {
          evolution_chat_list_synced: true,
          evolution_chat_sync_at: Time.current.to_i
        }
      }
    ).perform

    conversation = contact_inbox.conversations.find_or_create_by!(
      inbox_id: channel.inbox.id,
      contact_id: contact_inbox.contact_id,
      contact_inbox_id: contact_inbox.id
    )

    ts = parse_evolution_timestamp(data[:updated_at])
    return if ts.blank?

    raw_la = conversation.reload.read_attribute(:last_activity_at)
    return if raw_la.present? && ts <= raw_la

    conversation.update_columns(last_activity_at: ts, updated_at: Time.current)
  rescue StandardError => e
    Rails.logger.error "[EVOLUTION] Chat row sync failed for #{remote_jid.inspect}: #{e.message}"
  end

  private

  def normalize_payload(payload)
    h = payload.respond_to?(:deep_symbolize_keys) ? payload.deep_symbolize_keys : {}
    {
      remote_jid: h[:remoteJid] || h[:remote_jid],
      push_name: h[:pushName] || h[:push_name],
      updated_at: h[:updatedAt] || h[:updated_at]
    }
  end

  def parse_evolution_timestamp(value)
    return if value.blank?

    Time.zone.parse(value.to_s)
  rescue StandardError
    nil
  end
end
