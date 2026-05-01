# frozen_string_literal: true

# Resolves Channel::Whatsapp for Evolution API (Node) webhooks.
# Webhooks send `instance` + `server_url`; provider_config may use instance_name / instanceName / instance,
# and api_url often differs from server_url by a trailing slash or scheme/host casing.
module Whatsapp::EvolutionChannelFinder
  module_function

  def normalize_base(url)
    return '' if url.blank?

    url.to_s.strip.chomp('/')
  end

  def base_scope(instance_name)
    name = instance_name.to_s.strip
    return Channel::Whatsapp.none if name.blank?

    Channel::Whatsapp.joins(:inbox)
                     .where(provider: 'evolution')
                     .where(
                       <<~SQL.squish,
                         (provider_config ->> 'instance_name' = :name
                          OR provider_config ->> 'instanceName' = :name
                          OR provider_config ->> 'instance' = :name
                          OR inboxes.name = :name)
                       SQL
                       name: name
                     )
  end

  def find_channel(instance_name, server_url: nil)
    candidates = base_scope(instance_name).to_a
    return nil if candidates.empty?

    if server_url.present?
      want = normalize_base(server_url)
      by_url = candidates.find { |ch| normalize_base(ch.provider_config['api_url']) == want }
      return by_url if by_url
    end

    candidates.first
  end
end
