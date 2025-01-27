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
    module Processing
      module Strategies
        module Aj
          # - Aj
          # - Dlq
          # - Ftr
          # - Mom
          # - VP
          module DlqFtrMomVp
            include Strategies::Aj::DlqMomVp
            include Strategies::Aj::DlqFtrMom

            # Features for this strategy
            FEATURES = %i[
              active_job
              dead_letter_queue
              filtering
              manual_offset_management
              virtual_partitions
            ].freeze

            # AJ VP does not early stop on shutdown, hence here we can mark as consumed at the
            # end of all VPs
            def handle_after_consume
              coordinator.on_finished do |last_group_message|
                return if revoked?

                if coordinator.success?
                  coordinator.pause_tracker.reset

                  return if coordinator.manual_pause?

                  mark_as_consumed(last_group_message)

                  handle_post_filtering
                elsif coordinator.pause_tracker.attempt <= topic.dead_letter_queue.max_retries
                  retry_after_pause
                # If we've reached number of retries that we could, we need to skip the first
                # message that was not marked as consumed, pause and continue, while also moving
                # this message to the dead topic.
                #
                # For a Mom setup, this means, that user has to manage the checkpointing by
                # himself. If no checkpointing is ever done, we end up with an endless loop.
                else
                  coordinator.pause_tracker.reset
                  skippable_message, = find_skippable_message
                  dispatch_to_dlq(skippable_message) if dispatch_to_dlq?
                  # We can commit the offset here because we know that we skip it "forever" and
                  # since AJ consumer commits the offset after each job, we also know that the
                  # previous job was successful
                  mark_as_consumed(skippable_message)
                  pause(coordinator.seek_offset, nil, false)
                end
              end
            end
          end
        end
      end
    end
  end
end
