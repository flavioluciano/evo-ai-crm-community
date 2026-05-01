module Whatsapp::EvolutionGoHandlers::ContactSync
  private

  def process_contact_event
    data = normalize_evolution_go_data_hash(processed_params[:data])
    return if data.blank?

    jid = extract_whatsapp_jid_string(data)
    return unless individual_whatsapp_jid?(jid)

    phone = jid_to_phone_digits(jid)
    return if phone.blank?

    push_name = data[:PushName] || data[:pushName] || data[:FullName] || data[:fullName]

    upsert_evolution_go_contact!(phone, push_name.presence || phone)
    Rails.logger.info "Evolution Go API: Contact event synced #{phone}"
  rescue StandardError => e
    Rails.logger.error "Evolution Go API: Contact event failed: #{e.message}"
  end

  def process_push_name_event
    data = normalize_evolution_go_data_hash(processed_params[:data])
    return if data.blank?

    jid = extract_whatsapp_jid_string(data)
    return unless individual_whatsapp_jid?(jid)

    phone = jid_to_phone_digits(jid)
    return if phone.blank?

    new_name = data[:NewPushName] || data[:newPushName] || data[:PushName] || data[:pushName]
    return if new_name.blank?

    upsert_evolution_go_contact!(phone, new_name)
    Rails.logger.info "Evolution Go API: PushName updated for #{phone} -> #{new_name}"
  rescue StandardError => e
    Rails.logger.error "Evolution Go API: PushName event failed: #{e.message}"
  end

  def normalize_evolution_go_data_hash(data)
    return {} if data.blank?
    return data.deep_symbolize_keys if data.respond_to?(:deep_symbolize_keys)

    {}
  end

  def extract_whatsapp_jid_string(data)
    jid = data[:JID] || data[:jid] || data[:Chat] || data[:chat] ||
          data.dig(:Info, :Chat) || data.dig(:Info, :Sender)
    jid = jid.to_s
    jid.presence
  end

  def individual_whatsapp_jid?(jid)
    jid.present? && jid.include?('@s.whatsapp.net')
  end

  def jid_to_phone_digits(jid)
    jid.to_s.split('@').first.to_s.gsub(/:\d+$/, '')
  end

  def upsert_evolution_go_contact!(phone, display_name)
    formatted = phone.start_with?('+') ? phone : "+#{phone}"

    ::ContactInboxWithContactBuilder.new(
      source_id: phone,
      inbox: inbox,
      contact_attributes: {
        name: display_name,
        phone_number: formatted,
        additional_attributes: {
          evolution_go_contact_synced: true,
          evolution_go_synced_at: Time.current.iso8601
        }
      }
    ).perform
  end
end
