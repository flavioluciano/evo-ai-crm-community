class Whatsapp::IncomingMessageEvolutionService < Whatsapp::IncomingMessageBaseService
  include Whatsapp::EvolutionHandlers::MessagesUpsert
  include Whatsapp::EvolutionHandlers::MessagesUpdate
  include Whatsapp::EvolutionHandlers::Helpers

  def perform
    # Evolution API v2.3.1 structure: { event: 'messages.upsert', data: {...}, instance: '...' }
    event_type = processed_params[:event].to_s.downcase.tr('-', '.').tr('_', '.')

    Rails.logger.info "Evolution API: Processing event #{event_type} for instance #{processed_params[:instance]}"
    Rails.logger.debug { "Evolution API: Full payload: #{processed_params.inspect}" }

    case event_type
    when 'messages.upsert'
      process_messages_upsert
    when 'messages.set'
      # Pacote histórico da Evolution — não importamos; só mensagens novas via messages.upsert entram no CRM.
      Rails.logger.info 'Evolution API: messages.set ignored (bulk history); only messages.upsert creates CRM messages'
    when 'messages.update'
      process_messages_update
    when 'contacts.update'
      process_contacts_update
    when 'chats.update', 'chats.upsert'
      Rails.logger.info "Evolution API: Chat event #{event_type} - not processing (chat-level events)"
    when 'qrcode.updated'
      Rails.logger.info 'Evolution API: QR Code updated'
    when 'connection.update'
      process_connection_update
    when 'logout.instance'
      process_logout_instance
    else
      Rails.logger.warn "Evolution API: Unsupported event type: #{event_type}"
    end
  end

  private

  def message_under_process?
    mid = evolution_redis_message_id
    return false unless mid

    key = format(Redis::RedisKeys::MESSAGE_SOURCE_KEY, id: mid)
    Redis::Alfred.get(key)
  end

  def cache_message_source_id_in_redis
    mid = evolution_redis_message_id
    return unless mid

    key = format(Redis::RedisKeys::MESSAGE_SOURCE_KEY, id: mid)
    ::Redis::Alfred.setex(key, true)
  end

  def clear_message_source_id_from_redis
    mid = evolution_redis_message_id
    return unless mid

    key = format(Redis::RedisKeys::MESSAGE_SOURCE_KEY, id: mid)
    ::Redis::Alfred.delete(key)
  end

  def processed_params
    @processed_params ||= normalize_evolution_service_params(params)
  end

  def normalize_evolution_service_params(raw)
    h = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
    h = {} if h.nil?
    h = h.deep_symbolize_keys
    h[:event] ||= h[:Event]
    h[:instance] ||= h[:Instance] || h[:instanceName]
    h[:server_url] ||= h[:serverUrl] || h[:ServerUrl]
    h[:data] ||= h[:Data]
    h
  end

  # Align Redis dedup with MessagesUpsert: helpers used `data.dig(:key, :id)` which breaks when
  # `data` is an array or when the real blob is only on `@raw_message`.
  def evolution_redis_message_id
    blob = evolution_redis_message_blob
    return unless blob.is_a?(Hash)

    blob[:messageId] || blob[:keyId] || blob.dig(:key, :id)
  end

  def evolution_redis_message_blob
    if instance_variable_defined?(:@raw_message) && @raw_message.is_a?(Hash)
      @raw_message
    else
      d = processed_params[:data]
      return nil if d.blank?

      if d.is_a?(Array)
        return nil if d.size != 1

        item = d.first
        item.respond_to?(:deep_symbolize_keys) ? item.deep_symbolize_keys : item
      else
        d
      end
    end
  end

  def process_contacts_update
    # Evolution API sends contact updates when contact info changes (name, profile pic, etc.)
    contacts = processed_params[:data]
    contacts = [contacts] unless contacts.is_a?(Array)

    contacts.each do |contact_data|
      update_contact_info(contact_data)
    end
  end

  def update_contact_info(contact_data)
    remote_jid = contact_data[:remoteJid]
    return unless remote_jid

    phone_number = remote_jid.split('@').first
    push_name = contact_data[:pushName]
    profile_pic_url = contact_data[:profilePicUrl]

    # Find existing contact
    contact_inbox = inbox.contact_inboxes.find_by(source_id: phone_number)
    return unless contact_inbox

    contact = contact_inbox.contact

    # Update contact name if changed
    if push_name.present? && contact.name != push_name
      Rails.logger.info "Evolution API: Updating contact #{phone_number} name: #{contact.name} → #{push_name}"
      contact.update!(name: push_name)
    end

    # Update profile picture if available (optional enhancement for future)
    if profile_pic_url.present?
      Rails.logger.debug { "Evolution API: Contact #{phone_number} profile pic available: #{profile_pic_url}" }
      # Could implement profile picture download/update here
    end
  rescue StandardError => e
    Rails.logger.error "Evolution API: Failed to update contact info: #{e.message}"
  end

  def process_connection_update
    instance_name = processed_params[:instance]
    connection_data = processed_params[:data]
    state = connection_data[:state]
    status_reason = connection_data[:statusReason]
    profile_picture_url = connection_data[:profilePictureUrl]

    Rails.logger.info "Evolution API: Connection update - instance: #{instance_name}, state: #{state}, statusReason: #{status_reason}"

    case state
    when 'open'
      # Connection successful - clear any reauthorization flags
      handle_connection_open(profile_picture_url)
    when 'close'
      # Connection closed - mark for reauthorization
      handle_connection_close(status_reason)
    else
      Rails.logger.debug { "Evolution API: Connection state #{state} - no action needed" }
    end
  end

  def handle_connection_open(profile_picture_url)
    Rails.logger.info "Evolution API: Connection opened successfully for instance #{processed_params[:instance]}"

    # Clear any reauthorization flags from previous disconnections
    channel = inbox.channel
    if channel.reauthorization_required?
      Rails.logger.info "Evolution API: Clearing reauthorization flag for channel #{channel.id}"
      channel.reauthorized!
    end

    EvolutionContactsSyncJob.perform_later(inbox.id)

    # Update inbox avatar if profile picture URL is present
    return unless profile_picture_url.present?

    Rails.logger.info "Evolution API: Updating inbox avatar with profile picture from CONNECTION_UPDATE: #{profile_picture_url}"

    begin
      update_inbox_avatar(profile_picture_url)
    rescue StandardError => e
      Rails.logger.error "Evolution API: Failed to update inbox avatar from CONNECTION_UPDATE: #{e.message}"
      # Don't raise error - avatar update is not critical
    end
  end

  def handle_connection_close(status_reason)
    Rails.logger.warn "Evolution API: Connection closed for instance #{processed_params[:instance]} - statusReason: #{status_reason}"

    channel = inbox.channel

    # Mark channel as requiring reauthorization
    if status_reason == 401 || status_reason == '401'
      Rails.logger.error "Evolution API: Unauthorized (401) - marking channel #{channel.id} for reauthorization"
      channel.prompt_reauthorization!
    else
      Rails.logger.warn "Evolution API: Connection closed (reason: #{status_reason}) - marking channel #{channel.id} for reauthorization"
      channel.prompt_reauthorization!
    end

    # Update provider_connection status
    channel.update_provider_connection!({ 'connection' => 'disconnected', 'error' => "Connection closed (statusReason: #{status_reason})" })
  rescue StandardError => e
    Rails.logger.error "Evolution API: Failed to handle connection close: #{e.message}"
  end

  def process_logout_instance
    instance_name = processed_params[:instance]

    Rails.logger.warn "Evolution API: Logout instance event received for #{instance_name}"

    channel = inbox.channel

    # Mark channel as requiring reauthorization
    Rails.logger.warn "Evolution API: Instance logged out - marking channel #{channel.id} for reauthorization"
    channel.prompt_reauthorization!

    # Update provider_connection status
    channel.update_provider_connection!({ 'connection' => 'logged_out', 'error' => 'Instance has been logged out' })
  rescue StandardError => e
    Rails.logger.error "Evolution API: Failed to process logout instance: #{e.message}"
  end

  def update_inbox_avatar(picture_url)
    return unless inbox && picture_url.present?

    Rails.logger.info "Evolution API: Downloading and attaching inbox #{inbox.id} avatar from: #{picture_url}"

    # Download the image and attach it to the inbox
    require 'open-uri'

    downloaded_image = URI.open(picture_url)
    filename = "profile_#{inbox.id}_#{Time.now.to_i}.jpg"

    inbox.avatar.attach(
      io: downloaded_image,
      filename: filename,
      content_type: 'image/jpeg'
    )

    Rails.logger.info "Evolution API: Successfully updated inbox #{inbox.id} avatar via CONNECTION_UPDATE webhook"
  end
end
