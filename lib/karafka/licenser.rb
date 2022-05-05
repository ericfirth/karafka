# frozen_string_literal: true

module Karafka
  # Checks the license presence for pro and loads pro components when needed (if any)
  class Licenser
    # Location in the gem where we store the public key
    PUBLIC_KEY_LOCATION = File.join(Karafka.gem_root, 'certs', 'karafka-pro.pem')

    private_constant :PUBLIC_KEY_LOCATION

    # Check license and setup license details (if needed)
    # @param license_config [Dry::Configurable::Config] config part related to the licensing
    def verify(license_config)
      # If no license, it will just run LGPL components without anything extra
      return unless license_config.token

      public_key = OpenSSL::PKey::RSA.new(File.read(PUBLIC_KEY_LOCATION))

      # We gsub and strip in case someone copy-pasted it as a multi line string
      formatted_token = license_config.token.strip.delete("\n").delete(' ')
      decoded_token = Base64.decode64(formatted_token)

      begin
        data = public_key.public_decrypt(decoded_token)
      rescue OpenSSL::OpenSSLError
        data = nil
      end

      details = data ? JSON.parse(data) : raise_invalid_license_token(license_config)

      license_config.entity = details.fetch('entity')
      license_config.expires_on = Date.parse(details.fetch('expires_on'))

      return if license_config.expires_on > Date.today

      notify_if_license_expired(license_config.expires_on)
    end

    private

    # Raises an error with info, that used token is invalid
    # @param license_config [Dry::Configurable::Config]
    def raise_invalid_license_token(license_config)
      # We set it to false so `Karafka.pro?` method behaves as expected
      license_config.token = false

      raise(
        Errors::InvalidLicenseTokenError,
        <<~MSG.tr("\n", ' ')
          License key you provided is invalid.
          Please reach us at contact@karafka.io or visit https://karafka.io to obtain a valid one.
        MSG
      )
    end

    # We do not raise an error here as we don't want to cause any problems to someone that runs
    # Karafka on production. Error message is enough.
    #
    # @param expires_on [Date] when the license expires
    def notify_if_license_expired(expires_on)
      message = <<~MSG.tr("\n", ' ')
        Your license expired on #{expires_on}.
        Please reach us at contact@karafka.io or visit https://karafka.io to obtain a valid one.
      MSG

      Karafka.logger.error(message)

      Karafka.monitor.instrument(
        'error.occurred',
        caller: self,
        error: Errors::ExpiredLicenseTokenError.new(message),
        type: 'licenser.expired'
      )
    end
  end
end