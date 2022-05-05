# frozen_string_literal: true

# When there is a misconfiguration of karafka options on ActiveJob job class, it should raise an
# error

setup_active_job

def handle
  yield
  DataCollector.data[0] << false
rescue Karafka::Errors::InvalidConfigurationError
  DataCollector.data[0] << true
end

Job = Class.new(ActiveJob::Base)

handle { Job.karafka_options(dispatch_method: :na) }
handle { Job.karafka_options(dispatch_method: :produce_async) }
handle { Job.karafka_options(dispatch_method: rand) }

assert_equal true, DataCollector.data[0][0]
assert_equal false, DataCollector.data[0][1]
assert_equal true, DataCollector.data[0][2]