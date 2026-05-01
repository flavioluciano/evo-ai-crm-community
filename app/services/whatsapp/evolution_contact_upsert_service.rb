# frozen_string_literal: true

# Upserts a CRM Contact + ContactInbox from Evolution API payloads (webhook or /chat/findContacts).
class Whatsapp::EvolutionContactUpsertService
  pattr_initialize [:channel!, :contact_payload!]

  def perform
    data = normalize_payload(contact_payload)
    remote_jid = data[:remote_jid].to_s
    return if remote_jid.blank?

    domain = remote_jid.split('@').last.to_s.downcase
    return if remote_jid.end_with?('@g.us')
    return unless %w[s.whatsapp.net c.us].include?(domain)

    phone_number = remote_jid.split('@').first.to_s.split(':').first.split('_').first
    return if phone_number.blank?

    formatted_phone = phone_number.start_with?('+') ? phone_number : "+#{phone_number}"
    push_name = data[:push_name].presence
    display_name = push_name || formatted_phone

    ::ContactInboxWithContactBuilder.new(
      source_id: phone_number.delete('+'),
      inbox: channel.inbox,
      contact_attributes: {
        name: display_name,
        phone_number: formatted_phone,
        additional_attributes: {
          evolution_contact_synced: true,
          evolution_sync_timestamp: Time.current.to_i,
          evolution_profile_pic_url: data[:profile_pic_url],
          evolution_instance_id: data[:instance_id]
        }.compact
      }
    ).perform

    Rails.logger.info "[EVOLUTION] Contact upserted for inbox #{channel.inbox.id}: #{display_name} (#{formatted_phone})"
  rescue StandardError => e
    Rails.logger.error "[EVOLUTION] Contact upsert failed for #{remote_jid}: #{e.message}"
  end

  private

  def normalize_payload(payload)
    h = payload.respond_to?(:deep_symbolize_keys) ? payload.deep_symbolize_keys : {}
    {
      remote_jid: h[:remoteJid] || h[:remote_jid],
      push_name: h[:pushName] || h[:push_name],
      profile_pic_url: h[:profilePicUrl] || h[:profile_pic_url],
      instance_id: h[:instanceId] || h[:instance_id]
    }
  end
end
