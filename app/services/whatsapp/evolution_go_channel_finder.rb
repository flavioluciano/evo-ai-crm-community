# frozen_string_literal: true

# Maps Evolution Go webhook identifiers (instanceId, instanceToken) to Channel::Whatsapp.
# provider_config may store the same logical id under instance_uuid, instance_id, instanceId, etc.
module Whatsapp::EvolutionGoChannelFinder
  module_function

  UUID_RE = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i.freeze

  INSTANCE_ID_KEYS = %i[instance_uuid instance_id instanceId instance_name instanceName].freeze

  def find_channel(instance_id, instance_token: nil)
    raw = instance_id.to_s.strip if instance_id.present?

    if raw.present?
      variants = [raw]
      variants << raw.downcase if raw.match?(UUID_RE) && raw != raw.downcase

      variants.uniq.each do |variant|
        INSTANCE_ID_KEYS.each do |key|
          found = base_relation.where('provider_config @> ?', { key => variant }.to_json).first
          return found if found
        end
      end
    end

    if instance_token.present?
      tok = instance_token.to_s.strip
      found = base_relation.where('provider_config @> ?', { instance_token: tok }.to_json).first
      return found if found
    end

    nil
  end

  def base_relation
    Channel::Whatsapp.joins(:inbox).where(provider: 'evolution_go')
  end
end
