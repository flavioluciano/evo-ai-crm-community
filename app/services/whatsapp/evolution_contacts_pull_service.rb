# frozen_string_literal: true

# Fetches all contacts from Evolution (POST /chat/findContacts/:instanceName) and upserts them into CRM Contacts.
class Whatsapp::EvolutionContactsPullService
  pattr_initialize [:channel!]

  # @param force [Boolean] When true (manual sync from UI), skips throttle so pull always runs.
  def perform(force: false)
    unless channel.is_a?(Channel::Whatsapp) && channel.provider == 'evolution'
      Rails.logger.warn '[EVOLUTION] Contacts pull skipped: channel is not Evolution WhatsApp'
      return
    end

    instance_name = channel.provider_config['instance_name'].presence ||
                    channel.provider_config['instanceName'].presence
    if instance_name.blank?
      Rails.logger.warn '[EVOLUTION] Contacts pull skipped: missing instance_name'
      return
    end

    cache_key = "evolution_contacts_pull:#{channel.id}"
    unless force
      if Rails.cache.exist?(cache_key)
        Rails.logger.info '[EVOLUTION] Contacts pull skipped (recent run)'
        return
      end
    end

    api_url = evolution_api_url
    api_key = evolution_api_key
    if api_url.blank? || api_key.blank?
      Rails.logger.warn '[EVOLUTION] Contacts pull skipped: missing api_url or api key'
      return
    end

    url = "#{api_url.chomp('/')}/chat/findContacts/#{instance_name}"
    Rails.logger.info "[EVOLUTION] Pulling contacts from #{url}"

    response = HTTParty.post(
      url,
      headers: {
        'Content-Type' => 'application/json',
        'apikey' => api_key
      },
      body: {}.to_json,
      timeout: 180
    )

    unless response.success?
      Rails.logger.error "[EVOLUTION] findContacts failed: #{response.code} — #{response.body.to_s.truncate(500)}"
      return
    end

    list = normalize_contact_list(response.parsed_response)
    Rails.logger.info "[EVOLUTION] findContacts returned #{list.size} rows"

    Rails.cache.write(cache_key, true, expires_in: 30.minutes) unless force

    list.each do |row|
      Whatsapp::EvolutionContactUpsertService.new(channel: channel, contact_payload: row).perform
    end
  rescue StandardError => e
    Rails.logger.error "[EVOLUTION] Contacts pull error: #{e.message}"
    Rails.logger.debug { e.backtrace.join("\n") }
  end

  private

  def normalize_contact_list(parsed)
    return [] if parsed.blank?

    list =
      if parsed.is_a?(Array)
        parsed
      elsif parsed.is_a?(Hash)
        parsed['contacts'] || parsed[:contacts] || parsed['data'] || parsed[:data] || []
      else
        []
      end

    list.is_a?(Array) ? list : []
  end

  def evolution_api_url
    channel.provider_config['api_url'].to_s.strip.presence ||
      GlobalConfigService.load('EVOLUTION_API_URL', '').to_s.strip
  end

  def evolution_api_key
    cfg = channel.provider_config || {}
    (
      cfg['admin_token'].presence ||
      cfg['api_hash'].presence ||
      cfg['hash'].presence ||
      cfg['instance_token'].presence
    ).to_s.strip.presence || GlobalConfigService.load('EVOLUTION_ADMIN_SECRET', '').to_s.strip
  end
end
