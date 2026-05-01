class Webhooks::WhatsappEventsJob < ApplicationJob
  queue_as :low

  def perform(params = {})
    # ActiveJob deserializa argumentos como Hash com chaves *string*. O código usa símbolos
    # (:instanceId, :event, etc.) — sem normalizar, o canal Evolution Go nunca é encontrado e
    # as mensagens somem sem erro visível.
    params = normalize_whatsapp_webhook_params(params)

    Rails.logger.info "WhatsApp webhook processing started: #{params.slice(:event, :instanceId, :instance, :phone_number).inspect}"

    channel = find_channel(params)
    if channel.blank?
      Rails.logger.error(
        'WhatsApp webhook: no channel matched — event discarded. ' \
        "instanceId=#{params[:instanceId].inspect} instance=#{params[:instance].inspect} " \
        "phone_number=#{params[:phone_number].inspect}"
      )
      return
    end

    if channel_is_inactive?(channel)
      Rails.logger.warn("Inactive WhatsApp channel: #{channel.phone_number} (reauthorization_required=#{channel.reauthorization_required?})")
      return
    end

    Rails.logger.info "Found WhatsApp channel: #{channel.phone_number} (provider: #{channel.provider})"

    # Handle different webhook event types
    if sync_event?(params)
      handle_sync_events(channel, params)
    else
      handle_message_events(channel, params)
    end
  end

  private

  def normalize_evolution_webhook_event_name(raw)
    raw.to_s.downcase.tr('-', '.').tr('_', '.')
  end

  def normalize_whatsapp_webhook_params(raw)
    h = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
    h = {} if h.nil?
    h = h.deep_symbolize_keys

    # Evolution API (Node): payloads sometimes use PascalCase/camelCase at the root after JSON parse.
    h[:event] ||= h[:Event]
    h[:instance] ||= h[:Instance] || h[:instanceName]
    h[:server_url] ||= h[:serverUrl] || h[:ServerUrl]
    h[:data] ||= h[:Data]

    h
  end

  def sync_event?(params)
    # WhatsApp Cloud sync events
    whatsapp_cloud_field = params.dig(:entry, 0, :changes, 0, :field)
    whatsapp_cloud_sync_fields = %w[smb_app_state_sync smb_message_echoes history account_update user_id_update]

    # Evolution API sync events — payloads use CONTACTS_UPSERT (underscores).
    # messages.set / MESSAGES_SET (bulk history) is intentionally NOT sync: only messages.upsert imports messages.
    evolution_event = normalize_evolution_webhook_event_name(params[:event])
    evolution_sync_events = %w[contacts.upsert]

    is_whatsapp_cloud_sync = whatsapp_cloud_sync_fields.include?(whatsapp_cloud_field)
    is_evolution_sync = evolution_sync_events.include?(evolution_event)

    is_sync = is_whatsapp_cloud_sync || is_evolution_sync

    Rails.logger.info "Sync event detection: whatsapp_field=#{whatsapp_cloud_field}, evolution_event=#{evolution_event}, is_sync=#{is_sync}"
    is_sync
  end

  def handle_sync_events(channel, params)
    case channel.provider
    when 'whatsapp_cloud'
      handle_whatsapp_cloud_sync_events(channel, params)
    when 'evolution'
      handle_evolution_sync_events(channel, params)
    else
      Rails.logger.warn "Unknown provider for sync events: #{channel.provider}"
    end
  end

  def handle_whatsapp_cloud_sync_events(channel, params)
    field = params.dig(:entry, 0, :changes, 0, :field)
    Rails.logger.info "Processing WhatsApp Cloud sync event: #{field} for channel #{channel.phone_number}"

    case field
    when 'smb_app_state_sync'
      if defined?(Whatsapp::ContactSyncService)
        Whatsapp::ContactSyncService.new(inbox: channel.inbox, params: params).perform
      else
        Rails.logger.warn 'ContactSyncService not available, skipping contact sync'
      end
    when 'smb_message_echoes', 'history'
      if defined?(Whatsapp::ConversationSyncService)
        Whatsapp::ConversationSyncService.new(inbox: channel.inbox, params: params).perform
      else
        Rails.logger.warn 'ConversationSyncService not available, skipping conversation sync'
      end
    when 'account_update'
      handle_account_update(channel, params)
    when 'user_id_update'
      handle_user_id_update(channel, params)
    else
      Rails.logger.warn "Unknown WhatsApp Cloud sync event field: #{field}"
    end
  end

  def handle_account_update(channel, params)
    update_data = params.dig(:entry, 0, :changes, 0, :value)
    phone_number = update_data[:phone_number]
    event = update_data[:event]

    Rails.logger.info "[WHATSAPP] Account update event: #{event} for phone #{phone_number}"

    case event
    when 'PARTNER_REMOVED'
      Rails.logger.warn "[WHATSAPP] Partner removed from WhatsApp Business Account for #{phone_number}"
      # Mark channel as requiring reauthorization
      channel.authorization_error! if channel.respond_to?(:authorization_error!)
    when 'PHONE_NUMBER_CHANGED'
      Rails.logger.warn "[WHATSAPP] Phone number changed for account (old: #{channel.phone_number}, new: #{phone_number})"
      # Could update the channel phone number, but this requires careful consideration
    when 'ACCOUNT_STATUS_CHANGED'
      Rails.logger.info "[WHATSAPP] Account status changed for #{phone_number}"
    else
      Rails.logger.warn "[WHATSAPP] Unknown account update event: #{event}"
    end
  end

  def handle_user_id_update(channel, params)
    value = params.dig(:entry, 0, :changes, 0, :value)
    updates = value[:user_id_update]
    return unless updates.is_a?(Array)

    updates.each do |update|
      previous_bsuid = update.dig(:user_id, :previous)
      current_bsuid = update.dig(:user_id, :current)
      wa_id = update[:wa_id]

      next if previous_bsuid.blank? || current_bsuid.blank?

      Rails.logger.info "[WHATSAPP] user_id_update: #{previous_bsuid} -> #{current_bsuid} (wa_id: #{wa_id})"

      contact_inbox = channel.inbox.contact_inboxes.find_by(bsuid: previous_bsuid)
      if contact_inbox
        attrs = { bsuid: current_bsuid }
        # If source_id was set to the old BSUID (BSUID-only contact), update it too
        attrs[:source_id] = current_bsuid if contact_inbox.source_id == previous_bsuid
        contact_inbox.update!(attrs)
        Rails.logger.info "[WHATSAPP] Updated BSUID for ContactInbox #{contact_inbox.id}"
      else
        Rails.logger.warn "[WHATSAPP] No ContactInbox found with BSUID #{previous_bsuid} for user_id_update"
      end
    rescue StandardError => e
      Rails.logger.error "[WHATSAPP] user_id_update failed for #{previous_bsuid}: #{e.message}"
    end
  end

  def handle_evolution_sync_events(channel, params)
    event = normalize_evolution_webhook_event_name(params[:event])
    Rails.logger.info "Processing Evolution sync event: #{params[:event]} (normalized: #{event}) for channel #{channel.phone_number}"

    case event
    when 'contacts.upsert'
      handle_evolution_contacts_sync(channel, params)
    else
      Rails.logger.warn "Unknown Evolution sync event: #{params[:event]} (normalized: #{event})"
    end
  end

  def handle_evolution_contacts_sync(channel, params)
    contacts_data = params[:data]
    list =
      if contacts_data.is_a?(Array)
        contacts_data
      elsif contacts_data.is_a?(Hash)
        [contacts_data]
      else
        []
      end

    return if list.empty?

    Rails.logger.info "[EVOLUTION] Processing #{list.size} contacts from sync webhook"

    list.each do |contact_data|
      Whatsapp::EvolutionContactUpsertService.new(channel: channel, contact_payload: contact_data).perform
    end
  end

  def handle_message_events(channel, params)
    Rails.logger.info "Processing message event for channel #{channel.phone_number} (provider: #{channel.provider})"

    case channel.provider
    when 'whatsapp_cloud'
      Whatsapp::IncomingMessageWhatsappCloudService.new(inbox: channel.inbox, params: params).perform
    when 'baileys'
      Whatsapp::IncomingMessageBaileysService.new(inbox: channel.inbox, params: params).perform
    when 'evolution'
      Whatsapp::IncomingMessageEvolutionService.new(inbox: channel.inbox, params: params).perform
    when 'evolution_go'
      Whatsapp::IncomingMessageEvolutionGoService.new(inbox: channel.inbox, params: params).perform
    when 'notificame'
      Whatsapp::IncomingMessageNotificameService.new(inbox: channel.inbox, params: params).perform
    when 'zapi'
      Whatsapp::IncomingMessageZapiService.new(inbox: channel.inbox, params: params).perform
    else
      Whatsapp::IncomingMessageService.new(inbox: channel.inbox, params: params).perform
    end
  end

  def find_channel(params)
    # Log detailed params for debugging
    Rails.logger.info "WhatsApp webhook channel search started with params: #{params.slice(:event, :instance, :phone_number, :server_url, :object)}"

    channel = try_find_channel_from_business_payload(params) ||
              try_find_channel_by_phone_number_id(params) ||
              try_find_channel_by_phone_number(params)

    log_channel_search_result(channel, params)
    channel
  end

  def try_find_channel_from_business_payload(params)
    return nil unless params[:object] == 'whatsapp_business_account'

    channel = find_channel_from_whatsapp_business_payload(params)
    Rails.logger.info "Channel search via Business payload: #{channel ? "found #{channel.phone_number}" : 'not found'}"
    channel
  end

  def try_find_channel_by_phone_number_id(params)
    phone_number_id = extract_phone_number_id_from_params(params)
    return nil if phone_number_id.blank?

    channel = find_channel_by_phone_number_id(phone_number_id)
    Rails.logger.info "Channel search via extracted phone_number_id #{phone_number_id}: #{channel ? "found #{channel.phone_number}" : 'not found'}"
    channel
  end

  def try_find_channel_by_phone_number(params)
    # For Z-API, find by instanceId
    if params[:instanceId].present? && params[:type].present?
      channel = find_channel_by_zapi_instance(params[:instanceId])
      if channel
        Rails.logger.info "Channel search via Z-API instanceId #{params[:instanceId]}: found #{channel.phone_number}"
        return channel
      end
    end

    # For Evolution Go, match instanceId / instanceToken against any persisted provider_config keys
    if params[:instanceId].present? || params[:instanceToken].present?
      channel = find_channel_by_evolution_go_instance(
        params[:instanceId],
        instance_token: params[:instanceToken]
      )
      if channel
        Rails.logger.info "Channel search via Evolution Go instanceId=#{params[:instanceId].inspect}: found #{channel.phone_number}"
        return channel
      end
    end

    # For Evolution API (Node): instance name + optional server_url (normalized match)
    if params[:instance].present? && params[:event].present?
      channel = Whatsapp::EvolutionChannelFinder.find_channel(
        params[:instance],
        server_url: params[:server_url]
      )
      if channel
        Rails.logger.info "Channel search via Evolution instance #{params[:instance]}: found #{channel.phone_number}"
        return channel
      end
    end

    # Try phone_number parameter for other providers
    if params[:phone_number].present?
      channel = find_channel_by_phone_number(params[:phone_number])
      if channel
        Rails.logger.info "Channel search via phone_number #{params[:phone_number]}: found #{channel.phone_number}"
        return channel
      end
    end

    Rails.logger.info "Channel search: no channel found for params #{params.slice(:phone_number, :instance, :event, :instanceId)}"
    nil
  end

  def find_channel_by_phone_number_id(phone_number_id)
    channels = Channel::Whatsapp.joins(:inbox)
                                .where(provider: 'whatsapp_cloud')
                                .where("provider_config ->> 'phone_number_id' = ?", phone_number_id.to_s)

    Rails.logger.info "Found #{channels.count} whatsapp_cloud channels with phone_number_id: #{phone_number_id}"

    if channels.count > 1
      Rails.logger.warn "Multiple channels found for phone_number_id #{phone_number_id}: #{channels.map(&:phone_number).join(', ')}"
    end

    channels.first
  end

  def find_channel_by_zapi_instance(instance_id)
    Rails.logger.info "Z-API channel search: Searching for instance_id=#{instance_id}"

    channel = Channel::Whatsapp.joins(:inbox)
                               .where(provider: 'zapi')
                               .where("provider_config ->> 'instance_id' = ?", instance_id)
                               .first

    Rails.logger.info "Z-API channel search: instance_id=#{instance_id} - #{channel ? "found channel #{channel.id}" : 'not found'}"
    channel
  end

  def find_channel_by_evolution_go_instance(instance_id, instance_token: nil)
    Rails.logger.info(
      'Evolution Go channel search: ' \
      "instance_id=#{instance_id.inspect} instance_token=#{instance_token.present? ? '[present]' : '[absent]'}"
    )

    channel = Whatsapp::EvolutionGoChannelFinder.find_channel(instance_id, instance_token: instance_token)

    Rails.logger.info "Evolution Go channel search: #{channel ? "found channel #{channel.id} (#{channel.phone_number})" : 'not found'}"
    channel
  end

  def find_channel_by_phone_number(phone_number)
    Channel::Whatsapp.find_by(phone_number: phone_number)
  end

  def log_channel_search_result(channel, params)
    if channel
      Rails.logger.info "✅ Channel found: #{channel.phone_number} (provider: #{channel.provider}, inbox: #{channel.inbox.name})"
    else
      Rails.logger.warn "❌ No channel found for webhook params: #{params.slice(:event, :instance, :phone_number, :server_url, :object)}"

      # Additional debugging for Evolution API
      if params[:instance].present?
        evolution_channels = Channel::Whatsapp.where(provider: %w[evolution evolution_go])
        Rails.logger.warn "Available Evolution channels: #{evolution_channels.map do |c|
          "#{c.phone_number} (instance: #{c.provider_config['instance_name']}, api_url: #{c.provider_config['api_url']})"
        end}"
      end
    end
  end

  def channel_is_inactive?(channel)
    # Evolution / Evolution Go reconnect via QR; a stale Redis reauthorization flag drops webhooks
    # while the instance is actually connected, so inbound messages never reach the inbox.
    return false if channel.provider.in?(%w[evolution evolution_go])

    return true if channel.reauthorization_required?

    false
  end

  def find_channel_from_whatsapp_business_payload(params)
    phone_number, phone_number_id = extract_business_payload_metadata(params)

    Rails.logger.info "Business payload metadata: phone_number=#{phone_number}, phone_number_id=#{phone_number_id}"

    # For WhatsApp Cloud, prioritize phone_number_id lookup as it's unique per business account
    if phone_number_id.present?
      channel = find_channel_by_phone_number_id(phone_number_id)
      if channel
        Rails.logger.info "Channel found by phone_number_id: #{channel.phone_number} (phone_number_id: #{phone_number_id})"
        return channel
      end
    end

    # Fallback: try to find by phone_number and validate phone_number_id
    if phone_number.present?
      channel = find_and_validate_channel_by_phone(phone_number, phone_number_id)
      if channel
        Rails.logger.info "Channel found by phone_number validation: #{channel.phone_number}"
        return channel
      end
    end

    Rails.logger.warn "No channel found for business payload: phone_number=#{phone_number}, phone_number_id=#{phone_number_id}"
    nil
  end

  def extract_business_payload_metadata(params)
    metadata = params[:entry]&.first&.dig(:changes)&.first&.dig(:value, :metadata)
    return [nil, nil] unless metadata

    phone_number = "+#{metadata[:display_phone_number]}"
    phone_number_id = metadata[:phone_number_id]

    [phone_number, phone_number_id]
  end

  def find_and_validate_channel_by_phone(phone_number, phone_number_id)
    channel = Channel::Whatsapp.find_by(phone_number: phone_number)

    if channel&.provider_config&.dig('phone_number_id') == phone_number_id
      Rails.logger.info 'Channel matched by phone_number and phone_number_id validation'
      return channel
    end

    nil
  end

  def extract_phone_number_id_from_params(params)
    phone_number_id = extract_from_entry_changes(params) ||
                      extract_from_metadata(params) ||
                      extract_from_messages(params)

    Rails.logger.info "Extracted phone_number_id: #{phone_number_id}" if phone_number_id.present?
    phone_number_id
  end

  def extract_from_entry_changes(params)
    return nil if params[:entry].blank?

    params[:entry].first[:changes]&.first&.dig(:value, :metadata, :phone_number_id)
  end

  def extract_from_metadata(params)
    return nil if params[:metadata].blank?

    params[:metadata][:phone_number_id]
  end

  def extract_from_messages(params)
    return nil if params[:messages].blank?

    params[:messages].first&.dig(:metadata, :phone_number_id)
  end
end
