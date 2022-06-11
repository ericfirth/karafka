# frozen_string_literal: true

# When we have an lrj job and it fails, it should use regular Karafka retry policies

setup_karafka do |config|
  config.license.token = pro_license_token
end

setup_active_job

draw_routes do
  consumer_group DataCollector.consumer_group do
    active_job_topic DataCollector.topic do
      long_running_job true
    end
  end
end

class Job < ActiveJob::Base
  queue_as DataCollector.topic

  def perform
    sleep 5

    if DataCollector.data[0].size.zero?
      DataCollector.data[0] << '1'
      raise StandardError
    else
      DataCollector.data[0] << '2'
    end
  end
end

Job.perform_later

start_karafka_and_wait_until do
  DataCollector.data[0].size >= 2
end

assert_equal '1', DataCollector.data[0][0]
assert_equal '2', DataCollector.data[0][1]