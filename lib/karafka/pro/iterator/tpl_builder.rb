# frozen_string_literal: true

# This Karafka component is a Pro component under a commercial license.
# This Karafka component is NOT licensed under LGPL.
#
# All of the commercial components are present in the lib/karafka/pro directory of this
# repository and their usage requires commercial license agreement.
#
# Karafka has also commercial-friendly license, commercial support and commercial components.
#
# By sending a pull request to the pro components, you are agreeing to transfer the copyright of
# your code to Maciej Mensfeld.

module Karafka
  module Pro
    class Iterator
      # Max time for a TPL request. We increase it to compensate for remote clusters latency
      TPL_REQUEST_TIMEOUT = 2_000

      private_constant :TPL_REQUEST_TIMEOUT

      # Because we have various formats in which we can provide the offsets, before we can
      # subscribe to them, there needs to be a bit of normalization.
      #
      # For some of the cases, we need to go to Kafka and get the real offsets or watermarks.
      #
      # This builder resolves that and builds a tpl to which we can safely subscribe the way
      # we want it.
      class TplBuilder
        # @param consumer [::Rdkafka::Consumer] consumer instance needed to talk with Kafka
        # @param expanded_topics [Hash] hash with expanded and normalized topics data
        def initialize(consumer, expanded_topics)
          @consumer = consumer
          @expanded_topics = expanded_topics
          @mapped_topics = Hash.new { |h, k| h[k] = {} }
        end

        # @return [Rdkafka::Consumer::TopicPartitionList] final tpl we can use to subscribe
        def call
          resolve_partitions_without_offsets
          resolve_partitions_with_exact_offsets
          resolve_partitions_with_negative_offsets
          resolve_partitions_with_time_offsets

          # Final tpl with all the data
          tpl = Rdkafka::Consumer::TopicPartitionList.new

          @mapped_topics.each do |name, partitions|
            tpl.add_topic_and_partitions_with_offsets(name, partitions)
          end

          tpl
        end

        private

        # First we expand on those partitions that do not have offsets defined.
        # When we operate in case like this, we just start from beginning
        def resolve_partitions_without_offsets
          @expanded_topics.each do |name, partitions|
            # We can here only about the case where we have partitions without offsets
            next unless partitions.is_a?(Array) || partitions.is_a?(Range)

            # When no offsets defined, we just start from zero
            @mapped_topics[name] = partitions.map { |partition| [partition, 0] }.to_h
          end
        end

        # If we get exact numeric offsets, we can just start from them without any extra work
        def resolve_partitions_with_exact_offsets
          @expanded_topics.each do |name, partitions|
            next unless partitions.is_a?(Hash)

            partitions.each do |partition, offset|
              # Skip negative and time based offsets
              next unless offset.is_a?(Integer) && offset >= 0

              # Exact offsets can be used as they are
              # No need for extra operations
              @mapped_topics[name][partition] = offset
            end
          end
        end

        # If the offsets are negative, it means we want to fetch N last messages and we need to
        # figure out the appropriate offsets
        #
        # We do it by getting the watermark offsets and just calculating it. This means that for
        # heavily compacted topics, this may return less than the desired number but it is a
        # limitation that is documented.
        def resolve_partitions_with_negative_offsets
          @expanded_topics.each do |name, partitions|
            next unless partitions.is_a?(Hash)

            partitions.each do |partition, offset|
              # Care only about negative offsets (last n messages)
              next unless offset.is_a?(Integer) && offset.negative?

              low_offset, high_offset = @consumer.query_watermark_offsets(name, partition)

              # We add because this offset is negative
              @mapped_topics[name][partition] = [high_offset + offset, low_offset].max
            end
          end
        end

        # For time based offsets we first need to aggregate them and request the proper offsets.
        # We want to get all times in one go for all tpls defined with times, so we accumulate
        # them here and we will make one sync request to kafka for all.
        def resolve_partitions_with_time_offsets
          time_tpl = Rdkafka::Consumer::TopicPartitionList.new

          # First we need to collect the time based once
          @expanded_topics.each do |name, partitions|
            next unless partitions.is_a?(Hash)

            time_based = {}

            partitions.each do |partition, offset|
              next unless offset.is_a?(Time)

              time_based[partition] = offset
            end

            next if time_based.empty?

            time_tpl.add_topic_and_partitions_with_offsets(name, time_based)
          end

          # If there were no time-based, no need to query Kafka
          return if time_tpl.empty?

          real_offsets = @consumer.offsets_for_times(time_tpl, TPL_REQUEST_TIMEOUT)

          real_offsets.to_h.each do |name, results|
            results.each do |result|
              raise(Errors::InvalidTimeBasedOffsetError) unless result

              @mapped_topics[name][result.partition] = result.offset
            end
          end
        end
      end
    end
  end
end