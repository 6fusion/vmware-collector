# require 'active_support/core_ext/time'

module IntervalTime
  refine Time do
    # Chops time down to the nearest "interval"
    #  e.g., for a 5-minute interval, 5:34 -> 5:30, 5:36 -> 5:35
    def truncated(interval = 5)
      change(min: min - (min % interval))
    end
  end
end
